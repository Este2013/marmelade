import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/features/lyrics/lyrics_search_links.dart';

/// Sending somebody to look for lyrics elsewhere.
///
/// Links rather than a lyrics API, deliberately: fetching would mean telling
/// a third party what is playing every time a song without lyrics comes up,
/// and nothing else in this app reports what is being listened to. So what
/// matters here is that the address is right when clicked -- a button landing
/// on an empty search is worse than no button.
void main() {
  group('what goes in the search box', () {
    test('the artist first, the way somebody would say it', () {
      expect(
        searchTermsFor(title: 'Idol', artist: 'YOASOBI'),
        'YOASOBI Idol',
      );
    });

    test('just the title when nothing is credited', () {
      // No leading space: some search boxes keep it and match nothing.
      expect(searchTermsFor(title: 'Idol', artist: ''), 'Idol');
      expect(searchTermsFor(title: 'Idol'), 'Idol');
      expect(searchTermsFor(title: 'Idol', artist: '   '), 'Idol');
    });

    test('no stray whitespace from either side', () {
      expect(
        searchTermsFor(title: '  Idol  ', artist: '  YOASOBI  '),
        'YOASOBI Idol',
      );
    });

    test('the word "lyrics" is not bolted on', () {
      // Every site here searches lyrics already; the extra word narrows a
      // site search wrongly, and only the general engine wants it.
      final genius = lyricsSites.firstWhere((s) => s.label == 'Genius');
      expect(genius.urlFor(title: 'Idol', artist: 'YOASOBI').query,
          isNot(contains('lyrics')));
    });
  });

  group('the addresses themselves', () {
    test('every site builds an https address with the track in it', () {
      for (final site in lyricsSites) {
        final url = site.urlFor(title: 'Idol', artist: 'YOASOBI');
        expect(url.scheme, 'https', reason: site.label);
        expect('$url'.toLowerCase(), contains('yoasobi'), reason: site.label);
        expect(url.host, isNotEmpty, reason: site.label);
      }
    });

    test('LRCLIB takes its query as a path, not a parameter', () {
      // Its search lives at /search/<terms>; sending ?q= lands on the home
      // page, which looks like the button did nothing.
      final lrclib = lyricsSites.firstWhere((s) => s.label == 'LRCLIB');
      final url = lrclib.urlFor(title: 'Idol', artist: 'YOASOBI');

      expect(url.host, 'lrclib.net');
      // Encoded, since this is what actually gets opened.
      expect('$url', 'https://lrclib.net/search/YOASOBI%20Idol');
      expect(url.query, isEmpty);
    });

    test('a title with characters that break a URL is escaped', () {
      // Half this library is titled in Japanese, and plenty of it has & and
      // ? and # in it.
      final url = lyricsSites.first
          .urlFor(title: '夜に駆ける & more?', artist: 'YOASOBI');

      expect(() => Uri.parse('$url'), returnsNormally);
      expect('$url', isNot(contains(' ')));
    });

    test('the general search asks for lyrics, since it searches everything',
        () {
      final web = lyricsSites.last;
      expect(web.urlFor(title: 'Idol', artist: 'YOASOBI').query,
          contains('lyrics'));
    });

    test('each one says what it is good for', () {
      // Four search engines in a row is no help without it.
      for (final site in lyricsSites) {
        expect(site.note, isNotEmpty, reason: site.label);
      }
    });
  });
}
