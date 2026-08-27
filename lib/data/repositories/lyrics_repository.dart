import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../core/logging/app_log.dart';
import '../../domain/lyrics/lyrics_document.dart';
import '../db/database.dart';

/// One lyrics document as stored, with its text already parsed.
class LyricsEntry {
  const LyricsEntry({
    required this.id,
    required this.trackId,
    required this.format,
    required this.document,
    required this.offset,
    this.language,
    this.filePath,
    this.raw,
  });

  final int id;
  final int trackId;
  final LyricsFormat format;
  final LyricsDocument document;

  /// The correction stored against this document, on top of any the file
  /// carried itself.
  final Duration offset;

  /// BCP-47 tag. Null is the original.
  final String? language;

  /// Set when a file on disk is the source of truth.
  final String? filePath;

  /// The text as stored, for the editor to put in a field.
  final String? raw;

  bool get isLinked => filePath != null;

  /// What to call this document in a language picker.
  String get label => language == null ? 'Original' : language!;
}

/// Every lyrics document a track has.
class TrackLyrics {
  const TrackLyrics({
    required this.trackId,
    this.original,
    this.translations = const [],
  });

  final int trackId;
  final LyricsEntry? original;
  final List<LyricsEntry> translations;

  bool get isEmpty => original == null && translations.isEmpty;

  /// Every document, original first.
  List<LyricsEntry> get all => [
        ?original,
        ...translations,
      ];

  LyricsEntry? forLanguage(String? language) =>
      all.where((e) => e.language == language).firstOrNull;
}

/// Reads and writes lyrics.
///
/// A track may have several documents, one per language, so a translation sits
/// beside the original rather than replacing it. The schema's unique key on
/// (track, language) is what makes "the Japanese one" and "the English one"
/// distinct rows instead of a guess about which is which.
///
/// A document can also live in a file, and then the file is the source of
/// truth: the stored text is a cache so the viewer can render before touching
/// the disk, and it is re-read when the file is newer. That is the whole point
/// of linking rather than pasting -- the lyrics stay editable in a real editor.
class LyricsRepository {
  LyricsRepository(this.db);

  final MarmeladeDatabase db;

  /// Extensions worth looking at next to an audio file.
  static const sidecarExtensions = ['.lrc', '.md', '.txt'];

  /// Watches everything a track has.
  Stream<TrackLyrics> watch(int trackId) => db
      .customSelect(
        'SELECT id, language, format, file_path, content, offset_ms '
        'FROM lyrics WHERE track_id = ?1 '
        // Original first, then translations by language.
        'ORDER BY language IS NOT NULL, language',
        variables: [Variable(trackId)],
        readsFrom: {db.lyrics},
      )
      .watch()
      .map((rows) {
        final entries = [for (final row in rows) _entry(trackId, row)];
        return TrackLyrics(
          trackId: trackId,
          original: entries.where((e) => e.language == null).firstOrNull,
          translations:
              entries.where((e) => e.language != null).toList(),
        );
      });

  LyricsEntry _entry(int trackId, QueryRow row) {
    final content = row.read<String?>('content') ?? '';
    final language = row.read<String?>('language');
    return LyricsEntry(
      id: row.read<int>('id'),
      trackId: trackId,
      format: LyricsFormat.values
              .where((f) => f.name == row.read<String>('format'))
              .firstOrNull ??
          LyricsFormat.markdown,
      document: LyricsDocument.parse(content, language: language),
      offset: Duration(milliseconds: row.read<int>('offset_ms')),
      language: language,
      filePath: row.read<String?>('file_path'),
      raw: content,
    );
  }

