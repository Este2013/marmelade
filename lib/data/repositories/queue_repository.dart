import 'dart:math';

import 'package:drift/drift.dart';

import '../db/database.dart';

/// One entry in the play queue, with just enough track detail to render it.
class QueueEntry {
  const QueueEntry({
    required this.itemId,
    required this.trackId,
    required this.position,
    required this.title,
    required this.artistLine,
    required this.durationMs,
    required this.source,
    this.albumTitle,
    this.imagePath,
    this.sourceRefId,
    this.isMissing = false,
  });

  /// Row id in `queue_items`, so a specific entry can be removed even when the
  /// same track appears several times.
  final int itemId;

  final int trackId;
  final int position;
  final String title;
  final String artistLine;
  final int durationMs;

  /// A [QueueSource] name, so the UI can say where the track came from.
  final String source;

  final String? albumTitle;
  final String? imagePath;
  final int? sourceRefId;
  final bool isMissing;

  Duration get duration => Duration(milliseconds: durationMs);
}

/// Reads and writes the persisted play queue.
///
/// Positions are sparse - multiples of [_positionStride] - so inserting a
/// "play next" entry is one row write rather than renumbering the tail.
class QueueRepository {
  QueueRepository(this.db);

  final MarmeladeDatabase db;

  static const _positionStride = 1000;

  /// Loads the queue in order.
  Future<List<QueueEntry>> load() async {
    final rows = await db.customSelect(
      '''
      SELECT
        q.id AS item_id, q.track_id AS track_id, q.position AS position,
        q.source AS source, q.source_ref_id AS source_ref_id,
        t.title AS title, COALESCE(t.duration_ms, 0) AS duration_ms,
        alb.title AS album_title,
        ti.stored_path AS image_path,
        (SELECT group_concat(ar.name, ', ') FROM track_credits tc
          JOIN artists ar ON ar.id = tc.artist_id
         WHERE tc.track_id = t.id AND tc.role = 'mainArtist') AS artist_line,
        (SELECT COUNT(*) FROM media_files mf
          WHERE mf.track_id = t.id AND mf.status = 'present') AS present_files
      FROM queue_items q
      JOIN tracks t ON t.id = q.track_id
      LEFT JOIN albums alb ON alb.id = t.album_id
      LEFT JOIN v_track_artwork vt ON vt.track_id = t.id
      LEFT JOIN images ti ON ti.id = vt.image_id
      ORDER BY q.position, q.id
      ''',
    ).get();

    return [
      for (final row in rows)
        QueueEntry(
          itemId: row.read<int>('item_id'),
          trackId: row.read<int>('track_id'),
          position: row.read<int>('position'),
          title: row.read<String>('title'),
          artistLine: row.read<String?>('artist_line') ?? 'Unknown artist',
          durationMs: row.read<int>('duration_ms'),
          source: row.read<String>('source'),
          albumTitle: row.read<String?>('album_title'),
          imagePath: row.read<String?>('image_path'),
          sourceRefId: row.read<int?>('source_ref_id'),
          isMissing: row.read<int>('present_files') == 0,
        ),
    ];
  }

  /// Emits whenever the queue changes.
  ///
  /// Carries the row count rather than nothing, so listeners can be driven by a
  /// stream with a real value type.
  Stream<int> watchChanges() =>
      db.select(db.queueItems).watch().map((rows) => rows.length);

  /// Replaces the whole queue.
  Future<void> replaceWith(
    List<int> trackIds, {
    QueueSource source = QueueSource.user,
    int? sourceRefId,
  }) async {
    await db.transaction(() async {
      await db.delete(db.queueItems).go();
      await _appendInternal(trackIds, source, sourceRefId, startAt: 0);
    });
  }

  /// Adds to the end of the queue.
  Future<void> append(
    List<int> trackIds, {
    QueueSource source = QueueSource.user,
    int? sourceRefId,
  }) async {
    if (trackIds.isEmpty) return;
    await db.transaction(() async {
      final last = await _maxPosition();
      await _appendInternal(
        trackIds,
        source,
        sourceRefId,
        startAt: last + _positionStride,
      );
    });
  }

  /// Inserts immediately after [afterPosition], for "play next".
  ///
  /// Uses the gap between neighbouring positions, so nothing else has to move.
  /// Only when the gap is exhausted are positions rewritten.
  Future<void> insertNext(
    List<int> trackIds, {
    required int afterPosition,
    QueueSource source = QueueSource.user,
    int? sourceRefId,
  }) async {
    if (trackIds.isEmpty) return;
    await db.transaction(() async {
      final nextRow = await db.customSelect(
        'SELECT MIN(position) AS p FROM queue_items WHERE position > ?',
        variables: [Variable(afterPosition)],
      ).getSingle();
      final next = nextRow.read<int?>('p');

      // Room for the whole insert, plus one so positions stay distinct.
      final needed = trackIds.length + 1;
      if (next == null) {
        await _appendInternal(
          trackIds,
          source,
          sourceRefId,
          startAt: afterPosition + _positionStride,
        );
        return;
      }
      if (next - afterPosition < needed) {
        await _renumber();
        return insertNext(
          trackIds,
          afterPosition: afterPosition,
          source: source,
          sourceRefId: sourceRefId,
        );
      }

      final step = (next - afterPosition) ~/ needed;
      for (var i = 0; i < trackIds.length; i++) {
        await db.into(db.queueItems).insert(QueueItemsCompanion.insert(
              trackId: trackIds[i],
              position: afterPosition + step * (i + 1),
              source: Value(source),
              sourceRefId: Value(sourceRefId),
            ));
      }
    });
  }

