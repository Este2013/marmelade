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
