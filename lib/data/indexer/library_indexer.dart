import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../domain/credits/credit_resolver.dart';
import '../../domain/credits/credit_tokenizer.dart';
import '../../domain/credits/separator.dart';
import '../../domain/text/normalize.dart';
import '../../services/art/art_store.dart';
import '../db/database.dart';
import '../fs/art_sidecar.dart';
import '../fs/file_identity.dart';
import '../fs/file_reconciler.dart';
import '../fs/library_scanner.dart';
import '../metadata/tag_reader.dart';
import '../metadata/track_metadata.dart';
import 'catalog_writer.dart';
import 'search_indexer.dart';

/// Stage of an index run, for progress reporting.
enum IndexPhase {
  scanning,
  reconciling,
  readingTags,
  resolvingCredits,
  writing,
  artwork,
  indexingSearch,
  done,
}

/// Progress of an index run.
class IndexProgress {
  const IndexProgress({
    required this.phase,
    this.completed = 0,
    this.total = 0,
    this.detail,
  });

  final IndexPhase phase;
  final int completed;
  final int total;

  /// Usually the file being worked on.
  final String? detail;

  double get fraction => total == 0 ? 0 : (completed / total).clamp(0.0, 1.0);

  @override
  String toString() => 'IndexProgress(${phase.name} $completed/$total)';
}

/// What an index run did.
class IndexOutcome {
  IndexOutcome({required this.scanRunId, required this.folderId});

  final int scanRunId;
  final int? folderId;

  int filesSeen = 0;
  int filesAdded = 0;
  int filesUpdated = 0;
  int filesMoved = 0;
  int filesMissing = 0;
  int filesUnreadable = 0;

  int tracksCreated = 0;
  int artistsCreated = 0;
  int albumsCreated = 0;
  int imagesStored = 0;
  int creditsWritten = 0;
  int pendingCredits = 0;
  int aliasesLearned = 0;

  Duration elapsed = Duration.zero;
  final List<String> problems = [];

  int get changeCount =>
      filesAdded + filesUpdated + filesMoved + filesMissing;

  @override
  String toString() => 'IndexOutcome(seen: $filesSeen, added: $filesAdded, '
      'updated: $filesUpdated, moved: $filesMoved, missing: $filesMissing, '
      'tracks: +$tracksCreated, artists: +$artistsCreated, '
      'pending: $pendingCredits, ${elapsed.inMilliseconds}ms)';
}

/// One file that needs its metadata written.
class _PendingFile {
  _PendingFile({
    required this.scanned,
    required this.identity,
    this.existingFileId,
    this.wasMissing = false,
  });

  final ScannedFile scanned;
  final FileIdentity identity;

  /// Null for a genuinely new file.
  final int? existingFileId;
  final bool wasMissing;

  TrackFileMetadata? metadata;
  String? error;

  // Filled in by the write pass, consumed by the artwork pass.
  int? trackId;
  int? albumId;
  int? mediaFileId;
  final List<int> mainArtistIds = [];
}

/// Indexes watched folders into the catalog.
///
/// Runs in two passes, which is what lets credit resolution reason about the
/// collection rather than one file at a time: every credit string is gathered
/// first, then resolved once the whole picture is available. See
/// docs/ARTIST-MATCHING.md.
class LibraryIndexer {
  LibraryIndexer({
    required this.db,
    required this.artStore,
    this.tagReader = const TagReader(),
    this.hasher = const FileHasher(),
    this.sidecarFinder = const ArtSidecarFinder(),
    this.resolverOptions = const ResolverOptions(),
    this.batchSize = 200,
    this.computeContentKeys = false,
  })  : writer = CatalogWriter(db),
        searchIndexer = SearchIndexer(db);

  final MarmeladeDatabase db;
  final ArtStore artStore;
  final TagReader tagReader;
  final FileHasher hasher;
  final ArtSidecarFinder sidecarFinder;
  final ResolverOptions resolverOptions;

  /// How many files to write per transaction.
  ///
  /// One transaction for a whole library would hold a write lock for minutes;
  /// one per file would fsync thousands of times.
  final int batchSize;

  /// Whether to hash the full audio payload of every indexed file.
  ///
  /// Off by default. The cheap key already drives move detection; the full key
  /// only *confirms* a match that was already very likely. Enabling it means
  /// reading every byte of the library - fine for a few hundred files,
  /// unreasonable for fifty thousand - so it is offered as a setting for people
  /// who want moves confirmed rather than merely inferred.
  final bool computeContentKeys;

