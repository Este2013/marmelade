import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/enums.dart';
import 'package:marmelade/features/edit/link_visuals.dart';

/// Guessing a link's kind from its URL, and a real URL from an artist's name.
///
/// Both are guesses to check, not fetched facts -- no request is ever made
/// here, only a string match against the domains each site actually uses.
void main() {
  group('inferLinkKind', () {
    test('a subdomain shop counts, not just the bare domain', () {
      expect(
        inferLinkKind('https://akatsuki1030.booth.pm/'),
        LinkKind.booth,
      );
      expect(
        inferLinkKind('https://lukhash.bandcamp.com'),
        LinkKind.bandcamp,
      );
    });

    test('the well-known sites are recognised', () {
      expect(inferLinkKind('https://www.youtube.com/@LukHash'), LinkKind.youtube);
      expect(inferLinkKind('https://x.com/LukHash'), LinkKind.twitter);
      expect(inferLinkKind('https://soundcloud.com/lukhash'), LinkKind.soundcloud);
      expect(
        inferLinkKind('https://music.apple.com/artist/1'),
        LinkKind.appleMusic,
      );
      // Not the whole of apple.com -- only the music storefront.
      expect(inferLinkKind('https://apple.com/mac'), LinkKind.website);
    });

    test('an unrecognised domain is a plain website, not an error', () {
      expect(inferLinkKind('https://lukhash.com'), LinkKind.website);
    });

    test('text with no host at all falls back to other', () {
      expect(inferLinkKind('not a url'), LinkKind.other);
      expect(inferLinkKind(''), LinkKind.other);
    });
  });

  group('linkKindSuggestion', () {
    test('booth.pm follows the same subdomain shape as bandcamp', () {
      expect(
        linkKindSuggestion(LinkKind.booth, 'Akatsuki1030'),
        'https://akatsuki1030.booth.pm',
      );
    });

    test('the slug drops spaces and punctuation, not just lowercases', () {
      expect(
        linkKindSuggestion(LinkKind.bandcamp, "Koiflower, Bangler!"),
        'https://koiflowerbangler.bandcamp.com',
      );
    });

    test('a kind with no guessable pattern offers nothing', () {
      expect(linkKindSuggestion(LinkKind.spotify, 'LukHash'), isNull);
      expect(linkKindSuggestion(LinkKind.niconico, 'LukHash'), isNull);
    });

    test('an empty name has no slug to build from', () {
      expect(linkKindSuggestion(LinkKind.bandcamp, ''), isNull);
    });
  });

  group('linkKindHint', () {
    test('booth.pm gets an example matching what it actually asks for', () {
      expect(linkKindHint(LinkKind.booth), 'https://artistname.booth.pm');
    });

    test('a kind with no guessable pattern has no hint either', () {
      expect(linkKindHint(LinkKind.spotify), isNull);
    });
  });
}
