import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marmelade/services/art/link_artwork_service.dart';

/// Reading the picture a linked page shows for itself.
///
/// The feature is best effort by nature -- it asks a third-party site for a
/// social-preview tag -- so most of what matters here is the failure
/// behaviour: never throw at the caller, never come back with something that
/// is not a picture, and never quietly succeed with a favicon, which would
/// look like it worked and leave a 16-pixel site mark as somebody's portrait.
void main() {
  /// The bytes a fetch is expected to hand back, standing in for a photo.
  final imageBytes = Uint8List.fromList(List.filled(64, 7));

  /// A client that answers the page with [html] and any other URL with
  /// [imageBytes], recording every address it was asked for.
  ({LinkArtworkService service, List<String> requested}) serviceFor(
    String html, {
    int pageStatus = 200,
    int imageStatus = 200,
    Object? throws,
  }) {
    final requested = <String>[];
    final client = MockClient((request) async {
      requested.add(request.url.toString());
      if (throws != null) throw throws;
      final isPage = request.url.path.isEmpty ||
          request.url.path == '/' ||
          request.url.path.contains('artist');
      if (isPage) {
        return http.Response(html, pageStatus, headers: {
          'content-type': 'text/html; charset=utf-8',
        });
      }
      return http.Response.bytes(imageBytes, imageStatus, headers: {
        'content-type': 'image/jpeg',
      });
    });
    return (service: LinkArtworkService(client: client), requested: requested);
  }

  String page(String head) => '<html><head>$head</head><body>hi</body></html>';

  group('finding what a page offers', () {
    test('reads og:image and fetches it', () async {
      final harness = serviceFor(
        page('<meta property="og:image" content="https://cdn.test/photo.jpg">'),
      );

      final result = await harness.service.fetch('https://bandcamp.test/artist');

      expect(result, isA<LinkArtworkFound>());
      final found = result as LinkArtworkFound;
      expect(found.bytes, imageBytes);
      expect(found.from.toString(), 'https://cdn.test/photo.jpg');
      expect(harness.requested, [
        'https://bandcamp.test/artist',
        'https://cdn.test/photo.jpg',
      ]);
    });

    test('does not care which order the attributes come in', () async {
      // Half the sites in the wild put content first, and a single regex that
      // assumed otherwise missed them all.
      final harness = serviceFor(
        page('<meta content="https://cdn.test/photo.jpg" property="og:image">'),
      );

      expect(
        await harness.service.fetch('https://bandcamp.test/artist'),
        isA<LinkArtworkFound>(),
      );
    });

    test('takes single quotes and bare attributes too', () async {
      final harness = serviceFor(
        page("<meta property='og:image' content='https://cdn.test/p.jpg'>"),
      );

      expect(
        await harness.service.fetch('https://bandcamp.test/artist'),
        isA<LinkArtworkFound>(),
      );
    });

    test('resolves a relative address against the page', () async {
      final harness = serviceFor(
        page('<meta property="og:image" content="/img/photo.jpg">'),
      );

      final result = await harness.service.fetch('https://site.test/artist');

      expect(
        (result as LinkArtworkFound).from.toString(),
        'https://site.test/img/photo.jpg',
      );
    });

    test('unescapes the entities that break a query string', () async {
      // `&amp;` between parameters is extremely common in these tags, and
      // left in it fetches the wrong URL -- or nothing.
      final harness = serviceFor(
        page(
          '<meta property="og:image" '
          'content="https://cdn.test/p.jpg?w=500&amp;h=500">',
        ),
      );

      final result = await harness.service.fetch('https://site.test/artist');

      expect(
        (result as LinkArtworkFound).from.toString(),
        'https://cdn.test/p.jpg?w=500&h=500',
      );
    });

    test('prefers the secure URL, then og, then twitter', () async {
      final harness = serviceFor(
        page(
          '<meta name="twitter:image" content="https://cdn.test/twitter.jpg">'
          '<meta property="og:image" content="https://cdn.test/og.jpg">'
          '<meta property="og:image:secure_url" content="https://cdn.test/s.jpg">',
        ),
      );

      final result = await harness.service.fetch('https://site.test/artist');

      expect((result as LinkArtworkFound).from.toString(), 'https://cdn.test/s.jpg');
    });

    test('falls back to twitter:image when there is no og:image', () async {
      final harness = serviceFor(
        page('<meta name="twitter:image" content="https://cdn.test/t.jpg">'),
      );

      final result = await harness.service.fetch('https://site.test/artist');

      expect((result as LinkArtworkFound).from.toString(), 'https://cdn.test/t.jpg');
    });

    test('falls back to an apple touch icon, which is a real picture',
        () async {
      final harness = serviceFor(
        page('<link rel="apple-touch-icon" href="https://cdn.test/touch.png">'),
      );

      final result = await harness.service.fetch('https://site.test/artist');

      expect(
        (result as LinkArtworkFound).from.toString(),
        'https://cdn.test/touch.png',
      );
    });

    test('will not settle for a favicon', () async {
      // A 16-pixel site mark is not a portrait of anybody, and setting one
      // would look like the feature had worked.
      final harness = serviceFor(
        page('<link rel="icon" href="https://cdn.test/favicon.ico">'),
      );

      final result = await harness.service.fetch('https://site.test/artist');

      expect(result, isA<LinkArtworkMissing>());
      expect(harness.requested, ['https://site.test/artist']);
    });

    test('records where the picture came from, for the image row', () async {
      final harness = serviceFor(
        page('<meta property="og:image" content="https://cdn.test/p.jpg">'),
      );

      final result = await harness.service.fetch('https://bandcamp.test/artist')
          as LinkArtworkFound;

      expect(result.describe(), contains('bandcamp.test/artist'));
      expect(result.describe(), contains('cdn.test/p.jpg'));
    });
  });

  group('when it cannot', () {
    test('says so, naming the site, when no picture is declared', () async {
      final harness = serviceFor(page('<title>Nothing here</title>'));

      final result = await harness.service.fetch('https://quiet.test/artist');

      expect(result, isA<LinkArtworkMissing>());
      expect((result as LinkArtworkMissing).reason, contains('quiet.test'));
    });

    test('a page that refuses is a message, not an exception', () async {
      final harness = serviceFor(page(''), pageStatus: 403);

      final result = await harness.service.fetch('https://strict.test/artist');

      expect(result, isA<LinkArtworkMissing>());
      expect((result as LinkArtworkMissing).reason, contains('strict.test'));
    });

    test('an image that will not download is a message too', () async {
      final harness = serviceFor(
        page('<meta property="og:image" content="https://cdn.test/gone.jpg">'),
        imageStatus: 404,
      );

      expect(
        await harness.service.fetch('https://site.test/artist'),
        isA<LinkArtworkMissing>(),
      );
    });

    test('a network failure is caught rather than thrown at the caller',
        () async {
      // This runs from a button. An exception here would take the page down
      // over somebody being offline.
      final harness = serviceFor(page(''), throws: http.ClientException('down'));

      final result = await harness.service.fetch('https://site.test/artist');

      expect(result, isA<LinkArtworkMissing>());
    });

    test('refuses anything that is not a web address, without asking',
        () async {
      final harness = serviceFor(page(''));

      for (final url in const ['mailto:me@test', 'not a url', '', 'ftp://x.test/a']) {
        expect(
          await harness.service.fetch(url),
          isA<LinkArtworkMissing>(),
          reason: url,
        );
      }
      expect(harness.requested, isEmpty, reason: 'nothing should be fetched');
    });

    test('a page that will not stop is cut off rather than filling memory',
        () async {
      // The cap is the whole point: a wrong URL should not be able to pull an
      // unbounded stream into a music player.
      final huge = 'x' * (4 * 1024 * 1024);
      final harness = serviceFor(page('<!-- $huge -->'));

      expect(
        await harness.service.fetch('https://firehose.test/artist'),
        isA<LinkArtworkMissing>(),
      );
    });
  });

  /// A site with several pages, so a link can land on the wrong one.
  ///
  /// Anything whose path matches a key in [pages] is served as HTML; anything
  /// else is served as [imageBytes], which is how a picture gets fetched.
  ({LinkArtworkService service, List<String> requested}) siteFor(
    Map<String, String> pages,
  ) {
    final requested = <String>[];
    final client = MockClient((request) async {
      requested.add(request.url.toString());
      final html = pages[request.url.path];
      if (html != null) {
        return http.Response(html, 200, headers: {
          'content-type': 'text/html; charset=utf-8',
        });
      }
      if (request.url.host == 'f4.bcbits.com') {
        return http.Response.bytes(imageBytes, 200, headers: {
          'content-type': 'image/jpeg',
        });
      }
      return http.Response('gone', 404);
    });
    return (service: LinkArtworkService(client: client), requested: requested);
  }

  /// Bandcamp's landing page is whatever the artist chose, which is sometimes
  /// a record. Then the page's own picture is a sleeve, and using it puts an
  /// album cover on the artist -- the reported bug, seen on one artist and
  /// not the next purely because of that setting.
  group('a link that lands on a release', () {
    final album = page(
      '<meta property="og:type" content="album">'
      '<meta property="og:image" content="https://f4.bcbits.com/cover.jpg">',
    );
    final discography = page(
      '<meta property="og:type" content="band">'
      '<meta property="og:image" content="https://f4.bcbits.com/photo.jpg">',
    );

    test('asks the artist page instead, and says where it ended up', () async {
      final harness = siteFor({
        '/album/resonant-whispers': album,
        '/music': discography,
      });

      final result = await harness.service
          .fetch('https://elliothsu.bandcamp.com/album/resonant-whispers');

      final found = result as LinkArtworkFound;
      expect(found.from.toString(), 'https://f4.bcbits.com/photo.jpg');
      expect(found.page.path, '/music');
      // The provenance has to name the page the picture actually came from,
      // not the link that was clicked.
      expect(found.describe(), contains('/music'));
      expect(harness.requested, [
        'https://elliothsu.bandcamp.com/album/resonant-whispers',
        'https://elliothsu.bandcamp.com/music',
        'https://f4.bcbits.com/photo.jpg',
      ]);
    });

    test('takes a page that says it is the artist at its word', () async {
      // The other half of the bug report: this one always worked, and has to
      // keep working without a second request.
      final harness = siteFor({'/': discography, '/music': album});

      final result = await harness.service.fetch('https://dmdokuro.bandcamp.com/');

      expect(
        (result as LinkArtworkFound).from.toString(),
        'https://f4.bcbits.com/photo.jpg',
      );
      expect(harness.requested, [
        'https://dmdokuro.bandcamp.com/',
        'https://f4.bcbits.com/photo.jpg',
      ]);
    });

    test('keeps the sleeve when a release is what was wanted', () async {
      final harness = siteFor({
        '/album/resonant-whispers': album,
        '/music': discography,
      });

      final result = await harness.service.fetch(
        'https://elliothsu.bandcamp.com/album/resonant-whispers',
        subject: LinkArtworkSubject.release,
      );

      expect(
        (result as LinkArtworkFound).from.toString(),
        'https://f4.bcbits.com/cover.jpg',
      );
      expect(harness.requested.where((url) => url.endsWith('/music')), isEmpty);
    });

    test('settles for the sleeve when the artist page cannot be reached',
        () async {
      // Something of theirs beats a button that appeared to do nothing, and
      // the picture is still one tap from being replaced.
      final harness = siteFor({'/album/x': album});

      final result = await harness.service.fetch('https://elliothsu.bandcamp.com/album/x');

      expect(
        (result as LinkArtworkFound).from.toString(),
        'https://f4.bcbits.com/cover.jpg',
      );
      expect(harness.requested, contains('https://elliothsu.bandcamp.com/music'));
    });

    test('does not guess a second page on a site it does not know', () async {
      // Everywhere else, an artist's page and a release's page are unrelated
      // paths. Inventing `/music` there would just be a wasted request.
      final harness = siteFor({'/release/x': album, '/music': discography});

      final result = await harness.service.fetch('https://label.test/release/x');

      expect(
        (result as LinkArtworkFound).from.toString(),
        'https://f4.bcbits.com/cover.jpg',
      );
      expect(harness.requested, [
        'https://label.test/release/x',
        'https://f4.bcbits.com/cover.jpg',
      ]);
    });

    test('will not chase its own tail from the artist page', () async {
      // A discography that somehow declares itself a release must not send
      // the fetch back to the page it is already on.
      final harness = siteFor({'/music': album});

      await harness.service.fetch('https://elliothsu.bandcamp.com/music');

      expect(
        harness.requested.where((url) => url.endsWith('/music')).length,
        1,
      );
    });
  });
}