  final CatalogWriter writer;
  final SearchIndexer searchIndexer;

  /// Registers a folder for indexing, or returns the existing row.
  Future<int> addFolder(String path, {String? displayName}) async {
    final normalized = p.normalize(p.absolute(path));
    final existing = await (db.select(db.libraryFolders)
          ..where((t) => t.path.equals(normalized)))
        .getSingleOrNull();
    if (existing != null) return existing.id;

    return db.into(db.libraryFolders).insert(
          LibraryFoldersCompanion.insert(
            path: normalized,
            displayName: Value(displayName),
          ),
        );
  }

  /// Indexes every enabled folder.
  Future<List<IndexOutcome>> indexAll({
    ScanTrigger trigger = ScanTrigger.manual,
    void Function(IndexProgress)? onProgress,
  }) async {
    final folders = await (db.select(db.libraryFolders)
          ..where((t) => t.enabled.equals(true))
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .get();

    final outcomes = <IndexOutcome>[];
    for (final folder in folders) {
      outcomes.add(await indexFolder(
        folder.id,
        trigger: trigger,
        onProgress: onProgress,
        rebuildSearch: false,
      ));
    }
    // One rebuild at the end rather than one per folder.
    onProgress?.call(const IndexProgress(phase: IndexPhase.indexingSearch));
    await searchIndexer.rebuildAll();
    onProgress?.call(const IndexProgress(phase: IndexPhase.done));
    return outcomes;
  }

  /// Indexes one folder.
  Future<IndexOutcome> indexFolder(
    int folderId, {
    ScanTrigger trigger = ScanTrigger.manual,
    void Function(IndexProgress)? onProgress,
    bool rebuildSearch = true,
  }) async {
    final started = DateTime.now();
    final folder = await (db.select(db.libraryFolders)
          ..where((t) => t.id.equals(folderId)))
        .getSingle();

    final scanRunId = await db.into(db.scanRuns).insert(
          ScanRunsCompanion.insert(
            folderId: Value(folderId),
            trigger: trigger,
          ),
        );
    final outcome = IndexOutcome(scanRunId: scanRunId, folderId: folderId);

    try {
      // ---- Scan ----
      onProgress?.call(IndexProgress(
        phase: IndexPhase.scanning,
        detail: folder.path,
      ));
      final excludes = (jsonDecode(folder.excludeGlobs) as List)
          .map((e) => e.toString())
          .toList();
      final scanner = LibraryScanner(excludeGlobs: excludes);
      final scan = scanner.scan(folder.path, recursive: folder.recursive);
      outcome.filesSeen = scan.files.length;
      outcome.filesUnreadable = scan.unreadable.length;

      for (final entry in scan.unreadable.entries) {
        await _recordIssue(
          scanRunId: scanRunId,
          kind: ScanIssueKind.unreadableFile,
          filePath: entry.key,
          message: entry.value,
        );
        outcome.problems.add('${p.basename(entry.key)}: ${entry.value}');
      }

      // ---- Reconcile ----
      onProgress?.call(const IndexProgress(phase: IndexPhase.reconciling));
      final known = await _loadKnownFiles(folderId);
      final plan = FileReconciler(hasher: hasher).reconcile(
        scanned: scan.files,
        known: known,
      );

      outcome.filesAdded = plan.adds.length;
      outcome.filesUpdated = plan.update.length;
      outcome.filesMoved = plan.moves.length;
      outcome.filesMissing = plan.missing.length;

      await _applyCheapOperations(plan, outcome);

      // ---- Read tags ----
      final pending = <_PendingFile>[
        for (final move in plan.moves)
          // A moved file needs no reparse unless its tags changed too, which
          // shows up as a size change.
          if (move.scanned.sizeBytes != _sizeOf(known, move.id))
            _PendingFile(
              scanned: move.scanned,
              identity: move.identity,
              existingFileId: move.id,
            ),
        for (final update in plan.update)
          _PendingFile(
            scanned: update.scanned,
            identity: update.identity,
            existingFileId: update.id,
            wasMissing: update.wasMissing,
          ),
        for (final add in plan.adds)
          _PendingFile(scanned: add.scanned, identity: add.identity),
      ];

      for (var i = 0; i < pending.length; i++) {
        final file = pending[i];
        onProgress?.call(IndexProgress(
          phase: IndexPhase.readingTags,
          completed: i,
          total: pending.length,
          detail: file.scanned.fileName,
        ));
        try {
          file.metadata = tagReader.read(file.scanned.file);
        } catch (e) {
          file.error = e.toString().split('\n').first;
          await _recordIssue(
            scanRunId: scanRunId,
            kind: ScanIssueKind.unsupportedFormat,
            filePath: file.scanned.file.path,
            message: file.error!,
          );
          outcome.problems.add('${file.scanned.fileName}: ${file.error}');
        }
      }

      // ---- Resolve credits across the whole batch ----
      onProgress?.call(const IndexProgress(phase: IndexPhase.resolvingCredits));
      final resolver = await _buildResolver(pending);

      // ---- Write ----
      var completed = 0;
      for (final chunk in _chunks(pending, batchSize)) {
        await db.transaction(() async {
          for (final file in chunk) {
            if (file.metadata == null) continue;
            await _writeFile(
              folderId: folderId,
              folderPath: folder.path,
              file: file,
              resolver: resolver,
              outcome: outcome,
            );
          }
        });
        completed += chunk.length;
        onProgress?.call(IndexProgress(
          phase: IndexPhase.writing,
          completed: completed,
          total: pending.length,
        ));
      }

      // ---- Artwork ----
      onProgress?.call(const IndexProgress(phase: IndexPhase.artwork));
      await _importArtwork(folder.path, pending, outcome);

      // ---- Search ----
      if (rebuildSearch) {
        onProgress?.call(const IndexProgress(phase: IndexPhase.indexingSearch));
        await searchIndexer.rebuildAll();
      }

      outcome.aliasesLearned = writer.aliasesAdded;
      outcome.elapsed = DateTime.now().difference(started);
      await _finishScanRun(scanRunId, outcome, ScanStatus.completed);
      await (db.update(db.libraryFolders)..where((t) => t.id.equals(folderId)))
          .write(LibraryFoldersCompanion(
        lastScanFinishedAt: Value(DateTime.now().toUtc()),
        lastScanDurationMs: Value(outcome.elapsed.inMilliseconds),
        trackedFileCount: Value(scan.files.length),
      ));

      onProgress?.call(const IndexProgress(phase: IndexPhase.done));
      return outcome;
    } catch (e, stack) {
      outcome.elapsed = DateTime.now().difference(started);
      outcome.problems.add('$e');
      await _finishScanRun(
        scanRunId,
        outcome,
        ScanStatus.failed,
        errorMessage: '$e\n$stack',
      );
      rethrow;
    }
  }

  // ------------------------------------------------------------------ helpers

  Future<List<KnownFile>> _loadKnownFiles(int folderId) async {
    final rows = await (db.select(db.mediaFiles)
          ..where((t) => t.folderId.equals(folderId)))
        .get();
    return [
      for (final row in rows)
        KnownFile(
          id: row.id,
          relativePath: row.relativePath,
          fileName: row.fileName,
          sizeBytes: row.sizeBytes,
          modifiedAt: row.modifiedAt,
          status: row.status,
          quickKey: row.quickKey,
          contentKey: row.contentKey,
        ),
    ];
  }

  static int _sizeOf(List<KnownFile> known, int id) =>
      known.firstWhere((k) => k.id == id).sizeBytes;

  /// Applies the operations that need no tag parsing.
  Future<void> _applyCheapOperations(
    ReconciliationPlan plan,
    IndexOutcome outcome,
  ) async {
    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      if (plan.keep.isNotEmpty) {
        await db.customStatement(
          'UPDATE media_files SET last_seen_at = ? WHERE id IN '
          '(${plan.keep.map((_) => '?').join(',')})',
          [now.millisecondsSinceEpoch ~/ 1000, ...plan.keep.map((k) => k.id)],
        );
      }

      for (final move in plan.moves) {
        // Repointing the row is the whole trick: the track, its rating, its
        // play count and its artwork all stay attached.
        await (db.update(db.mediaFiles)..where((t) => t.id.equals(move.id)))
            .write(MediaFilesCompanion(
          relativePath: Value(move.scanned.relativePath),
          fileName: Value(move.scanned.fileName),
          sizeBytes: Value(move.scanned.sizeBytes),
          modifiedAt: Value(move.scanned.modifiedAt),
          quickKey: Value(move.identity.quickKey),
          status: const Value(FileStatus.present),
          lastSeenAt: Value(now),
        ));
      }

      for (final missing in plan.missing) {
        // Marked, never deleted.
        await (db.update(db.mediaFiles)..where((t) => t.id.equals(missing.id)))
            .write(const MediaFilesCompanion(
          status: Value(FileStatus.missing),
        ));
      }
    });
  }

  /// Builds a resolver that knows both the library and this batch.
  Future<CreditResolver> _buildResolver(List<_PendingFile> pending) async {
    final separators = await _loadSeparators();
    final tokenizer = CreditTokenizer(separators);

    final vocabulary = await writer.loadVocabulary();
    final evidence = MapCreditEvidence();

    // Everything the library already knows, so a second folder cannot reach a
    // different conclusion than the first.
    await writer.seedEvidenceFromLibrary(evidence, tokenizer);

    // Then this batch, before anything is resolved.
    for (final file in pending) {
      final metadata = file.metadata;
      if (metadata == null) continue;
      for (final credit in metadata.mainCredits) {
        if (credit.isPreSplit) continue;
        evidence.observe(credit.value, tokenizer);
      }
      final albumArtist = metadata.albumArtistRaw;
      if (albumArtist != null) evidence.observe(albumArtist, tokenizer);
    }

    return CreditResolver(
      tokenizer: tokenizer,
      vocabulary: vocabulary,
      evidence: evidence,
      options: resolverOptions,
    );
  }

  /// Loads the user's separator configuration, falling back to the defaults.
  Future<List<SeparatorSpec>> _loadSeparators() async {
    final rows = await (db.select(db.separatorTokens)
          ..where((t) => t.enabled.equals(true))
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .get();
    if (rows.isEmpty) return defaultSeparators;
    return [
      for (final row in rows)
        SeparatorSpec(
          row.token,
          row.kind,
          requiresSpaces: row.requiresSpaces,
          isAmbiguous: row.isAmbiguous,
        ),
    ];
  }

  static Iterable<List<T>> _chunks<T>(List<T> items, int size) => [
        for (var i = 0; i < items.length; i += size)
          items.sublist(i, i + size > items.length ? items.length : i + size),
      ];

  // ------------------------------------------------------------ artwork pass

  /// Imports artwork for everything this run touched.
  ///
  /// Works a directory at a time, because artwork belongs to a folder far more
  /// often than to a file: one `cover.jpg` serves a whole album, and probing it
  /// once per folder instead of once per track is the difference between a fast
  /// scan and a slow one. Embedded pictures are only extracted when the folder
  /// offered nothing, since decoding a multi-megabyte APIC frame per track is
  /// the expensive path.
  Future<void> _importArtwork(
    String folderPath,
    List<_PendingFile> pending,
    IndexOutcome outcome,
  ) async {
    final byDirectory = <String, List<_PendingFile>>{};
    for (final file in pending) {
      if (file.metadata == null || file.trackId == null) continue;
      (byDirectory[p.dirname(file.scanned.file.path)] ??= []).add(file);
    }

    final albumsHandled = <int>{};
    final artistsHandled = <int>{};

    for (final entry in byDirectory.entries) {
      final candidates = sidecarFinder.forAlbumFolder(Directory(entry.key));
      final front = candidates
          .where((c) => c.role == ImageRole.front || c.role == ImageRole.other)
          .firstOrNull;

      // An artist portrait may sit in this folder or in a
      // "[Collection] <Artist>" ancestor, which is how the convention shows up
      // in practice.
      final artistArt = _findArtistArt(entry.key, folderPath);

      for (final file in entry.value) {
        final albumId = file.albumId;

        // 1. Folder-level cover art, applied to the album.
        if (albumId != null && front != null && albumsHandled.add(albumId)) {
          final imageId = await _storeSidecar(front, outcome);
          if (imageId != null) {
            await writer.setAlbumImageIfAbsent(albumId, imageId);
          }
        }

        // 2. Embedded art, when the folder had nothing to offer.
        if (front == null &&
            (albumId == null || !albumsHandled.contains(albumId))) {
          final imageId = await _importEmbeddedArt(file, outcome);
          if (imageId != null) {
            if (albumId != null) {
              albumsHandled.add(albumId);
              await writer.setAlbumImageIfAbsent(albumId, imageId);
            } else {
              // A loose single has nowhere else to keep its art.
              await writer.setTrackImageIfAbsent(file.trackId!, imageId);
            }
          }
        }

        // 3. Artist portrait.
        if (artistArt != null) {
          // When the portrait came from a "[Collection] <Artist>" folder, it
          // belongs to that artist alone. Applying it to every artist in the
          // tree would hand the collection owner's photo to each guest and
          // collaborator that appears inside it.
          final targets = artistArt.artistName != null
              ? await _artistIdsNamed(artistArt.artistName!)
              : file.mainArtistIds;

          for (final artistId in targets) {
            if (!artistsHandled.add(artistId)) continue;
            final imageId = await _storeSidecar(
              artistArt.candidate,
              outcome,
              role: ImageRole.artist,
            );
            if (imageId != null) {
              await writer.setArtistImageIfAbsent(artistId, imageId);
            }
          }
        }
      }
    }
  }

  Future<int?> _storeSidecar(
    ArtCandidate candidate,
    IndexOutcome outcome, {
    ImageRole? role,
  }) async {
    final stored = await artStore.putFile(candidate.file);
    if (stored == null) return null;
    if (!stored.wasAlreadyStored) outcome.imagesStored++;
    return writer.upsertImage(
      sha256: stored.sha256,
      storedPath: stored.storedPath,
      mimeType: stored.mimeType,
      byteSize: stored.byteSize,
      width: stored.width,
      height: stored.height,
      kind: ImageKind.sidecar,
      role: role ?? ImageRole.front,
      sourceDescription: '${p.basename(candidate.file.path)} '
          '(${candidate.reason})',
    );
  }

  Future<int?> _importEmbeddedArt(
    _PendingFile file,
    IndexOutcome outcome,
  ) async {
    TrackFileMetadata withPictures;
    try {
      withPictures = tagReader.read(file.scanned.file, includePictures: true);
    } catch (_) {
      return null;
    }
    if (withPictures.pictures.isEmpty) return null;

    // Prefer a declared front cover over whatever happened to come first.
    final pictures = withPictures.pictures;
    final picture = pictures.firstWhere(
      (pic) => pic.role == ImageRole.front,
      orElse: () => pictures.first,
    );

    final stored = await artStore.putBytes(picture.bytes);
    if (stored == null) return null;
    if (!stored.wasAlreadyStored) outcome.imagesStored++;

    return writer.upsertImage(
      sha256: stored.sha256,
      storedPath: stored.storedPath,
      mimeType: stored.mimeType,
      byteSize: stored.byteSize,
      width: stored.width,
      height: stored.height,
      kind: ImageKind.embedded,
      role: picture.role,
      sourceFileId: file.mediaFileId,
      sourceDescription: 'embedded in ${file.scanned.fileName}',
    );
  }

  /// Looks for an artist portrait here, then in each ancestor up to the
  /// library root.
  ///
  /// [artistName] is set when the containing folder names its artist, as
  /// `[Collection] <Artist>` does. That turns the portrait from "some artist in
  /// this tree" into "this specific artist", which is the difference between
  /// getting it right and handing one artist's photo to everyone they ever
  /// collaborated with.
  ({ArtCandidate candidate, String? artistName})? _findArtistArt(
    String directory,
    String folderRoot,
  ) {
    var current = directory;
    for (var depth = 0; depth < 6; depth++) {
      final found = sidecarFinder.forArtistFolder(Directory(current));
      if (found.isNotEmpty) {
        return (
          candidate: found.first,
          artistName: ArtSidecarFinder.artistNameFromFolder(
            p.basename(current),
          ),
        );
      }

      if (p.equals(current, folderRoot)) break;
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return null;
  }

  /// Artists whose canonical name or an alias matches [name].
  Future<List<int>> _artistIdsNamed(String name) async {
    final key = normalizeKey(name);
    if (key.isEmpty) return const [];
    final rows = await db.customSelect(
      'SELECT id FROM artists WHERE name_key = ? '
      'UNION '
      'SELECT artist_id AS id FROM artist_aliases WHERE alias_key = ?',
      variables: [Variable(key), Variable(key)],
    ).get();
    return rows.map((r) => r.read<int>('id')).toList();
  }

  // -------------------------------------------------------------- write pass

  /// Writes one file's metadata: album, track, credits, tags and the file row.
  Future<void> _writeFile({
    required int folderId,
    required String folderPath,
    required _PendingFile file,
    required CreditResolver resolver,
    required IndexOutcome outcome,
  }) async {
    final md = file.metadata!;
    final scanned = file.scanned;
    final title = md.title ?? _titleFromFileName(scanned.fileName);

    // ---- Album artist ----
    int? albumArtistId;
    var isVariousArtists = false;
    final albumArtistRaw = md.albumArtistRaw;
    if (albumArtistRaw != null) {
      final resolution = resolver.resolve(albumArtistRaw);
      if (resolution.outcome == ResolutionOutcome.compilation) {
        // "Various Artists" describes the release, not a performer.
        isVariousArtists = true;
      } else if (resolution.isActionable && resolution.credits.isNotEmpty) {
        final primary = resolution.credits.first;
        final upserted = await writer.upsertArtist(
          primary.creditedAs,
          candidateIds: primary.candidateArtistIds,
          aliases: primary.aliases,
        );
        albumArtistId = upserted.id;
        if (upserted.created) outcome.artistsCreated++;
      }
    }

    // ---- Album ----
    int? albumId;
    if (md.albumTitle != null) {
      final album = await writer.upsertAlbum(
        title: md.albumTitle!,
        albumArtistId: albumArtistId,
        year: md.year,
        month: md.month,
        day: md.day,
        totalTracks: md.trackTotal,
        totalDiscs: md.discTotal,
        folderHint: p.dirname(scanned.file.path),
        isVariousArtists: isVariousArtists,
        kind: md.isCompilation ? AlbumKind.compilation : AlbumKind.unknown,
      );
      albumId = album.id;
      if (album.created) outcome.albumsCreated++;
      if (albumArtistId != null) {
        await writer.upsertAlbumCredit(
          albumId: albumId,
          artistId: albumArtistId,
          creditedAs: albumArtistRaw,
        );
      }
    }
    file.albumId = albumId;

    // ---- Track ----
    var trackId = file.existingFileId == null
        ? null
        : await _trackIdOfFile(file.existingFileId!);

    trackId ??= await writer.findExistingTrack(
      contentKey: file.identity.contentKey,
      title: title,
      albumId: albumId,
      trackNo: md.trackNo,
      discNo: md.discNo,
    );

    if (trackId == null) {
      trackId = await writer.insertTrack(
        title: title,
        albumId: albumId,
        trackNo: md.trackNo,
        discNo: md.discNo,
        durationMs: md.duration?.inMilliseconds,
        year: md.year,
        bpm: md.bpm,
        initialKey: md.initialKey,
        comment: md.comment,
        rating: md.rating,
      );
      outcome.tracksCreated++;
    } else {
      await writer.refreshTrack(
        trackId,
        title: title,
        albumId: albumId,
        trackNo: md.trackNo,
        discNo: md.discNo,
        durationMs: md.duration?.inMilliseconds,
        year: md.year,
      );
    }
    file.trackId = trackId;

    await _writeCredits(
      trackId: trackId,
      metadata: md,
      resolver: resolver,
      file: file,
      outcome: outcome,
    );
    await _writeTags(trackId, md);

    // Lyrics that travelled inside the file.
    if (md.lyrics != null) {
      await db.into(db.lyrics).insert(
            LyricsCompanion.insert(
              trackId: trackId,
              format: const Value(LyricsFormat.plainText),
              content: Value(md.lyrics),
              source: const Value(DataSource.fileMetadata),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }

    file.mediaFileId = await _writeMediaFile(
      folderId: folderId,
      file: file,
      trackId: trackId,
      metadata: md,
    );
  }

  /// Resolves and writes every artist credit on a track.
  Future<void> _writeCredits({
    required int trackId,
    required TrackFileMetadata metadata,
    required CreditResolver resolver,
    required _PendingFile file,
    required IndexOutcome outcome,
  }) async {
    final companions = <TrackCreditsCompanion>[];
    var sortOrder = 0;

    for (final raw in metadata.credits) {
      // A field that already listed its artists separately is authoritative.
      // Running heuristics over it could only make a well-tagged file worse.
      if (raw.isPreSplit) {
        // Even so, a compilation marker is not a performer. Taggers put
        // "Various Artists" in artist fields often enough that skipping this
        // check creates a phantom artist with hundreds of tracks.
        if (compilationMarkers.contains(normalizeKey(raw.value))) continue;

        final upserted = await writer.upsertArtist(raw.value);
        final artistId = upserted.id;
        if (upserted.created) outcome.artistsCreated++;
        companions.add(TrackCreditsCompanion.insert(
          trackId: trackId,
          artistId: artistId,
          role: Value(raw.role),
          sortOrder: Value(sortOrder++),
          creditedAs: Value(raw.value),
          source: const Value(DataSource.fileMetadata),
          confidence: const Value(1),
        ));
        if (raw.role == CreditRole.mainArtist) file.mainArtistIds.add(artistId);
        continue;
      }

      final resolution = resolver.resolve(raw.value);
      if (resolution.outcome == ResolutionOutcome.compilation ||
          resolution.outcome == ResolutionOutcome.empty) {
        continue;
      }

      if (resolution.outcome == ResolutionOutcome.needsReview) {
        // Park the decision rather than guess. The conservative reading is
        // still applied, so the track is never left without an artist.
        await writer.recordPendingCredit(
          trackId: trackId,
          rawCredit: raw.value,
          suggestionsJson: _encodeSuggestions(resolution),
        );
        outcome.pendingCredits++;
      }

      for (final credit in resolution.credits) {
        final upserted = await writer.upsertArtist(
          credit.creditedAs,
          candidateIds: credit.candidateArtistIds,
          aliases: credit.aliases,
        );
        final artistId = upserted.id;
        if (upserted.created) outcome.artistsCreated++;

        // A split keeps the field's own role for its lead parts, so a composer
        // field listing two people yields two composers, while a "feat."
        // inside it still yields a guest credit.
        final role = credit.role == SegmentRole.main
            ? raw.role
            : creditRoleFor(credit.role);

        companions.add(TrackCreditsCompanion.insert(
          trackId: trackId,
          artistId: artistId,
          role: Value(role),
          sortOrder: Value(sortOrder++),
          creditedAs: Value(credit.creditedAs),
          source: Value(_sourceFor(resolution.outcome)),
          confidence: Value(resolution.confidence),
        ));
        if (role == CreditRole.mainArtist) file.mainArtistIds.add(artistId);
      }
    }

    await writer.replaceTrackCredits(trackId, companions);
    outcome.creditsWritten += companions.length;
  }

  static DataSource _sourceFor(ResolutionOutcome outcome) => switch (outcome) {
        ResolutionOutcome.split ||
        ResolutionOutcome.aliasPair =>
          DataSource.inferredFromSplit,
        _ => DataSource.fileMetadata,
      };

  static String _encodeSuggestions(CreditResolution resolution) => jsonEncode({
        'raw': resolution.raw,
        'reason': resolution.reason,
        'confidence': resolution.confidence,
        'applied': [
          for (final c in resolution.credits)
            {'creditedAs': c.creditedAs, 'role': c.role.name},
        ],
        'alternative': [
          for (final c in resolution.alternative)
            {
              'creditedAs': c.creditedAs,
              'role': c.role.name,
              'artistIds': c.candidateArtistIds,
            },
        ],
      });

  /// Writes genre and language tags into their system categories.
  Future<void> _writeTags(int trackId, TrackFileMetadata metadata) async {
    final tagIds = <int>[];

    if (metadata.genres.isNotEmpty) {
      final categoryId =
          await writer.upsertTagCategory(systemTagCategoryGenre, 'Genre');
      for (final genre in metadata.genres) {
        tagIds.add(await writer.upsertTag(name: genre, categoryId: categoryId));
      }
    }
    if (metadata.languages.isNotEmpty) {
      final categoryId =
          await writer.upsertTagCategory(systemTagCategoryLanguage, 'Language');
      for (final language in metadata.languages) {
        tagIds.add(await writer.upsertTag(
          name: _prettyLanguage(language),
          categoryId: categoryId,
        ));
      }
    }

    if (tagIds.isNotEmpty) {
      await writer.replaceMetadataTags(trackId, tagIds);
    }
  }

  /// Inserts or updates the `media_files` row.
  Future<int> _writeMediaFile({
    required int folderId,
    required _PendingFile file,
    required int trackId,
    required TrackFileMetadata metadata,
  }) async {
    final scanned = file.scanned;
    final contentKey = computeContentKeys
        ? (file.identity.contentKey ?? _tryContentKey(scanned.file))
        : file.identity.contentKey;
    final now = DateTime.now().toUtc();

    final values = MediaFilesCompanion(
      folderId: Value(folderId),
      relativePath: Value(scanned.relativePath),
      fileName: Value(scanned.fileName),
      extension: Value(scanned.extension),
      sizeBytes: Value(scanned.sizeBytes),
      modifiedAt: Value(scanned.modifiedAt),
      quickKey: Value(file.identity.quickKey),
      contentKey: Value(contentKey),
      codec: Value(metadata.codec),
      bitrate: Value(metadata.bitrate),
      sampleRate: Value(metadata.sampleRate),
      channels: Value(metadata.channels),
      bitDepth: Value(metadata.bitDepth),
      lossless: Value(metadata.lossless),
      durationMs: Value(metadata.duration?.inMilliseconds),
      replayGainDb: Value(metadata.replayGainDb),
      replayGainPeak: Value(metadata.replayGainPeak),
      status: const Value(FileStatus.present),
      trackId: Value(trackId),
      lastSeenAt: Value(now),
      lastIndexedAt: Value(now),
      errorMessage: const Value(null),
    );

    final existingId = file.existingFileId;
    if (existingId != null) {
      await (db.update(db.mediaFiles)..where((t) => t.id.equals(existingId)))
          .write(values);
      return existingId;
    }
    return db
        .into(db.mediaFiles)
        .insert(values.copyWith(firstSeenAt: Value(now)));
  }

  String? _tryContentKey(File file) {
    try {
      return hasher.contentKey(file);
    } on FileSystemException {
      return null;
    }
  }

  Future<int?> _trackIdOfFile(int mediaFileId) async {
    final row = await (db.select(db.mediaFiles)
          ..where((t) => t.id.equals(mediaFileId)))
        .getSingleOrNull();
    return row?.trackId;
  }

  /// Derives a title from a filename when the file carries no tags.
  ///
  /// Strips the extension and a leading track number, and nothing else. In
  /// particular it does not try to read an artist out of an
  /// "Artist - Title" filename: that pattern is real but so are titles
  /// containing a dash, and inventing an artist produces plausible nonsense
  /// that is then hard to notice and correct. An untagged file gets a title and
  /// no credits, which is honest and easy to fix.
  ///
  /// The number is capped at three digits so a title opening with a year
  /// survives. A title genuinely starting with a small number - "99
  /// Luftballons" - does lose it, which is the accepted cost of handling the
  /// far more common "07 Title" convention. Only untagged files reach here.
  static String _titleFromFileName(String fileName) {
    var stem = p.basenameWithoutExtension(fileName);
    final stripped =
        stem.replaceFirst(RegExp(r'^\s*\d{1,3}\s*[-._)]?\s+'), '');
    // Never strip everything away, and never leave a fragment.
    if (stripped.length >= 2 && !RegExp(r'^\d').hasMatch(stripped)) {
      stem = stripped;
    }
    stem = stem.replaceAll(RegExp(r'\s+'), ' ').trim();
    return stem.isEmpty ? fileName : stem;
  }

  /// Turns a language tag into something worth showing on a chip.
  static String _prettyLanguage(String code) {
    final normalized = code.trim().toLowerCase();
    const names = <String, String>{
      'eng': 'English', 'en': 'English',
      'jpn': 'Japanese', 'ja': 'Japanese',
      'fra': 'French', 'fre': 'French', 'fr': 'French',
      'deu': 'German', 'ger': 'German', 'de': 'German',
      'spa': 'Spanish', 'es': 'Spanish',
      'ita': 'Italian', 'it': 'Italian',
      'kor': 'Korean', 'ko': 'Korean',
      'zho': 'Chinese', 'chi': 'Chinese', 'zh': 'Chinese',
      'rus': 'Russian', 'ru': 'Russian',
      'por': 'Portuguese', 'pt': 'Portuguese',
      'nld': 'Dutch', 'dut': 'Dutch', 'nl': 'Dutch',
      'swe': 'Swedish', 'sv': 'Swedish',
      'pol': 'Polish', 'pl': 'Polish',
      'zxx': 'Instrumental',
    };
    return names[normalized] ?? code.trim();
  }

  Future<void> _recordIssue({
    required int scanRunId,
    required ScanIssueKind kind,
    String? filePath,
    required String message,
    String? detail,
  }) =>
      db.into(db.scanIssues).insert(
            ScanIssuesCompanion.insert(
              scanRunId: Value(scanRunId),
              kind: kind,
              filePath: Value(filePath),
              message: message,
              detail: Value(detail),
            ),
          );

  Future<void> _finishScanRun(
    int scanRunId,
    IndexOutcome outcome,
    ScanStatus status, {
    String? errorMessage,
  }) =>
      (db.update(db.scanRuns)..where((t) => t.id.equals(scanRunId)))
          .write(ScanRunsCompanion(
        status: Value(status),
        finishedAt: Value(DateTime.now().toUtc()),
        filesSeen: Value(outcome.filesSeen),
        filesAdded: Value(outcome.filesAdded),
        filesUpdated: Value(outcome.filesUpdated),
        filesMoved: Value(outcome.filesMoved),
        filesMissing: Value(outcome.filesMissing),
        errorCount: Value(outcome.problems.length),
        errorMessage: Value(errorMessage),
      ));
}
