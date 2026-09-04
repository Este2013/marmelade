/// The changelog, hand-written and compiled in.
///
/// This file is the single source of truth. `tool/changelog_json.dart` turns it
/// into the JSON that CI publishes to GitHub Pages, so there is no second copy
/// to forget: what the app shows, what the website shows and what a release
/// announces all come from here.
///
/// Being compiled in also means the running build can answer "what changed in
/// the version I am running" with no network at all, which is the question
/// asked most often and the one a download should never be needed for. The
/// published copy exists for the other question -- what a *newer* version would
/// bring -- which a build obviously cannot know about itself.
///
/// Add entries at the top. Leave [ReleaseNotes.date] null while a version is
/// still being worked on; the tag is what makes it real, and the release
/// workflow refuses to build a tag whose entry has no date.
library;

/// What kind of change an entry is.
enum ChangeKind {
  added('Added'),
  changed('Changed'),
  fixed('Fixed'),
  removed('Removed');

  const ChangeKind(this.label);

  final String label;

  static ChangeKind? of(String name) => ChangeKind.values.where((k) => k.name == name).firstOrNull;
}

/// One line of a changelog.
class Change {
  const Change(this.kind, this.text);

  const Change.added(this.text) : kind = ChangeKind.added;
  const Change.changed(this.text) : kind = ChangeKind.changed;
  const Change.fixed(this.text) : kind = ChangeKind.fixed;
  const Change.removed(this.text) : kind = ChangeKind.removed;

  final ChangeKind kind;
  final String text;

  Map<String, Object?> toJson() => {'kind': kind.name, 'text': text};

  static Change? fromJson(Object? json) {
    if (json is! Map) return null;
    final text = json['text'];
    if (text is! String || text.trim().isEmpty) return null;
    return Change(ChangeKind.of('${json['kind']}') ?? ChangeKind.changed, text);
  }
}

/// Everything one version brought.
class ReleaseNotes {
  const ReleaseNotes({required this.version, required this.changes, this.date, this.headline});

  /// The version, without a leading `v`. Matches the tag and pubspec.
  final String version;

  /// When it was released. Null means it has not been yet.
  final String? date;

  /// One sentence for the version as a whole, when there is one worth saying.
  final String? headline;

  final List<Change> changes;

  bool get isReleased => date != null;

  Iterable<Change> ofKind(ChangeKind kind) => changes.where((c) => c.kind == kind);

  Map<String, Object?> toJson() => {
    'version': version,
    if (date != null) 'date': date,
    if (headline != null) 'headline': headline,
    'changes': [for (final change in changes) change.toJson()],
  };

  static ReleaseNotes? fromJson(Object? json) {
    if (json is! Map) return null;
    final version = json['version'];
    if (version is! String || version.trim().isEmpty) return null;
    final changes = json['changes'];
    return ReleaseNotes(
      version: version,
      date: json['date'] is String ? json['date'] as String : null,
      headline: json['headline'] is String ? json['headline'] as String : null,
      changes: [
        if (changes is List)
          for (final entry in changes) ?Change.fromJson(entry),
      ],
    );
  }
}