  /// Stores pasted or typed lyrics.
  ///
  /// Storing the text unlinks any file: a document cannot be both typed here
  /// and owned by a file on disk, and pretending otherwise means one of the two
  /// silently wins.
  Future<void> save(
    int trackId, {
    String? language,
    required String content,
    LyricsFormat format = LyricsFormat.markdown,
  }) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      await remove(trackId, language: language);
      return;
    }
    await _upsert(
      trackId: trackId,
      language: language,
      format: format,
      content: trimmed,
      filePath: null,
    );
  }

  /// Links a file, and caches what it says right now.
  Future<bool> link(
    int trackId, {
    String? language,
    required String path,
  }) async {
    final file = File(path);
    if (!file.existsSync()) return false;
    final text = await _read(file);
    if (text == null) return false;

    await _upsert(
      trackId: trackId,
      language: language,
      format: _formatOf(path),
      content: text,
      filePath: path,
    );
    return true;
  }

  /// Re-reads a linked document when the file has changed since it was stored.
  ///
  /// Returns whether anything changed, so a caller can avoid a pointless
  /// rebuild.
  Future<bool> refreshIfStale(LyricsEntry entry) async {
    final path = entry.filePath;
    if (path == null) return false;
    final file = File(path);
    if (!file.existsSync()) return false;

    final row = await db
        .customSelect(
          'SELECT updated_at FROM lyrics WHERE id = ?1',
          variables: [Variable(entry.id)],
          readsFrom: {db.lyrics},
        )
        .getSingleOrNull();
    if (row == null) return false;

    final storedAt = row.read<DateTime>('updated_at');
    if (!file.lastModifiedSync().toUtc().isAfter(storedAt)) return false;

    final text = await _read(file);
    if (text == null || text.trim() == (entry.raw ?? '').trim()) return false;

    await _upsert(
      trackId: entry.trackId,
      language: entry.language,
      format: entry.format,
      content: text.trim(),
      filePath: path,
    );
    AppLog.instance.debug(
      'lyrics reloaded from a newer file',
      fields: {'track': entry.trackId, 'path': path},
    );
    return true;
  }

  /// Shifts a document in time. Positive means the words come later.
  Future<void> setOffset(int entryId, Duration offset) async {
    await db.customUpdate(
      'UPDATE lyrics SET offset_ms = ?1, updated_at = ?2 WHERE id = ?3',
      variables: [
        Variable(offset.inMilliseconds),
        Variable(DateTime.now().toUtc()),
        Variable(entryId),
      ],
      updates: {db.lyrics},
    );
  }

  Future<void> remove(int trackId, {String? language}) async {
    await db.customUpdate(
      'DELETE FROM lyrics WHERE track_id = ?1 AND '
      '${language == null ? 'language IS NULL' : 'language = ?2'}',
      variables: [
        Variable(trackId),
        if (language != null) Variable(language),
      ],
      updates: {db.lyrics},
      updateKind: UpdateKind.delete,
    );
  }

  /// Lyrics files sitting next to a track's audio file.
  ///
  /// Named after the audio file, optionally with a language before the
  /// extension: `song.lrc`, `song.md`, `song.en.md`. Anything else in the
  /// folder is somebody else's business.
  Future<List<({String path, String? language})>> findSidecars(
    int trackId,
  ) async {
    // The absolute path is the folder plus the relative one: paths are stored
    // relative so re-rooting a library is one update to the folder row.
    final row = await db
        .customSelect(
          "SELECT lf.path AS folder_path, mf.relative_path AS relative_path "
          "FROM media_files mf "
          "JOIN library_folders lf ON lf.id = mf.folder_id "
          "WHERE mf.track_id = ?1 AND mf.status = 'present' "
          "ORDER BY mf.id LIMIT 1",
          variables: [Variable(trackId)],
          readsFrom: {db.mediaFiles, db.libraryFolders},
        )
        .getSingleOrNull();
    if (row == null) return const [];

    final audio = p.join(
      row.read<String>('folder_path'),
      row.read<String>('relative_path'),
    );
    final directory = Directory(p.dirname(audio));
    if (!directory.existsSync()) return const [];

    final stem = p.basenameWithoutExtension(audio).toLowerCase();
    final found = <({String path, String? language})>[];

    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path).toLowerCase();
      final extension = p.extension(name);
      if (!sidecarExtensions.contains(extension)) continue;

      var base = name.substring(0, name.length - extension.length);
      if (base == stem) {
        found.add((path: entity.path, language: null));
        continue;
      }
      // `song.en.md`: the audio stem, then a language.
      if (!base.startsWith('$stem.')) continue;
      final suffix = base.substring(stem.length + 1);
      if (_looksLikeLanguage(suffix)) {
        found.add((path: entity.path, language: suffix));
      }
    }

    found.sort((a, b) {
      if (a.language == null) return -1;
      if (b.language == null) return 1;
      return a.language!.compareTo(b.language!);
    });
    return found;
  }

  /// Links every sidecar found, and reports how many were new.
  Future<int> importSidecars(int trackId) async {
    var linked = 0;
    for (final sidecar in await findSidecars(trackId)) {
      final ok = await link(
        trackId,
        language: sidecar.language,
        path: sidecar.path,
      );
      if (ok) linked += 1;
    }
    return linked;
  }

  Future<void> _upsert({
    required int trackId,
    required String? language,
    required LyricsFormat format,
    required String content,
    required String? filePath,
  }) async {
    // Written as a statement because the unique key involves a nullable column,
    // and "language IS NULL" is not something an upsert on (track, language)
    // can express.
    final existing = await db
        .customSelect(
          'SELECT id FROM lyrics WHERE track_id = ?1 AND '
          '${language == null ? 'language IS NULL' : 'language = ?2'}',
          variables: [
            Variable(trackId),
            if (language != null) Variable(language),
          ],
          readsFrom: {db.lyrics},
        )
        .getSingleOrNull();

    final synced = LyricsDocument.parse(content).isSynced;
    final now = DateTime.now().toUtc();

    if (existing == null) {
      await db.into(db.lyrics).insert(
            LyricsCompanion.insert(
              trackId: trackId,
              format: Value(format),
              content: Value(content),
              filePath: Value(filePath),
              language: Value(language),
              isSynced: Value(synced),
              source: const Value(DataSource.user),
              updatedAt: Value(now),
            ),
          );
      return;
    }

    await db.customUpdate(
      'UPDATE lyrics SET content = ?1, file_path = ?2, format = ?3, '
      'is_synced = ?4, updated_at = ?5 WHERE id = ?6',
      variables: [
        Variable(content),
        Variable(filePath),
        Variable(format.name),
        Variable(synced),
        Variable(now),
        Variable(existing.read<int>('id')),
      ],
      updates: {db.lyrics},
    );
  }

  /// Reads a file as text, treating an unreadable one as absent.
  Future<String?> _read(File file) async {
    try {
      return await file.readAsString();
    } catch (error) {
      // Lyrics files are hand-made and often not UTF-8. A mis-encoded file is
      // worth a log line, not a broken page.
      AppLog.instance.warn(
        'could not read a lyrics file',
        fields: {'path': file.path, 'error': '$error'},
      );
      return null;
    }
  }

  static LyricsFormat _formatOf(String path) =>
      switch (p.extension(path).toLowerCase()) {
        '.lrc' => LyricsFormat.lrc,
        '.md' => LyricsFormat.markdown,
        _ => LyricsFormat.plainText,
      };

  /// Whether a filename suffix reads as a language tag rather than a word.
  ///
  /// Deliberately narrow: `song.en.md` is a translation, `song.instrumental.md`
  /// is not, and guessing wrong would file someone's notes as Indonesian.
  static bool _looksLikeLanguage(String suffix) =>
      RegExp(r'^[a-z]{2,3}(-[a-z0-9]{2,8})*$').hasMatch(suffix);
}
