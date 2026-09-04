import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/logging/app_log.dart';

/// Finds the picture a page shows for itself.
///
/// An artist's links already point at the places their own photo lives -- a
/// Bandcamp page, a SoundCloud profile, a Wikipedia article -- so the picture
/// is usually one fetch away rather than something to go hunting for and save
/// to disk first. This is the same idea as offering a playlist the covers of
/// the tracks already in it: use what the library already knows instead of
/// asking for a file.
///
/// It reads the page's own social-preview tags (`og:image`, then
/// `twitter:image`, then an Apple touch icon) rather than scraping images out
/// of the body. Those tags are the site *telling* you which single image
/// represents this page, which is exactly the question being asked, and it
/// means one small request and one image instead of a crawl.
///
/// Best effort by design. A site can refuse an unknown client, serve a
/// generic card, or declare no image at all, and none of those is an error
/// worth more than a sentence on screen -- browsing for a file is still right
/// there.
///
/// A favicon is deliberately *not* a fallback: a 16-pixel site mark is not a
/// portrait of anybody, and setting one would look like the feature worked.
class LinkArtworkService {
  LinkArtworkService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _timeout = Duration(seconds: 12);

  /// Cap on the page read. Enough for any real page's `<head>`; the point is
  /// that a wrong URL cannot pull an unbounded stream into memory.
  static const _maxPageBytes = 3 * 1024 * 1024;

  /// Cap on the image itself. Generous -- press photos are large -- while
  /// still refusing something that is clearly not a picture for a header.
  static const _maxImageBytes = 24 * 1024 * 1024;

  /// Identifies itself honestly. Some sites refuse anything they do not
  /// recognise, and pretending to be a browser to get around that is not
  /// something a music player should be doing on its own initiative.
  static const _userAgent = 'marmelade (+https://github.com/Este2013/marmelade)';

  static const _headers = {
    'User-Agent': _userAgent,
    'Accept': 'text/html,application/xhtml+xml',
  };

  /// Tries to fetch the picture [pageUrl] advertises.
  Future<LinkArtwork> fetch(String pageUrl) async {
    final page = Uri.tryParse(pageUrl.trim());
    if (page == null || !page.hasScheme || !page.hasAuthority) {
      return const LinkArtworkMissing('That link is not a web address.');
    }
    if (page.scheme != 'http' && page.scheme != 'https') {
      return LinkArtworkMissing('Only web links can be read (not ${page.scheme}).');
    }

    try {
      final html = await _read(page, maxBytes: _maxPageBytes, headers: _headers);
      if (html == null) {
        return LinkArtworkMissing('${page.host} did not answer.');
      }

      final declared = _findImageUrl(String.fromCharCodes(html));
      if (declared == null) {
        return LinkArtworkMissing('${page.host} does not offer a picture.');
      }

      // Relative is legal in these tags and common in the wild.
      final image = page.resolve(declared);
      if (image.scheme != 'http' && image.scheme != 'https') {
        return LinkArtworkMissing('${page.host} pointed at something unreadable.');
      }

      final bytes = await _read(
        image,
        maxBytes: _maxImageBytes,
        headers: const {'User-Agent': _userAgent},
      );
      if (bytes == null || bytes.isEmpty) {
        return LinkArtworkMissing('The picture ${image.host} offered could not be read.');
      }

      AppLog.instance.info('fetched a picture from a link', tag: 'artwork', fields: {
        'page': page.host,
        'image': '$image',
        'bytes': AppLog.formatBytes(bytes.length),
      });
      return LinkArtworkFound(
        bytes: Uint8List.fromList(bytes),
        from: image,
        page: page,
      );
    } catch (error, stack) {
      // A network failure is ordinary here -- offline, DNS, a site that hangs
      // -- so it reports rather than throws. Logged because "it did nothing"
      // is otherwise impossible to look into.
      AppLog.instance.warn(
        'could not fetch a picture from a link',
        tag: 'artwork',
        error: error,
        stack: stack,
        fields: {'url': pageUrl},
      );
      return LinkArtworkMissing('${page.host} could not be reached.');
    }
  }

