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
    version: '0.3.2',
    date: '2026-09-09',
    headline: 'A player that remembers its place, seeks where it is told, '
        'and stops crackling.',
    changes: [
      Change.fixed(
        'Playback could crackle and sound muffled, on and off, for no '
        'obvious reason. The mixer buffer had been sized down for a sharper '
        'visualiser, which left the visualiser -- always running as the '
        "player bar's ambience, not only while a visualiser view is open -- "
        'too little headroom on the mixing thread, and it would '
        'occasionally miss a callback deadline.',
      ),
      Change.fixed(
        'Dragging the seek bar to set up where to resume, then pausing, '
        'sometimes snapped back to wherever playback last was. A seek made '
        'while paused had nothing to make the bar notice it, since its '
        'position only polls while playing.',
      ),
      Change.fixed(
        "The seek bar's knob could clip against the player above it when "
        'hovered.',
      ),
      Change.fixed(
        'Resizing the window could leave the play queue no longer showing '
        'the now-playing row, or showing the wrong "Jump to playing" pill '
        '-- nothing was watching for the viewport itself changing size, '
        'only scrolling and track changes.',
      ),
      Change.fixed(
        'Pressing play after relaunching the app always restarted the '
        'restored queue from the top. It now resumes at the track that was '
        'actually playing when the app closed.',
      ),
    ],
  ),
  ReleaseNotes(
    version: '0.3.1',
    date: '2026-09-09',
    headline: 'The real reason some tracks silently refused to play, found '
        'and fixed.',
    changes: [
      Change.fixed(
        'Some tracks failed to play with no explanation, always on files '
        'under deeply nested folders. The cause: SoLoud opens files by path '
        'natively, which on Windows is capped at 260 characters regardless '
        'of how long a path the OS otherwise allows -- reading the file '
        "ourselves and handing SoLoud the bytes directly sidesteps it, "
        'whatever the path looks like.',
      ),
      Change.added(
        'A failed play now says so on screen, with a Details button for the '
        'exact log lines -- which file, which codec, the raw error -- and a '
        'Copy button. Session logging is far more thorough throughout '
        'playback, and a new Log level setting controls how much of it gets '
        'written.',
      ),
      Change.added(
        'A right-click menu on every track row, everywhere one shows up -- '
        'previously only Songs had one. Open in Explorer and Edit track are '
        'new; the rest (play next, queue, playlists, tags) already existed '
        'in Songs and now reach every other list too.',
      ),
      Change.changed(
        'The "Add a tag" dialog shows what a track, album or artist already '
        'carries as removable chips, and applies every change immediately '
        'instead of collecting one pick to apply when the dialog closes.',
      ),
      Change.added(
        "A tag's own page lists the artists it reaches, the same way it "
        'already listed albums: artists wearing the tag directly first, '
        'then artists whose entire output happens to carry it anyway, both '
        'ordered by how much of their work is tagged.',
      ),
      Change.changed(
        "A track's Picture section shows the real fallback chain -- artist, "
        "then album, then the track's own picture, in the order each "
        'overrides the last -- instead of a single control with no sign of '
        'where the picture actually comes from. Whichever stage wins is '
        'highlighted; the album and artist cards jump to that page, and the '
        "track's own picture can be replaced or removed right there.",
      ),
    ],
  ),
  ReleaseNotes(
    version: '0.3.0',
    date: '2026-09-08',
    headline: 'A detail page keeps its name in reach, and a playlist tree '
        'finally looks like one.',
    changes: [
      Change.added(
        'Scrolling down an album, artist, tag or playlist page hands its '
        'name and its Play button to the window\'s title bar once the '
        "header itself has scrolled away, so they're never more than a "
        'glance off. Proven first on tags, now everywhere.',
      ),
      Change.added(
        "A tag's own page lists the albums it reaches, above the songs, "
        'with a Singles card for whatever has no album at all. Editing the '
        'tag moves from the title bar to beside its name, revealed on hover.',
      ),
      Change.added(
        'The play queue follows what is playing: stepping to the next or '
        'previous track scrolls just enough to keep the playing row on '
        'screen, and a "Jump to playing" pill appears when you have scrolled '
        'away from it yourself.',
      ),
      Change.added(
        'Playlists that include other playlists now actually look like it: '
        'an included playlist is indented under whatever includes it, with '
        'a chevron to fold the branch away. It used to sit at the top level '
        'with no sign it belonged anywhere.',
      ),
      Change.changed(
        'Switching to Search puts the caret in the field and selects '
        'whatever was already typed, the same as Ctrl+F. The smart-playlist '
        'sparkle icon is gone -- the row underneath already says "Follows a '
        'search".',
      ),
      Change.removed(
        'The edit-picture button over the now-playing artwork. It opens '
        'large on a click either way; the album, artist and track pages are '
        'still where you change the picture.',
      ),
      Change.fixed(
        'A hovered cover in Albums or Artists looked slightly soft compared '
        'to its neighbours -- the tile lifts a few per cent on hover, and the '
        'bitmap underneath was decoded to exactly its resting size.',
      ),
    ],
  ),
  ReleaseNotes(
    version: '0.2.4',
    date: '2026-09-07',
    headline: 'Colours that follow the music, and a player that plays what '
        'you clicked.',
    changes: [
      Change.added(
        'An "Adaptive" accent colour, which takes the whole interface -- '
        'player included -- from the artwork of whatever is playing. It '
        'survives a pause, and falls back to the Windows accent when nothing '
        'is loaded.',
      ),
      Change.added(
        "A Contrast setting: muted, default, high or highest. Material's own "
        'contrast levels, so the colours stay the colours and only the gap '
        'between text and what is behind it changes. Muted stops short of '
        'the level that would put small text under the readable minimum.',
      ),
      Change.added(
        'Eight palette styles, from the Material default through Faithful -- '
        'which keeps a muted cover muted instead of brightening it -- to '
        "Swapped, which builds the whole palette from the accent's opposite. "
        'Monochrome and the two playful ones are there for the asking.',
      ),
      Change.added(
        'The blurred artwork behind the now-playing view, and behind album '
        'and artist pages, turns its colours to match a palette style that '
        'moves the hue, so the ambiance and the interface agree rather than '
        'arguing. A switch, and it only appears when it applies.',
      ),
      Change.changed(
        'The now-playing view gives its height to the artwork: the song is '
        'named in the title bar instead of the middle of the page, and the '
        'artist and album fold onto one line once the picture would suffer '
        'for the second. Worth 40 to 120 pixels of cover on a short screen.',
      ),
      Change.fixed(
        'Clicking a song in an album that was already playing sometimes '
        'started a neighbour instead, with the right title on screen. A track '
        'ending and a click landing together were both moving the same index; '
        'they take turns now, and an advance that has been overtaken is '
        'dropped.',
      ),
      Change.fixed(
        'An artist can be found by the other names they go by. The search bar '
        'always could -- the filter boxes in Artists and Albums could not, '
        'which is what made this look like something that broke.',
      ),
      Change.added(
        'Tags on an artist reach their music: tag: in the Songs and Albums '
        "filters finds their work, the tag's own page lists both the artists "
        'wearing it and their tracks, and searching a tag name turns up the '
        'artists. The tag stays off the individual song, where it would say '
        'more about the cast than the recording.',
      ),
      Change.added(
        'A library that has lost track of files says so on launch and keeps '
        'saying so in settings. They can be kept out of the lists without '
        'deleting anything -- they come back when the drive does -- or '
        'removed outright, which asks first.',
      ),
      Change.added(
        'Lyrics that are not on this machine get a "Search the web" menu, and '
        'timing them by hand is now Ctrl+Enter: one keystroke per line, '
        'hands where the typing is.',
      ),
      Change.fixed(
        'Closing the app is immediate again. The window goes first and the '
        'cleanup happens out of sight, so a slow database close is no longer '
        'something to sit and watch.',
      ),
      Change.fixed(
        'The window can be dragged by its title bar again while the '
        'now-playing view is open.',
      ),
    ],
  ),
  ReleaseNotes(
    version: '0.2.3',
    date: '2026-09-05',
    headline: 'Music that has gone walkabout, and being told about it.',
    changes: [
      Change.added(
        'A library that has lost track of files now says so on launch, and '
        'keeps saying so in settings until the files come back or are '
        'removed. Songs whose files are gone can be kept out of the lists '
        'without deleting anything -- they return by themselves when the '
        'drive does -- or removed outright, which asks first and says what '
        'goes with them.',
      ),
      Change.changed(
        'An album only counts as gone when every track on it has gone: one '
        'missing song is a gap in a record, not a missing record. A song held '
        'as both a FLAC and an MP3 is fine as long as one of them is here.',
      ),
    ],
  ),
  ReleaseNotes(
    version: '0.2.2',
    date: '2026-09-05',
    headline: 'An import that brings the music too.',
    changes: [
      Change.added(
        'An import now copies the music a bundle carries into the library and '
        'indexes it, so the tags and ratings arriving with it have something '
        'to land on. Before, the files stayed in the bundle and every track '
        'they described was reported missing.',
      ),
      Change.added(
        'Importing into a library with no music folder says so and offers to '
        'add one, instead of bringing in metadata for files that can never '
        'exist. With several folders it asks which one the music goes in.',
      ),
      Change.changed(
        'A bundle that carries no music now says so in the import dialog. '
        'Exporting still leaves the music files off by default -- a bundle '
        'with them is as big as the library -- so this is the difference '
        'between "nothing happened" and "turn that on before exporting".',
      ),
    ],
  ),
  ReleaseNotes(
    version: '0.2.1',
    date: '2026-09-05',
    headline: 'Importing a library onto a machine that has none.',
    changes: [
      Change.fixed(
        'Importing into a library with nothing in it yet failed outright, '
        'reporting "Null check operator used on a null value" and bringing '
        'nothing in -- which is every first import on a new machine.',
      ),
      Change.fixed(
        'An import could fold two records that share a name into one, so an '
        'album released twice in different years arrived as a single album. '
        'Everything in a bundle now keeps its own identity.',
      ),
      Change.added(
        'A library with no folders yet offers to choose one, or to open '
        'settings, rather than explaining what to do and leaving no way to '
        'do it.',
      ),
      Change.fixed(
        'A transfer that fails now writes what went wrong to the log instead '
        'of only showing a line on screen.',
      ),
    ],
  ),
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
