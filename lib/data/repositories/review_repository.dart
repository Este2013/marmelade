import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/credits/credit_tokenizer.dart';
import '../db/database.dart';
import '../indexer/catalog_writer.dart';
import '../indexer/search_indexer.dart';

/// One interpretation of a credit string: the artists it would produce.
class CreditOption {
  const CreditOption({
    required this.creditedAs,
    required this.role,
    this.artistIds = const [],
  });

  /// The name this part would be credited as.
  final String creditedAs;

  /// A [SegmentRole] name: `main`, `featured` or `remixer`.
  final String role;

  /// Artists the resolver believes this part already matches.
  final List<int> artistIds;

  SegmentRole get segmentRole => switch (role) {
        'featured' => SegmentRole.featured,
        'remixer' => SegmentRole.remixer,
        _ => SegmentRole.main,
      };

  CreditOption withName(String name) =>
      CreditOption(creditedAs: name, role: role, artistIds: artistIds);

  static CreditOption fromJson(Map<String, Object?> json) => CreditOption(
        creditedAs: (json['creditedAs'] as String?) ?? '',
        role: (json['role'] as String?) ?? 'main',
        artistIds: [
          for (final id in (json['artistIds'] as List?) ?? const [])
            if (id is int) id,
        ],
      );
}

/// A credit string the resolver would not decide on, and what it suggested.
///
/// Grouped by the string itself rather than listed per track. The same field
/// usually appears on every track of a release, so a per-track list would ask
/// the same question twenty times; one decision applies to all of them.
class PendingCreditGroup {
  const PendingCreditGroup({
    required this.rawCredit,
    required this.pendingIds,
    required this.trackIds,
    required this.reason,
    required this.confidence,
    required this.whole,
    required this.parts,
    required this.sampleTitles,
  });

  final String rawCredit;

  /// Rows in `pending_credits` this group covers.
  final List<int> pendingIds;

  final List<int> trackIds;

  /// The resolver's own words for why it declined to decide.
  final String reason;

  final double confidence;

  /// What was actually applied: usually the whole string as one artist.
  final List<CreditOption> whole;

  /// The split the resolver considered but did not trust.
  final List<CreditOption> parts;

  /// A few track titles, so the string can be recognised in context.
  final List<String> sampleTitles;

  int get trackCount => trackIds.length;

  /// Whether there is a split worth offering.
  bool get hasSplit => parts.length > 1;
}

/// Reads the review queue and applies decisions to the catalog.
class ReviewRepository {
  ReviewRepository({required this.db, required this.searchIndexer});

  final MarmeladeDatabase db;
  final SearchIndexer searchIndexer;

  /// How many track titles to keep per group for context.
  static const _sampleSize = 3;

  /// Watches unresolved credits, most-affected first.
  ///
  /// Ordering by track count puts the decision that fixes the most music at the
  /// top, which is the one worth making first.
  Stream<List<PendingCreditGroup>> watchPending() {
    return db
        .customSelect(
          '''
      SELECT
        p.id AS id, p.track_id AS track_id, p.raw_credit AS raw_credit,
        p.suggestions AS suggestions, t.title AS title
      FROM pending_credits p
      JOIN tracks t ON t.id = p.track_id
      WHERE p.resolved_at IS NULL
      ORDER BY p.raw_credit, p.id
      ''',
          readsFrom: {db.pendingCredits, db.tracks},
        )
        .watch()
        .map(_group);
  }

  /// How many credits are waiting, for a badge.
  Stream<int> watchPendingCount() => db
      .customSelect(
        'SELECT COUNT(DISTINCT raw_credit) AS n FROM pending_credits '
        'WHERE resolved_at IS NULL',
        readsFrom: {db.pendingCredits},
      )
      .watch()
      .map((rows) => rows.isEmpty ? 0 : rows.first.read<int>('n'));

  List<PendingCreditGroup> _group(List<QueryRow> rows) {
    final byCredit = <String, List<QueryRow>>{};
    for (final row in rows) {
      byCredit.putIfAbsent(row.read<String>('raw_credit'), () => []).add(row);
    }

    final groups = <PendingCreditGroup>[];
    byCredit.forEach((rawCredit, rows) {
      // Every row of a group carries the same suggestion, so the first will do.
      final decoded = _decode(rows.first.read<String>('suggestions'));
      groups.add(PendingCreditGroup(
        rawCredit: rawCredit,
        pendingIds: [for (final r in rows) r.read<int>('id')],
        trackIds: [for (final r in rows) r.read<int>('track_id')],
        reason: decoded.reason,
        confidence: decoded.confidence,
        whole: decoded.whole,
        parts: decoded.parts,
        sampleTitles: [
          for (final r in rows.take(_sampleSize)) r.read<String>('title'),
        ],
      ));
    });

    groups.sort((a, b) {
      final byCount = b.trackCount.compareTo(a.trackCount);
      return byCount != 0 ? byCount : a.rawCredit.compareTo(b.rawCredit);
    });
    return groups;
  }

  static ({
    String reason,
    double confidence,
    List<CreditOption> whole,
    List<CreditOption> parts,
  }) _decode(String json) {
    List<CreditOption> read(Object? value) => [
          for (final entry in (value as List?) ?? const [])
            if (entry is Map<String, Object?>) CreditOption.fromJson(entry),
        ];

    try {
      final map = jsonDecode(json) as Map<String, Object?>;
      return (
        reason: (map['reason'] as String?) ?? 'no reason recorded',
        confidence: ((map['confidence'] as num?) ?? 0).toDouble(),
        whole: read(map['applied']),
        parts: read(map['alternative']),
      );
    } catch (_) {
      // A malformed suggestion must not hide the credit; the raw string is
      // still reviewable without it.
      return (
        reason: 'the recorded suggestion could not be read',
        confidence: 0,
        whole: const [],
        parts: const [],
      );
    }
  }