/// Newest first.
const changelog = <ReleaseNotes>[
  ReleaseNotes(
    version: '0.2.0',
    date: '2026-09-04',
    headline: 'Lists you can work through, metadata you can fix in place, and '
        'a library that can move between computers.',
    changes: [
      Change.added(
        'A filter box in Albums, Songs and Artists that narrows the list as '
        'you type, matching titles, artists and albums, and folding accents.',
      ),
      Change.added(
        'Right-click menus on songs, albums and artists: play, play next, '
        'queue, add to a playlist, tag, and jump to the album or artist.',
      ),
      Change.added(
        'Ctrl-click and Shift-click to select several rows, with bulk actions '
        'for queueing, playlists and tagging. Selecting two or more artists '
        'also offers to merge them.',
      ),
      Change.added(
        'Artists and albums can be created from the pickers, so a credit can '
        'be corrected without leaving the editor to go and make one first.',
      ),
      Change.added(
        "A track's album can be changed or cleared from its editor.",
      ),
      Change.added(
        'Tags can be dragged between categories, and a category can be given '
        'an icon and a colour, which every one of its tags then wears '
        'wherever it appears.',
      ),
      Change.added(
        'Playlist groups fold away by clicking their heading, with a collapse '
        'all button above the list.',
      ),
      Change.changed(
        'A playlist page no longer lists its tracks twice. The contents '
        'section shows only the playlists included in it, which is the one '
        'thing the track list cannot express.',
      ),
      Change.added(
        'Clicking the artwork on an album, artist, playlist or now-playing '
        'page opens it large; hovering it offers to change the picture.',
      ),
      Change.added(
        'The smart playlist query field suggests what can come next, '
        'including real artists, albums and tags from the library.',
      ),
      Change.added(
        'Playlists can be sorted and grouped, and arranged by hand. An '
        'arrangement is remembered, applies to tracks added later, and '
        'survives a change to a smart playlist query.',
      ),
      Change.added(
        'A library can be exported and imported on another computer, so tags, '
        'aliases, links, playlists and lyrics travel with the files instead '
        'of being typed twice. Both sides may have moved on in the meantime: '
        'an import merges rather than overwrites, and shows what it would '
        'change before it changes anything.',
      ),
      Change.added(
        'Two machines can keep up with each other through one shared folder, '
        'with no server involved -- each writes only its own corner of it, so '
        'there is nothing to collide over. Sending the audio files themselves '
        'is off unless asked for.',
      ),
      Change.added(
        'The query language behind smart playlists now works in Search and in '
        'the Albums, Songs and Artists filter boxes: contains by default, '
        'exact with =, regular expressions in r"...", is: for favourites and '
        'singles, not: to invert a clause, and OR between them.',
      ),
      Change.added(
        'Suggestions appear on one line under the field rather than pushing '
        'it open, and the arrow keys and Enter pick one.',
      ),
      Change.added(
        'A playlist can be turned into a smart playlist, and a smart playlist '
        'frozen back into a fixed list of what it currently holds.',
      ),
      Change.added(
        "An artist's picture can be taken from one of their own links -- the "
        'same idea as offering a playlist the covers of the tracks in it.',
      ),
      Change.added(
        "A page's own actions sit next to its name: edit, links, and add a "
        'tag. Its links show as site badges beside its tags, one click from '
        'the page they point at.',
      ),
      Change.added('Every playlist in the list has a play button.'),
      Change.added(
        'Lyrics have their own dialog, with a scrubber for lining timings up '
        'against the song, and can be linked or dragged in from a file.',
      ),
      Change.added('The hardware media keys play, pause and skip.'),
      Change.changed(
        "Every view's toolbar now lives in the window's title bar instead of "
        'a second row beneath it, which gives the lists back a row of height '
        'and leaves one bar where there were two.',
      ),
      Change.changed(
        'Tag editing moved out of the editor forms and onto the pages the '
        'tags belong to.',
      ),
      Change.fixed(
        'The app could refuse to close. The window sat waiting on cleanup '
        'that never finished, and killing it left the library file needing '
        'repair on the next start -- which is how a library got genuinely '
        'corrupted. Nothing in the shutdown can hold the app open now, and '
        'the database is always left whole.',
      ),
      Change.fixed(
        'Links saved without an https:// prefix now open, show which site '
        'they point at, and are recognised by their domain.',
      ),
      Change.fixed(
        "A Bandcamp link that lands on a release no longer takes the record's "
        "cover as the artist's picture.",
      ),
      Change.fixed(
        'Damage to the search index is noticed and rebuilt on the spot '
        'instead of leaving search broken until the next scan.',
      ),
    ],
  ),
  ReleaseNotes(
    version: '0.2.0-beta.1',
    date: '2026-08-31',
    headline: 'Testing our updates',
    changes: [Change.added('Changelogs')],
  ),
  ReleaseNotes(
    version: '0.1.0',
    headline: 'The first build worth handing to someone else.',
    changes: [
      Change.added(
        'Artist credits are split into the artists they name, so a track '
        'tagged "Name1 x Name2" belongs to both and is found under either.',
      ),
      Change.added(
        'A review inbox for credits marmelade would rather ask about than '
        'guess at, with the interpretation it declined offered as one click.',
      ),
      Change.added(
        'Editors for artists, albums and tracks: names, other names in any '
        'script, pictures, and splitting or merging an artist.',
      ),
      Change.added(
        'Tags on tracks, albums, artists and playlists. An album or playlist '
        'passes its tags down to every track it holds.',
      ),
      Change.added(
        'Playlists that hold tracks and other playlists, and smart playlists '
        'that are a query rather than a list.',
      ),
      Change.added(
        'Search over artists, songs, albums, tags and playlists at once, '
        'matching prefixes as you type, folding diacritics, and handling '
        'substrings and Japanese.',
      ),
      Change.added(
        'Lyrics in markdown with timestamps, translations beside the '
        'original, and support for linking a file you keep editing elsewhere.',
      ),
      Change.added(
        'Light and dark themes, with the accent taken from Windows or picked '
        'from a set of colours.',
      ),
      Change.added(
        'A player with a queue, shuffle, repeat, a spectrum visualiser and a '
        'now-playing view that takes over the window.',
      ),
    ],
  ),
];
