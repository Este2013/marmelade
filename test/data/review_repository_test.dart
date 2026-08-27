import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/review_repository.dart';

/// Exercises the review queue against a real schema.
///
/// The value of these tests is in what applying a decision does to
/// `track_credits`: a review that half-rewrites a credit is worse than no
/// review at all, because the library then disagrees with itself.
void main() {
  late MarmeladeDatabase db;
  late ReviewRepository repository;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    repository = ReviewRepository(
      db: db,
      searchIndexer: SearchIndexer(db),
    );
  });

  tearDown(() async => db.close());

  /// Creates a track with one credit spelled exactly [creditedAs].
  Future<({int trackId, int artistId})> seedTrack({
    required String title,
    required String creditedAs,
    CreditRole role = CreditRole.mainArtist,
  }) async {
    final artistId = await db.into(db.artists).insert(
          ArtistsCompanion.insert(
            name: creditedAs,
            nameKey: creditedAs.toLowerCase(),
          ),
        );
    final trackId = await db.into(db.tracks).insert(
          TracksCompanion.insert(title: title, nameKey: title.toLowerCase()),
        );
    await db.into(db.trackCredits).insert(
          TrackCreditsCompanion.insert(
            trackId: trackId,
            artistId: artistId,
            role: Value(role),
            creditedAs: Value(creditedAs),
          ),
        );
    return (trackId: trackId, artistId: artistId);
  }

  Future<void> park({
    required int trackId,
    required String rawCredit,
    List<String> parts = const [],
    String reason = 'nothing corroborates a split here',
  }) =>
      db.into(db.pendingCredits).insert(
            PendingCreditsCompanion.insert(
              trackId: trackId,
              rawCredit: rawCredit,
              suggestions: jsonEncode({
                'raw': rawCredit,
                'reason': reason,
                'confidence': 0.4,
                'applied': [
                  {'creditedAs': rawCredit, 'role': 'main'},
                ],
                'alternative': [
                  for (final part in parts)
                    {'creditedAs': part, 'role': 'main', 'artistIds': <int>[]},
                ],
              }),
            ),
          );

  Future<List<({String name, String role, String? creditedAs, String source})>>
      creditsOf(int trackId) async {
    final rows = await db.customSelect(
      'SELECT a.name AS name, tc.role AS role, tc.credited_as AS credited_as, '
      'tc.source AS source FROM track_credits tc '
      'JOIN artists a ON a.id = tc.artist_id '
      'WHERE tc.track_id = ?1 ORDER BY tc.sort_order',
      variables: [Variable(trackId)],
    ).get();
    return [
      for (final row in rows)
        (
          name: row.read<String>('name'),
          role: row.read<String>('role'),
          creditedAs: row.read<String?>('credited_as'),
          source: row.read<String>('source'),
        ),
    ];
  }

  group('grouping', () {
    test('one card per credit string, not per track', () async {
      // The same field on every track of a release must ask once.
      for (final title in ['One', 'Two', 'Three']) {
        final seeded = await seedTrack(
          title: title,
          creditedAs: 'Koiflower,Bangler',
        );
        await park(
          trackId: seeded.trackId,
          rawCredit: 'Koiflower,Bangler',
          parts: ['Koiflower', 'Bangler'],
        );
      }

      final groups = await repository.watchPending().first;
      expect(groups, hasLength(1));
      expect(groups.single.trackCount, 3);
      expect(groups.single.sampleTitles, ['One', 'Two', 'Three']);
      expect(groups.single.parts.map((p) => p.creditedAs),
          ['Koiflower', 'Bangler']);
      expect(await repository.watchPendingCount().first, 1);
    });

    test('the most-affected credit comes first', () async {
      for (var i = 0; i < 2; i++) {
        final seeded = await seedTrack(title: 'few $i', creditedAs: 'A & B');
        await park(trackId: seeded.trackId, rawCredit: 'A & B', parts: ['A', 'B']);
      }
      for (var i = 0; i < 5; i++) {
        final seeded = await seedTrack(title: 'many $i', creditedAs: 'C & D');
        await park(trackId: seeded.trackId, rawCredit: 'C & D', parts: ['C', 'D']);
      }

      final groups = await repository.watchPending().first;
      expect(groups.map((g) => g.rawCredit), ['C & D', 'A & B']);
    });

    test('a malformed suggestion still surfaces the credit', () async {
      final seeded = await seedTrack(title: 'One', creditedAs: 'A & B');
      await db.into(db.pendingCredits).insert(
            PendingCreditsCompanion.insert(
              trackId: seeded.trackId,
              rawCredit: 'A & B',
              suggestions: 'not json at all',
            ),
          );

      final groups = await repository.watchPending().first;
      expect(groups, hasLength(1));
      expect(groups.single.hasSplit, isFalse);
      expect(groups.single.reason, contains('could not be read'));
    });
  });

  group('applySplit', () {
    test('replaces the credit on every affected track', () async {
      final tracks = <int>[];
      for (final title in ['One', 'Two']) {
        final seeded =
            await seedTrack(title: title, creditedAs: 'Koiflower,Bangler');
        tracks.add(seeded.trackId);
        await park(
          trackId: seeded.trackId,
          rawCredit: 'Koiflower,Bangler',
          parts: ['Koiflower', 'Bangler'],
        );
      }

      final group = (await repository.watchPending().first).single;
      await repository.applySplit(group, group.parts);

      for (final trackId in tracks) {
        final credits = await creditsOf(trackId);
        expect(credits.map((c) => c.name), ['Koiflower', 'Bangler']);
        expect(credits.map((c) => c.role), ['mainArtist', 'mainArtist']);
        // Marked as the user's decision, so a rescan leaves it alone.
        expect(credits.map((c) => c.source), ['user', 'user']);
      }
      expect(await repository.watchPending().first, isEmpty);
    });

    test('the composite artist row does not linger', () async {
      // A leftover "Koiflower,Bangler" with no tracks is exactly the mess the
      // review exists to clear up.
      final seeded =
          await seedTrack(title: 'One', creditedAs: 'Koiflower,Bangler');
      await park(
        trackId: seeded.trackId,
        rawCredit: 'Koiflower,Bangler',
        parts: ['Koiflower', 'Bangler'],
      );

      final group = (await repository.watchPending().first).single;
      await repository.applySplit(group, group.parts);

      final names = await db
          .customSelect('SELECT name FROM artists ORDER BY name')
          .get()
          .then((rows) => rows.map((r) => r.read<String>('name')).toList());
      expect(names, ['Bangler', 'Koiflower']);
    });

    test('keeps the field role, so a composer stays a composer', () async {
      // The stored suggestion records tokenizer roles ("main"), not the field's
      // role, so the role has to come off the row being replaced.
      final seeded = await seedTrack(
        title: 'One',
        creditedAs: 'Ryo & Nobuo',
        role: CreditRole.composer,
      );
      await park(
        trackId: seeded.trackId,
        rawCredit: 'Ryo & Nobuo',
        parts: ['Ryo', 'Nobuo'],
      );

      final group = (await repository.watchPending().first).single;
      await repository.applySplit(group, group.parts);

      final credits = await creditsOf(seeded.trackId);
      expect(credits.map((c) => c.role), ['composer', 'composer']);
    });

    test('a corrected name is what gets written', () async {
      final seeded = await seedTrack(title: 'One', creditedAs: 'Lime / Kanktsu');
      await park(
        trackId: seeded.trackId,
        rawCredit: 'Lime / Kanktsu',
        parts: ['Lime', 'Kanktsu'],
      );

      final group = (await repository.watchPending().first).single;
      await repository.applySplit(group, [
        group.parts.first,
        group.parts.last.withName('Kankitsu'),
      ]);

      final credits = await creditsOf(seeded.trackId);
      expect(credits.map((c) => c.name), ['Lime', 'Kankitsu']);
    });

    test('an emptied part is dropped rather than written blank', () async {
      final seeded = await seedTrack(title: 'One', creditedAs: 'Solo & ');
      await park(
        trackId: seeded.trackId,
        rawCredit: 'Solo & ',
        parts: ['Solo', ''],
      );

      final group = (await repository.watchPending().first).single;
      await repository.applySplit(group, group.parts);

      final credits = await creditsOf(seeded.trackId);
      expect(credits.map((c) => c.name), ['Solo']);
    });

    test('reuses an existing artist rather than creating a second', () async {
      final known = await seedTrack(title: 'Solo work', creditedAs: 'LukHash');
      final collab =
          await seedTrack(title: 'Together', creditedAs: 'LukHash x Shirobon');
      await park(
        trackId: collab.trackId,
        rawCredit: 'LukHash x Shirobon',
        parts: ['LukHash', 'Shirobon'],
      );

      final group = (await repository.watchPending().first).single;
      await repository.applySplit(group, group.parts);

      final ids = await db
          .customSelect(
            'SELECT tc.artist_id AS id FROM track_credits tc '
            'JOIN artists a ON a.id = tc.artist_id WHERE a.name = ?1',
            variables: [Variable('LukHash')],
          )
          .get();
      expect(ids.map((r) => r.read<int>('id')).toSet(), {known.artistId});
    });
  });

  group('keepWhole', () {
    test('flags the artist so a rescan stops asking', () async {
      // Without the flag the next scan re-tokenizes the string, reaches the
      // same impasse, and parks it again -- the review would never stick.
      final seeded = await seedTrack(title: 'One', creditedAs: 'Earth, Wind');
      await park(
        trackId: seeded.trackId,
        rawCredit: 'Earth, Wind',
        parts: ['Earth', 'Wind'],
      );

      final group = (await repository.watchPending().first).single;
      await repository.keepWhole(group);

      final artist = await db
          .customSelect(
            'SELECT never_split AS n, is_verified AS v FROM artists WHERE id = ?1',
            variables: [Variable(seeded.artistId)],
          )
          .getSingle();
      expect(artist.read<int>('n'), 1);
      expect(artist.read<int>('v'), 1);
      expect(await repository.watchPending().first, isEmpty);

      // The credit itself is untouched.
      final credits = await creditsOf(seeded.trackId);
      expect(credits.map((c) => c.name), ['Earth, Wind']);
    });
  });

  group('dismiss', () {
    test('clears the queue without touching any credit', () async {
      final seeded = await seedTrack(title: 'One', creditedAs: 'A & B');
      await park(trackId: seeded.trackId, rawCredit: 'A & B', parts: ['A', 'B']);

      final group = (await repository.watchPending().first).single;
      await repository.dismiss(group);

      expect(await repository.watchPending().first, isEmpty);
      final credits = await creditsOf(seeded.trackId);
      expect(credits.map((c) => c.name), ['A & B']);
      // Nothing was decided, so nothing is flagged.
      final artist = await db
          .customSelect(
            'SELECT never_split AS n FROM artists WHERE id = ?1',
            variables: [Variable(seeded.artistId)],
          )
          .getSingle();
      expect(artist.read<int>('n'), 0);
    });
  });
}