  /// Reads at most [maxBytes], refusing anything longer instead of letting a
  /// stream fill memory. Returns null on any non-200 or an overlong body.
  Future<List<int>?> _read(
    Uri uri, {
    required int maxBytes,
    Map<String, String>? headers,
  }) async {
    final request = http.Request('GET', uri);
    if (headers != null) request.headers.addAll(headers);

    final response = await _client.send(request).timeout(_timeout);
    if (response.statusCode != 200) return null;

    final bytes = <int>[];
    // Per-chunk rather than per-request: a site that sends a byte a minute
    // should not hold this open for as long as it likes.
    await for (final chunk in response.stream.timeout(_timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) return null;
    }
    return bytes;
  }

  /// The image a page declares for itself, in the order worth trusting.
  ///
  /// Hand-matched rather than parsed with an HTML library: the app has no
  /// parser dependency, and pulling one in to read three meta tags out of a
  /// `<head>` is a poor trade. Attributes are read per-tag rather than with
  /// one big pattern, because their order varies by site and a single regex
  /// that assumed `property` before `content` silently missed half of them.
  static String? _findImageUrl(String html) {
    final metas = <String, String>{};
    for (final match in RegExp(r'<meta\s[^>]*>', caseSensitive: false)
        .allMatches(html)) {
      final tag = match.group(0)!;
      final key = _attribute(tag, 'property') ?? _attribute(tag, 'name');
      final content = _attribute(tag, 'content');
      if (key == null || content == null || content.isEmpty) continue;
      metas.putIfAbsent(key.toLowerCase(), () => content);
    }

    for (final key in const [
      'og:image:secure_url',
      'og:image:url',
      'og:image',
      'twitter:image',
      'twitter:image:src',
    ]) {
      final found = metas[key];
      if (found != null) return _unescape(found);
    }

    // An Apple touch icon is a real, reasonably large picture chosen by the
    // site, unlike a favicon.
    for (final match in RegExp(r'<link\s[^>]*>', caseSensitive: false)
        .allMatches(html)) {
      final tag = match.group(0)!;
      final rel = _attribute(tag, 'rel')?.toLowerCase() ?? '';
      if (!rel.contains('apple-touch-icon')) continue;
      final href = _attribute(tag, 'href');
      if (href != null && href.isNotEmpty) return _unescape(href);
    }

    return null;
  }

  /// One attribute out of a tag, quoted either way or bare.
  static String? _attribute(String tag, String name) {
    final match = RegExp(
      '$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))',
      caseSensitive: false,
    ).firstMatch(tag);
    if (match == null) return null;
    return match.group(1) ?? match.group(2) ?? match.group(3);
  }

  /// The handful of entities that actually turn up inside a URL attribute.
  /// `&amp;` between query parameters is the common one and breaks the URL if
  /// left in.
  static String _unescape(String value) => value
      .trim()
      .replaceAll('&amp;', '&')
      .replaceAll('&#38;', '&')
      .replaceAll('&#x26;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");

  void dispose() => _client.close();
}

/// What came back from trying a link.
sealed class LinkArtwork {
  const LinkArtwork();
}

/// A picture, and where it came from -- kept so the image row can record its
/// provenance rather than claiming it was chosen by hand.
class LinkArtworkFound extends LinkArtwork {
  const LinkArtworkFound({
    required this.bytes,
    required this.from,
    required this.page,
  });

  final Uint8List bytes;

  /// The image's own address.
  final Uri from;

  /// The page that advertised it.
  final Uri page;

  /// For `images.source_description`, so months later it is obvious where a
  /// picture came from and whether it can be fetched again.
  String describe() => 'from $page ($from)';
}

/// Nothing usable, with a sentence worth showing.
class LinkArtworkMissing extends LinkArtwork {
  const LinkArtworkMissing(this.reason);

  final String reason;
}