  Future<void> _appendInternal(
    List<int> trackIds,
    QueueSource source,
    int? sourceRefId, {
    required int startAt,
  }) async {
    await db.batch((batch) {
      batch.insertAll(db.queueItems, [
        for (var i = 0; i < trackIds.length; i++)
          QueueItemsCompanion.insert(
            trackId: trackIds[i],
            position: startAt + i * _positionStride,
            source: Value(source),
            sourceRefId: Value(sourceRefId),
          ),
      ]);
    });
  }

  /// Removes one entry.
  Future<void> remove(int itemId) =>
      (db.delete(db.queueItems)..where((t) => t.id.equals(itemId))).go();

  /// Removes several entries.
  Future<void> removeAll(Iterable<int> itemIds) async {
    if (itemIds.isEmpty) return;
    await (db.delete(db.queueItems)..where((t) => t.id.isIn(itemIds))).go();
  }

  Future<void> clear() => db.delete(db.queueItems).go();

  /// Moves an entry to sit just before [beforeItemId], or to the end.
  Future<void> move(int itemId, {int? beforeItemId}) async {
    await db.transaction(() async {
      if (beforeItemId == null) {
        final last = await _maxPosition();
        await (db.update(db.queueItems)..where((t) => t.id.equals(itemId)))
            .write(QueueItemsCompanion(position: Value(last + _positionStride)));
        return;
      }

      final target = await (db.select(db.queueItems)
            ..where((t) => t.id.equals(beforeItemId)))
          .getSingleOrNull();
      if (target == null) return;

      final previousRow = await db.customSelect(
        'SELECT MAX(position) AS p FROM queue_items '
        'WHERE position < ? AND id != ?',
        variables: [Variable(target.position), Variable(itemId)],
      ).getSingle();
      final previous = previousRow.read<int?>('p') ?? (target.position - 2 * _positionStride);

      if (target.position - previous < 2) {
        await _renumber();
        return move(itemId, beforeItemId: beforeItemId);
      }

      await (db.update(db.queueItems)..where((t) => t.id.equals(itemId)))
          .write(QueueItemsCompanion(
        position: Value(previous + (target.position - previous) ~/ 2),
      ));
    });
  }

  /// Shuffles the queue once, remembering the previous order.
  ///
  /// "Shuffle once" rather than a shuffle mode: the queue is genuinely
  /// reordered, so what plays next is visible in the queue view instead of
  /// being decided invisibly at each track change. [unshuffle] puts it back.
  ///
  /// [keepItemId] stays where it is, so shuffling does not interrupt the track
  /// currently playing.
  Future<void> shuffleOnce({int? keepItemId, int? seed}) async {
    await db.transaction(() async {
      final items = await (db.select(db.queueItems)
            ..orderBy([(t) => OrderingTerm(expression: t.position)]))
          .get();
      if (items.length < 2) return;

      final random = Random(seed);
      final movable = items.where((i) => i.id != keepItemId).toList()
        ..shuffle(random);

      // The kept entry holds its slot; everything else fills the rest in the
      // shuffled order.
      final slots = [
        for (var i = 0; i < items.length; i++) i * _positionStride,
      ];
      var keptIndex = items.indexWhere((i) => i.id == keepItemId);
      if (keptIndex < 0) keptIndex = -1;

      var cursor = 0;
      for (var slot = 0; slot < slots.length; slot++) {
        final QueueItem item;
        if (slot == keptIndex) {
          item = items[keptIndex];
        } else {
          item = movable[cursor++];
        }
        await (db.update(db.queueItems)..where((t) => t.id.equals(item.id)))
            .write(QueueItemsCompanion(
          position: Value(slots[slot]),
          // Recorded once, so a second shuffle does not lose the original.
          unshuffledPosition: item.unshuffledPosition == null
              ? Value(item.position)
              : const Value.absent(),
        ));
      }
    });
  }

  /// Whether the queue is currently shuffled.
  Future<bool> isShuffled() async {
    final row = await db.customSelect(
      'SELECT COUNT(*) AS c FROM queue_items '
      'WHERE unshuffled_position IS NOT NULL',
    ).getSingle();
    return row.read<int>('c') > 0;
  }

  /// Restores the order from before the last shuffle.
  Future<void> unshuffle() async {
    await db.transaction(() async {
      final items = await (db.select(db.queueItems)
            ..where((t) => t.unshuffledPosition.isNotNull()))
          .get();
      for (final item in items) {
        await (db.update(db.queueItems)..where((t) => t.id.equals(item.id)))
            .write(QueueItemsCompanion(
          position: Value(item.unshuffledPosition!),
          unshuffledPosition: const Value(null),
        ));
      }
    });
  }

  /// Rewrites every position to restore even spacing.
  Future<void> _renumber() async {
    final items = await (db.select(db.queueItems)
          ..orderBy([
            (t) => OrderingTerm(expression: t.position),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
    for (var i = 0; i < items.length; i++) {
      await (db.update(db.queueItems)..where((t) => t.id.equals(items[i].id)))
          .write(QueueItemsCompanion(position: Value(i * _positionStride)));
    }
  }

  Future<int> _maxPosition() async {
    final row = await db
        .customSelect('SELECT COALESCE(MAX(position), 0) AS p FROM queue_items')
        .getSingle();
    return row.read<int>('p');
  }
}
