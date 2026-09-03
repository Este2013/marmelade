/// Progress and outcome types shared by export, import and sync.
///
/// Plain Dart with no Flutter imports, matching `IndexProgress`: the phase to
/// label mapping lives in the widget, so these stay usable from a
/// command-line tool and testable without a binding.
library;

/// Stage of a transfer job.
enum TransferPhase {
  readingLibrary,
  writingBundle,
  copyingArtwork,
  copyingAudio,
  readingBundle,
  matchingTracks,
  merging,
  rebuildingIndex,
  done,
}

/// Progress of a transfer job.
class TransferProgress {
  const TransferProgress({
    required this.phase,
    this.completed = 0,
    this.total = 0,
    this.detail,
  });

  final TransferPhase phase;
  final int completed;
  final int total;

  /// Usually what is being worked on: a track title, a machine name.
  final String? detail;

  /// Zero when there is no total to divide by, which the UI reads as
  /// "indeterminate" rather than as 0%.
  double get fraction => total == 0 ? 0 : (completed / total).clamp(0.0, 1.0);

  @override
  String toString() => 'TransferProgress(${phase.name} $completed/$total)';
}

/// How much of the library to put in a bundle.
///
/// Metadata always travels. The two heavy things are opt-in, because a bundle
/// often goes somewhere metered -- a cloud folder that syncs over a phone
/// tether, a USB stick with other things on it.
class TransferExportOptions {
  const TransferExportOptions({
    this.includeArtwork = true,
    this.includeAudio = false,
  });

  /// Copy the artwork store's files for every image the bundle references.
  /// Cheap next to audio -- a few MB for a large library -- and without it a
  /// picture someone chose by hand does not travel.
  final bool includeArtwork;

  /// Copy the audio files themselves. Off by default: this turns a bundle of
  /// a few megabytes into one the size of the music.
  final bool includeAudio;
}

/// What an importer does when both machines have a value for the same field.
enum TransferConflictPolicy {
  /// Keep what is here, and only fill in what is missing. The default,
  /// because a bundle can be older than the local edits and nothing in the
  /// schema reliably says which came first.
  keepMine,

  /// Take the bundle's value wherever it has one. For "I did the real work
  /// over there, bring it here".
  preferTheirs,
}

/// How hard to try when matching a bundle's track to a local one.
enum TransferMatchMode {
  /// Only the same audio: the payload fingerprint, or a file of the same
  /// name, size and length. What you want when the files were copied.
  sameFiles,

  /// Also accept a title, album and track-number match, so a re-encoded or
  /// re-downloaded copy of the same song still finds its ratings and tags.
  alsoByTags,
}

/// The knobs an import run offers.
class TransferImportOptions {
  const TransferImportOptions({
    this.conflicts = TransferConflictPolicy.keepMine,
    this.matching = TransferMatchMode.sameFiles,
    this.importPlaylists = true,
    this.importArtwork = true,
    this.importPlayCounts = true,
  });

  final TransferConflictPolicy conflicts;
  final TransferMatchMode matching;
  final bool importPlaylists;
  final bool importArtwork;

  /// Play and skip counts merge by taking the larger of the two, which is the
  /// only honest option: they are counters, and neither side's history is
  /// wrong.
  final bool importPlayCounts;
}

/// A track in a bundle that this machine does not have.
///
/// Not an error: it is the normal state right after tagging new music
/// elsewhere. Reported so the UI can say "copy the files over and import
/// again", which is the actual fix.
class TransferMissingTrack {
  const TransferMissingTrack({required this.title, this.artist, this.album});

  final String title;
  final String? artist;
  final String? album;

  String describe() {
    final parts = [
      if (artist != null && artist!.isNotEmpty) artist!,
      title,
      if (album != null && album!.isNotEmpty) '($album)',
    ];
    return parts.join(' - ');
  }
}

/// What an import did, or -- for a preview run -- what it would do.
///
/// Every counter is "rows actually changed", not "rows considered", so a
/// second import of the same bundle reports zeros. That is the property that
/// makes it safe to press the button twice.
class TransferReport {
  TransferReport({required this.origin, required this.exportedAt, this.preview = false});

  /// Which machine the bundle came from, for the summary line.
  final String origin;
  final DateTime exportedAt;

  /// True when nothing was written: the whole run happened inside a
  /// transaction that was rolled back.
  final bool preview;

  int artistsCreated = 0;
  int artistsUpdated = 0;
  int albumsCreated = 0;
  int albumsUpdated = 0;
  int tracksMatched = 0;
  int tracksUpdated = 0;
  int tagsCreated = 0;
  int tagLinksAdded = 0;
  int aliasesAdded = 0;
  int creditsAdded = 0;
  int linksAdded = 0;
  int membershipsAdded = 0;
  int playlistsCreated = 0;
  int playlistsUpdated = 0;
  int playlistItemsAdded = 0;
  int imagesAdded = 0;
  int artworkAttached = 0;
  int lyricsAdded = 0;
  int splitRulesAdded = 0;
  int separatorsAdded = 0;

  /// Fields where both sides had a different value and the local one was
  /// kept. Surfaced so "nothing happened" is never a silent outcome.
  int conflictsKept = 0;

  /// Tracks the bundle knows about that are not on this machine.
  final List<TransferMissingTrack> missingTracks = [];

  /// Anything that went wrong without stopping the run.
  final List<String> problems = [];

  int get changeCount =>
      artistsCreated +
      artistsUpdated +
      albumsCreated +
      albumsUpdated +
      tracksUpdated +
      tagsCreated +
      tagLinksAdded +
      aliasesAdded +
      creditsAdded +
      linksAdded +
      membershipsAdded +
      playlistsCreated +
      playlistsUpdated +
      playlistItemsAdded +
      imagesAdded +
      artworkAttached +
      lyricsAdded +
      splitRulesAdded +
      separatorsAdded;

  bool get changedNothing => changeCount == 0;

  /// A one-line summary for a snackbar. Deliberately says the two things a
  /// person wants to know: what landed, and what could not.
  String summarize() {
    if (changedNothing && missingTracks.isEmpty) {
      return 'Nothing to bring over -- this computer is already up to date.';
    }
    final parts = <String>[
      if (tracksUpdated > 0) '$tracksUpdated tracks updated',
      if (tagLinksAdded > 0) '$tagLinksAdded tags applied',
      if (creditsAdded > 0) '$creditsAdded credits added',
      if (aliasesAdded > 0) '$aliasesAdded aliases added',
      if (artistsCreated > 0) '$artistsCreated artists added',
      if (playlistsCreated > 0) '$playlistsCreated playlists added',
      if (playlistItemsAdded > 0) '$playlistItemsAdded playlist entries added',
      if (artworkAttached > 0) '$artworkAttached pictures attached',
      if (splitRulesAdded > 0) '$splitRulesAdded split rules learned',
    ];
    final head = parts.isEmpty ? 'No changes' : parts.join(' · ');
    if (missingTracks.isEmpty) return head;
    return '$head · ${missingTracks.length} tracks not on this computer yet';
  }
}

/// What an export wrote.
class TransferExportReport {
  const TransferExportReport({
    required this.path,
    required this.tracks,
    required this.artists,
    required this.playlists,
    required this.artworkFiles,
    required this.audioFiles,
    required this.bytes,
  });

  /// The bundle folder.
  final String path;
  final int tracks;
  final int artists;
  final int playlists;
  final int artworkFiles;
  final int audioFiles;

  /// Total size on disk, so the UI can warn before a metered upload.
  final int bytes;
}
