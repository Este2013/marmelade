/// Where to go looking for lyrics this machine does not have.
///
/// Links rather than a lyrics API on purpose. Fetching would mean telling a
/// third party what is playing, every time a song without lyrics comes up,
/// and the app does not otherwise talk to anyone about what is being
/// listened to. A link is the same convenience with none of that: the browser
/// makes the request, the app never learns the answer, and nothing is sent
/// unless somebody actually clicks.
///
/// The sites are the ones worth a dedicated button, in the order they tend to
/// pay off; the plain web search is last because it always works and never
/// wins. Uta-Net is deliberately absent: its search parameters could not be
/// verified, and a button that lands on an empty result page is worse than no
/// button.
library;

/// One place to look, and how to ask it.
class LyricsSite {
  const LyricsSite({
    required this.label,
    required this.note,
    required this.build,
  });

  final String label;

  /// What this one is good for, since "four search engines" is no help.
  final String note;

  final Uri Function(String query) build;

  /// The address to open for a track.
  Uri urlFor({required String title, String? artist}) =>
      build(searchTermsFor(title: title, artist: artist));
}

/// What to type into a search box for a track.
///
/// Artist first, the way people say it, and without the word "lyrics": every
/// site here searches lyrics already, and the extra word only narrows a
/// site-search wrongly. An empty artist is dropped rather than leaving a
/// leading space that some search boxes treat as part of the term.
String searchTermsFor({required String title, String? artist}) {
  final who = artist?.trim() ?? '';
  return who.isEmpty ? title.trim() : '$who ${title.trim()}';
}

final lyricsSites = <LyricsSite>[
  LyricsSite(
    label: 'LRCLIB',
    note: 'Timed lyrics you can paste straight in',
    build: (q) => Uri.https('lrclib.net', '/search/$q'),
  ),
  LyricsSite(
    label: 'Genius',
    note: 'The widest catalogue, with annotations',
    build: (q) => Uri.https('genius.com', '/search', {'q': q}),
  ),
  LyricsSite(
    label: 'Vocaloid Lyrics Wiki',
    note: 'Vocaloid and doujin, usually with a translation',
    build: (q) => Uri.https(
      'vocaloidlyrics.fandom.com',
      '/wiki/Special:Search',
      {'query': q},
    ),
  ),
  LyricsSite(
    label: 'Search the web',
    note: 'For everything the others do not have',
    build: (q) => Uri.https('duckduckgo.com', '/', {'q': '$q lyrics'}),
  ),
];
