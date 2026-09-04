import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/core/net/web_url.dart';

/// Reading a web address out of what somebody actually typed.
///
/// The reason this exists: nobody types `https://`. A link saved as
/// `artist.bandcamp.com` is, to `Uri`, a relative path with no host at all,
/// and every feature downstream then quietly did the wrong thing -- the
/// button opened nothing, the tooltip had no site name, the kind guessed from
/// the domain came out "Other", and asking the page for a picture answered
/// "that link is not a web address".
void main() {
  group('a link with no scheme', () {
    test('is assumed to be https, like an address bar would', () {
      expect(webUrl('artist.bandcamp.com').toString(),
          'https://artist.bandcamp.com');
      expect(webUrl('www.vgmdb.net/artist/123').toString(),
          'https://www.vgmdb.net/artist/123');
    });

    test('gets a host, which is what everything downstream reads', () {
      // The actual defect. Without a scheme this was empty, and an empty host
      // is why the icon, the tooltip and the picture fetch all gave up.
      expect(webUrl('artist.bandcamp.com')?.host, 'artist.bandcamp.com');
    });

    test('keeps the path, query and fragment it was given', () {
      final uri = webUrl('nicovideo.jp/watch/sm9?a=1#t=30');
      expect(uri?.host, 'nicovideo.jp');
      expect(uri?.path, '/watch/sm9');
      expect(uri?.query, 'a=1');
      expect(uri?.fragment, 't=30');
    });

    test('is not fooled by a port into reading the host as a scheme', () {
      // Dots are legal in a scheme, so `Uri` reads `example.com:8080` as the
      // scheme `example.com` -- which would sail past a `hasScheme` check and
      // then fail to open.
      final uri = webUrl('example.com:8080/x');
      expect(uri?.scheme, 'https');
      expect(uri?.host, 'example.com');
      expect(uri?.port, 8080);
    });

    test('takes a protocol-relative address as copied out of a page', () {
      expect(webUrl('//bsky.app/profile/x').toString(),
          'https://bsky.app/profile/x');
    });

    test('ignores the whitespace around a paste', () {
      expect(webUrl('  soundcloud.com/x \n').toString(),
          'https://soundcloud.com/x');
    });
  });

  group('a link that already says what it is', () {
    test('is left exactly as it was', () {
      for (final url in const [
        'https://artist.bandcamp.com',
        'http://old.example/x',
        'https://x.com/someone?a=1#b',
      ]) {
        expect(webUrl(url).toString(), url, reason: url);
      }
    });

    test('keeps a scheme that is not the web, for whoever has to judge it', () {
      // Not this function's business to refuse: the caller decides whether
      // `mailto:` is something it can open or fetch.
      expect(webUrl('mailto:artist@example.com')?.scheme, 'mailto');
      expect(webUrl('ftp://files.example/x')?.scheme, 'ftp');
    });
  });

  group('text that is not an address at all', () {
    test('is not turned into one by assuming a scheme', () {
      // The trap in "just prepend https": `Uri` accepts `not a url` as the
      // host `not%20a%20url` without complaint, which would make any stray
      // note in a link field look like a site nobody can reach.
      for (final text in const ['not a url', 'hello', 'TODO: find this', '..']) {
        expect(webUrl(text), isNull, reason: text);
      }
    });

    test('nothing typed is nothing to open', () {
      expect(webUrl(''), isNull);
      expect(webUrl('   '), isNull);
    });

    test('gibberish no scheme can rescue stays null', () {
      expect(webUrl(':::not a url:::'), isNull);
    });
  });
}