  /// Splits [group] into [parts], replacing the credit on every affected track.
  ///
  /// [parts] is passed in rather than taken from the group so the names can be
  /// corrected before applying, which is most of the point of reviewing them.
  Future<void> applySplit(
    PendingCreditGroup group,
    List<CreditOption> parts,
  ) async {
    final usable = [
      for (final part in parts)
        if (part.creditedAs.trim().isNotEmpty)
          part.withName(part.creditedAs.trim()),
    ];
    if (usable.isEmpty) return;

    final writer = CatalogWriter(db);
    final touchedArtists = <int>{};

    await db.transaction(() async {
      for (final trackId in group.trackIds) {
        // The role and position of the credit being replaced have to be read
        // from the row itself: the stored suggestion records tokenizer roles
        // ("main", "featured"), not the field's own role, so a composer credit
        // would otherwise be rewritten as a main artist.
        final existing = await db
            .customSelect(
              'SELECT id, role, sort_order FROM track_credits '
              'WHERE track_id = ?1 AND credited_as = ?2',
              variables: [Variable(trackId), Variable(group.rawCredit)],
              readsFrom: {db.trackCredits},
            )
            .get();
        if (existing.isEmpty) continue;

        final fieldRole = CreditRole.values.firstWhere(
          (r) => r.name == existing.first.read<String>('role'),
          orElse: () => CreditRole.mainArtist,
        );
        var sortOrder = existing.first.read<int>('sort_order');

        await (db.delete(db.trackCredits)
              ..where((t) =>
                  t.trackId.equals(trackId) &
                  t.creditedAs.equals(group.rawCredit)))
            .go();

        for (final part in usable) {
          final upserted = await writer.upsertArtist(
            part.creditedAs,
            candidateIds: part.artistIds,
          );
          touchedArtists.add(upserted.id);

          // A split keeps the field's own role for its lead parts, so a
          // composer field listing two people yields two composers, while a
          // "feat." inside it still yields a guest credit.
          final role = part.segmentRole == SegmentRole.main
              ? fieldRole
              : creditRoleFor(part.segmentRole);

          await db.into(db.trackCredits).insert(
                TrackCreditsCompanion.insert(
                  trackId: trackId,
                  artistId: upserted.id,
                  role: Value(role),
                  sortOrder: Value(sortOrder++),
                  creditedAs: Value(part.creditedAs),
                  // Marked as the user's decision, so a later rescan leaves it
                  // alone rather than asking the same question again.
                  source: const Value(DataSource.user),
                  confidence: const Value(1),
                ),
                mode: InsertMode.insertOrIgnore,
              );
        }
      }

      await _resolve(group.pendingIds);
      await _deleteOrphanedArtists({group.rawCredit});
    });

    for (final id in touchedArtists) {
      await searchIndexer.reindexEntity('artist', id);
    }
  }

  /// Accepts the credit as a single artist, and stops it being asked again.
  ///
  /// The never-split flag is the durable half: without it the next scan would
  /// re-tokenize the string, reach the same impasse, and park it once more.
  Future<void> keepWhole(PendingCreditGroup group) async {
    await db.transaction(() async {
      final rows = await db
          .customSelect(
            'SELECT DISTINCT artist_id FROM track_credits '
            'WHERE credited_as = ?1',
            variables: [Variable(group.rawCredit)],
            readsFrom: {db.trackCredits},
          )
          .get();

      for (final row in rows) {
        final id = row.read<int>('artist_id');
        await (db.update(db.artists)..where((t) => t.id.equals(id))).write(
          const ArtistsCompanion(
            neverSplit: Value(true),
            isVerified: Value(true),
          ),
        );
      }
      await _resolve(group.pendingIds);
    });
  }

  /// Marks the rows decided without changing any credit.
  ///
  /// For a credit that is simply not worth thinking about. It will come back if
  /// a rescan meets the same impasse, which is the honest behaviour: nothing
  /// was actually settled.
  Future<void> dismiss(PendingCreditGroup group) => _resolve(group.pendingIds);

  Future<void> _resolve(List<int> pendingIds) async {
    if (pendingIds.isEmpty) return;
    await (db.update(db.pendingCredits)..where((t) => t.id.isIn(pendingIds)))
        .write(PendingCreditsCompanion(resolvedAt: Value(DateTime.now().toUtc())));
  }

  /// Removes artists that existed only to hold a credit that has just been
  /// split apart.
  ///
  /// Without this, splitting "Koiflower,Bangler" leaves an artist of that name
  /// behind with no tracks: a dead row in the artists list, which is exactly
  /// the mess the review is meant to clear up. Only childless, unverified rows
  /// go, so a real artist who happens to have lost one credit survives.
  Future<void> _deleteOrphanedArtists(Set<String> names) async {
    for (final name in names) {
      final rows = await db
          .customSelect(
            '''
        SELECT a.id AS id FROM artists a
        WHERE a.name = ?1
          AND a.is_verified = 0
          AND a.never_split = 0
          AND NOT EXISTS (SELECT 1 FROM track_credits tc WHERE tc.artist_id = a.id)
          AND NOT EXISTS (SELECT 1 FROM albums al WHERE al.album_artist_id = a.id)
        ''',
            variables: [Variable(name)],
            readsFrom: {db.artists, db.trackCredits, db.albums},
          )
          .get();

      for (final row in rows) {
        final id = row.read<int>('id');
        await (db.delete(db.artists)..where((t) => t.id.equals(id))).go();
        await searchIndexer.removeEntity('artist', id);
      }
    }
  }
}
