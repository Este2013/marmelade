import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/edit_repository.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'dart:io';

/// Hand corrections, and what they do to the catalog.
///
/// Splitting and merging move every reference an artist had. Getting either
/// half wrong leaves the library disagreeing with itself, which is worse than
/// not offering the operation at all.
void main() {
  late MarmeladeDatabase db;
  late EditRepository repository;
  late Directory artRoot;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    artRoot = Directory.systemTemp.createTempSync('marmelade_edit_art_');
    repository = EditRepository(
      db: db,
      searchIndexer: SearchIndexer(db),
      artStore: ArtStore(artRoot),
    );
  });

  tearDown(() async {
    await db.close();
    if (artRoot.existsSync()) artRoot.deleteSync(recursive: true);
  });

  Future<int> artist(String name, {ArtistKind? kind}) => db
      .into(db.artists)
      .insert(ArtistsCompanion.insert(
        name: name,
        nameKey: name.toLowerCase(),
        kind: kind == null ? const Value.absent() : Value(kind),
      ));

  Future<int> album(String title, {int? albumArtistId}) => db
      .into(db.albums)
      .insert(AlbumsCompanion.insert(
        title: title,
        nameKey: title.toLowerCase(),
        albumArtistId: Value(albumArtistId),
      ));

  Future<int> track(
    String title, {
    required int artistId,
    CreditRole role = CreditRole.mainArtist,
    int? albumId,
  }) async {
    final id = await db.into(db.tracks).insert(TracksCompanion.insert(
          title: title,
          nameKey: title.toLowerCase(),
          albumId: Value(albumId),
        ));
    await db.into(db.trackCredits).insert(TrackCreditsCompanion.insert(
          trackId: id,
          artistId: artistId,
          role: Value(role),
        ));
    return id;
  }

  Future<bool> artStoreHas(String storedPath) =>
      File('${artRoot.path}/$storedPath').exists();

  Future<List<String>> artistNames() async {
    final rows =
        await db.customSelect('SELECT name FROM artists ORDER BY name').get();
    return [for (final row in rows) row.read<String>('name')];
  }

  Future<List<({String name, String role})>> creditsOf(int trackId) async {
    final rows = await db.customSelect(
      'SELECT a.name AS name, tc.role AS role FROM track_credits tc '
      'JOIN artists a ON a.id = tc.artist_id '
      'WHERE tc.track_id = ?1 ORDER BY tc.sort_order',
      variables: [Variable(trackId)],
    ).get();
    return [
      for (final row in rows)
        (name: row.read<String>('name'), role: row.read<String>('role')),
    ];
  }

  group('saveArtist', () {
    test('moves the matching key with the name', () async {
      // Without this the artist stops matching its own files on the next scan.
      final id = await artist('LukHassh');
      await repository.saveArtist(id, name: 'LukHash');

      final row = await db
          .customSelect(
            'SELECT name, name_key, is_verified FROM artists WHERE id = ?1',
            variables: [Variable(id)],
          )
          .getSingle();
      expect(row.read<String>('name'), 'LukHash');
      expect(row.read<String>('name_key'), 'lukhash');
      // Verified, so a rescan does not undo the correction.
      expect(row.read<int>('is_verified'), 1);
    });

    test('blank fields are stored as null, not as empty strings', () async {
      final id = await artist('Creo');
      await repository.saveArtist(id, name: 'Creo', description: '   ');

      final row = await db
          .customSelect(
            'SELECT description FROM artists WHERE id = ?1',
            variables: [Variable(id)],
          )
          .getSingle();
      expect(row.read<String?>('description'), isNull);
    });

    test('an empty name is refused rather than written', () async {
      final id = await artist('Creo');
      await repository.saveArtist(id, name: '   ');
      expect(await artistNames(), ['Creo']);
    });
  });

  group('aliases', () {
    test('an alias is added once, and adding it again is not an error',
        () async {
      final id = await artist('PinocchioP');
      await repository.addArtistAlias(id, 'ピノキオピー',
          kind: AliasKind.nativeScript);
      await repository.addArtistAlias(id, 'ピノキオピー');

      final artistEdit = await repository.watchArtist(id).first;
      expect(artistEdit!.aliases, hasLength(1));
      expect(artistEdit.aliases.single.alias, 'ピノキオピー');
      expect(artistEdit.aliases.single.kind, AliasKind.nativeScript);
    });

    test('an alias can be removed', () async {
      final id = await artist('REOL');
      await repository.addArtistAlias(id, 'れをる');
      final added = (await repository.watchArtist(id).first)!.aliases.single;

      await repository.removeArtistAlias(added.id);
      expect((await repository.watchArtist(id).first)!.aliases, isEmpty);
    });
  });

  group('membership', () {
    test('adding a member marks an unknown artist as a group', () async {
      // A group with members that still says "unknown" would be filed with the
      // people.
      final group = await artist('Xista');
      final member = await artist('xi');
      await repository.addMember(group, member, role: 'composer');

      final edit = (await repository.watchArtist(group).first)!;
      expect(edit.kind, ArtistKind.group);
      expect(edit.members.single.name, 'xi');
      expect(edit.members.single.role, 'composer');
    });

    test('the membership reads from both ends', () async {
      final group = await artist('Xista', kind: ArtistKind.group);
      final member = await artist('Sta');
      await repository.addMember(group, member);

      expect((await repository.watchArtist(member).first)!.memberOf.single.name,
          'Xista');
      expect((await repository.watchArtist(group).first)!.members.single.name,
          'Sta');
    });

    test('an artist cannot be its own member', () async {
      final id = await artist('Solo', kind: ArtistKind.group);
      await repository.addMember(id, id);
      expect((await repository.watchArtist(id).first)!.members, isEmpty);
    });

    test('a person kind is left alone', () async {
      // Adding a member to something already classified should not reclassify
      // it; only "unknown" is a gap worth filling in.
      final group = await artist('Duo', kind: ArtistKind.person);
      final member = await artist('Someone');
      await repository.addMember(group, member);
      expect((await repository.watchArtist(group).first)!.kind,
          ArtistKind.person);
    });
  });

  group('splitArtist', () {
    test('every credit moves to all of the parts, keeping its role', () async {
      final composite = await artist('LukHash x Shirobon');
      final one = await track('Together', artistId: composite);
      final two = await track(
        'Also together',
        artistId: composite,
        role: CreditRole.composer,
      );

      final created =
          await repository.splitArtist(composite, ['LukHash', 'Shirobon']);
      expect(created, hasLength(2));

      expect(
        await creditsOf(one),
        [
          (name: 'LukHash', role: 'mainArtist'),
          (name: 'Shirobon', role: 'mainArtist'),
        ],
      );
      // A composer field that named two people yields two composers.
      expect(
        await creditsOf(two),
        [
          (name: 'LukHash', role: 'composer'),
          (name: 'Shirobon', role: 'composer'),
        ],
      );
    });

    test('the composite artist does not linger', () async {
      final composite = await artist('A x B');
      await track('Song', artistId: composite);
      await repository.splitArtist(composite, ['A', 'B']);
      expect(await artistNames(), ['A', 'B']);
    });

    test('an existing artist is reused rather than duplicated', () async {
      final known = await artist('LukHash');
      await track('Solo work', artistId: known);
      final composite = await artist('LukHash x Shirobon');
      final collab = await track('Together', artistId: composite);

      await repository.splitArtist(composite, ['LukHash', 'Shirobon']);

      final ids = await db
          .customSelect(
            "SELECT id FROM artists WHERE name = 'LukHash'",
          )
          .get();
      expect(ids, hasLength(1));
      expect(ids.single.read<int>('id'), known);
      expect(
        (await creditsOf(collab)).map((c) => c.name),
        ['LukHash', 'Shirobon'],
      );
    });

    test('an album credited to the composite follows the first part', () async {
      final composite = await artist('A x B');
      final albumId = await album('Collab', albumArtistId: composite);
      await track('Song', artistId: composite, albumId: albumId);

      final created = await repository.splitArtist(composite, ['A', 'B']);

      final row = await db
          .customSelect(
            'SELECT album_artist_id FROM albums WHERE id = ?1',
            variables: [Variable(albumId)],
          )
          .getSingle();
      expect(row.read<int>('album_artist_id'), created.first);
    });

    test('fewer than two usable names does nothing', () async {
      // Nothing to split into is not a split, and half-applying it would take
      // the credits off the only artist there is.
      final composite = await artist('A x B');
      final song = await track('Song', artistId: composite);

      expect(await repository.splitArtist(composite, ['Only']), isEmpty);
      expect(await repository.splitArtist(composite, ['A', '   ']), isEmpty);
      expect(await creditsOf(song), [(name: 'A x B', role: 'mainArtist')]);
      expect(await artistNames(), ['A x B']);
    });
  });

  group('mergeArtists', () {
    test('credits move and the discarded name survives as an alias', () async {
      // What makes a wrong split recoverable: searching the old spelling still
      // finds the tracks.
      final keep = await artist('Camellia');
      final other = await artist('かめりあ');
      final song = await track('Track', artistId: other);

      await repository.mergeArtists(keep, [other]);

      expect(await creditsOf(song), [(name: 'Camellia', role: 'mainArtist')]);
      expect(await artistNames(), ['Camellia']);
      final edit = (await repository.watchArtist(keep).first)!;
      expect(edit.aliases.map((a) => a.alias), contains('かめりあ'));
      expect(edit.isVerified, isTrue);
    });

    test('a track credited to both ends up with one credit, not two', () async {
      final keep = await artist('Camellia');
      final other = await artist('camellia');
      final song = await track('Track', artistId: keep);
      await db.into(db.trackCredits).insert(TrackCreditsCompanion.insert(
            trackId: song,
            artistId: other,
          ));

      await repository.mergeArtists(keep, [other]);
      expect(await creditsOf(song), hasLength(1));
    });

    test('albums and memberships are repointed', () async {
      final keep = await artist('Rigel Theatre');
      final other = await artist('Rigël Theatre');
      final albumId = await album('Solringen', albumArtistId: other);
      final group = await artist('A Group', kind: ArtistKind.group);
      await repository.addMember(group, other);

      await repository.mergeArtists(keep, [other]);

      final albumRow = await db
          .customSelect(
            'SELECT album_artist_id FROM albums WHERE id = ?1',
            variables: [Variable(albumId)],
          )
          .getSingle();
      expect(albumRow.read<int>('album_artist_id'), keep);
      expect((await repository.watchArtist(group).first)!.members.single.name,
          'Rigel Theatre');
    });

    test('merging into itself is a no-op', () async {
      final keep = await artist('Solo');
      await repository.mergeArtists(keep, [keep]);
      expect(await artistNames(), ['Solo']);
    });

    test('a merge cannot leave a group as its own member', () async {
      final group = await artist('Xista', kind: ArtistKind.group);
      final member = await artist('xi');
      await repository.addMember(group, member);

      // Folding the member into the group would otherwise point the membership
      // at both ends of itself.
      await repository.mergeArtists(group, [member]);
      expect((await repository.watchArtist(group).first)!.members, isEmpty);
    });
  });

  group('albums and tracks', () {
    test('an album keeps its matching key in step', () async {
      final id = await album('Antena');
      await repository.saveAlbum(id, title: 'Antenna', releaseYear: 2023);

      final row = await db
          .customSelect(
            'SELECT title, name_key, release_year, is_verified '
            'FROM albums WHERE id = ?1',
            variables: [Variable(id)],
          )
          .getSingle();
      expect(row.read<String>('title'), 'Antenna');
      expect(row.read<String>('name_key'), 'antenna');
      expect(row.read<int>('release_year'), 2023);
      expect(row.read<int>('is_verified'), 1);
    });

    test('an album artist can be cleared', () async {
      final artistId = await artist('Someone');
      final id = await album('Compilation', albumArtistId: artistId);
      await repository.saveAlbum(id,
          title: 'Compilation', clearAlbumArtist: true, isVariousArtists: true);

      final row = await db
          .customSelect(
            'SELECT album_artist_id, is_various_artists FROM albums '
            'WHERE id = ?1',
            variables: [Variable(id)],
          )
          .getSingle();
      expect(row.read<int?>('album_artist_id'), isNull);
      expect(row.read<int>('is_various_artists'), 1);
    });

    test('track credits are replaced wholesale, in order', () async {
      final a = await artist('First');
      final b = await artist('Second');
      final id = await track('Song', artistId: a);

      await repository.setTrackCredits(id, [
        (artistId: b, role: CreditRole.mainArtist, creditedAs: 'Second'),
        (artistId: a, role: CreditRole.featured, creditedAs: null),
      ]);

      expect(await creditsOf(id), [
        (name: 'Second', role: 'mainArtist'),
        (name: 'First', role: 'featured'),
      ]);
    });

    test('a track number can be set and cleared', () async {
      final a = await artist('Someone');
      final id = await track('Song', artistId: a);

      await repository.saveTrack(id, title: 'Song', trackNo: 4, discNo: 2);
      var row = await db
          .customSelect(
            'SELECT track_no, disc_no FROM tracks WHERE id = ?1',
            variables: [Variable(id)],
          )
          .getSingle();
      expect(row.read<int?>('track_no'), 4);
      expect(row.read<int?>('disc_no'), 2);

      await repository.saveTrack(id, title: 'Song');
      row = await db
          .customSelect(
            'SELECT track_no, disc_no FROM tracks WHERE id = ?1',
            variables: [Variable(id)],
          )
          .getSingle();
      expect(row.read<int?>('track_no'), isNull);
    });
  });

  group('pictures', () {
    /// The smallest valid PNG: a 1x1 transparent pixel.
    File writePng(String name) {
      final file = File('${artRoot.path}/$name');
      file.writeAsBytesSync(const [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
      ]);
      return file;
    }

    test('a chosen picture is stored and attached', () async {
      final id = await artist('LukHash');
      expect(await repository.setArtistPicture(id, writePng('a.png')), isTrue);

      final edit = (await repository.watchArtist(id).first)!;
      expect(edit.imagePath, isNotNull);
      // Touched by hand, so a rescan leaves it alone.
      expect(edit.isVerified, isTrue);
      // And the file actually landed in the store.
      expect(await artStoreHas(edit.imagePath!), isTrue);
    });

    test('the same picture twice is stored once', () async {
      // The store is content-addressed, so choosing a file already in the
      // library must not duplicate it on disk or in the images table.
      final one = await artist('One');
      final two = await artist('Two');
      await repository.setArtistPicture(one, writePng('same.png'));
      await repository.setArtistPicture(two, writePng('same-copy.png'));

      final images = await db.customSelect('SELECT COUNT(*) AS n FROM images')
          .getSingle();
      expect(images.read<int>('n'), 1);
    });

    test('a file that is not an image is refused', () async {
      final id = await artist('Someone');
      final junk = File('${artRoot.path}/notes.txt')
        ..writeAsStringSync('this is not a picture');
      expect(await repository.setArtistPicture(id, junk), isFalse);
      expect((await repository.watchArtist(id).first)!.imagePath, isNull);
    });

    test('clearing detaches the picture but keeps the file', () async {
      final id = await artist('LukHash');
      await repository.setArtistPicture(id, writePng('b.png'));
      final stored = (await repository.watchArtist(id).first)!.imagePath!;

      await repository.clearArtistPicture(id);
      expect((await repository.watchArtist(id).first)!.imagePath, isNull);
      // Content-addressed and possibly shared, so the file stays; pruning is
      // the store's job.
      expect(await artStoreHas(stored), isTrue);
    });

    test('albums and tracks work the same way', () async {
      final artistId = await artist('Someone');
      final albumId = await album('A release');
      final trackId = await track('A song', artistId: artistId);

      expect(
        await repository.setAlbumPicture(albumId, writePng('c.png')),
        isTrue,
      );
      expect(
        await repository.setTrackPicture(trackId, writePng('d.png')),
        isTrue,
      );
      expect((await repository.watchAlbum(albumId).first)!.imagePath, isNotNull);
      expect((await repository.watchTrack(trackId).first)!.imagePath, isNotNull);
    });
  });

  group('album and track aliases', () {
    test('an album alias is added, deduplicated and removed', () async {
      final id = await album('AD:HOUSE Winter 4');
      await repository.addAlbumAlias(id, 'アドハウス',
          kind: AliasKind.nativeScript);
      await repository.addAlbumAlias(id, 'アドハウス');

      var edit = (await repository.watchAlbum(id).first)!;
      expect(edit.aliases, hasLength(1));
      expect(edit.aliases.single.kind, AliasKind.nativeScript);

      await repository.removeAlbumAlias(edit.aliases.single.id);
      edit = (await repository.watchAlbum(id).first)!;
      expect(edit.aliases, isEmpty);
    });

    test('a track alias is added and removed', () async {
      final artistId = await artist('Someone');
      final id = await track('Feel Right', artistId: artistId);
      await repository.addTrackAlias(id, 'フィールライト');

      var edit = (await repository.watchTrack(id).first)!;
      expect(edit.aliases.single.alias, 'フィールライト');

      await repository.removeTrackAlias(edit.aliases.single.id);
      edit = (await repository.watchTrack(id).first)!;
      expect(edit.aliases, isEmpty);
    });
  });

  group('findArtists', () {
    test('matches names and aliases, and honours exclusions', () async {
      final pino = await artist('PinocchioP');
      await repository.addArtistAlias(pino, 'ピノキオピー');
      final other = await artist('Pinocchio Band');

      expect(
        (await repository.findArtists('pinocchio')).map((a) => a.id),
        containsAll([pino, other]),
      );
      // Found by its native-script alias too.
      expect(
        (await repository.findArtists('ピノキオ')).map((a) => a.id),
        contains(pino),
      );
      // A group cannot be offered as its own member.
      expect(
        (await repository.findArtists('pinocchio', exclude: {pino}))
            .map((a) => a.id),
        isNot(contains(pino)),
      );
    });

    test('an empty query returns nothing rather than everything', () async {
      await artist('Someone');
      expect(await repository.findArtists('  '), isEmpty);
    });
  });

  group('the search index follows an edit', () {
    // A regression guard. The indexer keys rows by a short string ('art'),
    // and every caller used to pass the long word ('artist'): the delete
    // matched nothing, the reindex switch fell through, and searching kept
    // finding the old name forever. Nothing threw, and no other test noticed.
    Future<List<String>> indexed(SearchEntity entity, int id) async {
      final rows = await db.customSelect(
        'SELECT title FROM $ftsTokenTable '
        'WHERE entity_type = ? AND entity_id = ?',
        variables: [Variable(entity.key), Variable('$id')],
      ).get();
      return rows.map((r) => r.read<String>('title')).toList();
    }

    test('renaming an artist replaces its indexed name', () async {
      final id = await artist('Old Name');
      await SearchIndexer(db).rebuildAll();
      expect(await indexed(SearchEntity.artist, id), ['Old Name']);

      await repository.saveArtist(id, name: 'New Name');

      // Exactly one row: a reindex that inserted without deleting would leave
      // the artist findable under both names.
      expect(await indexed(SearchEntity.artist, id), ['New Name']);
    });

    test('renaming an album and a track replaces their indexed names',
        () async {
      final albumId = await album('Old Album');
      final trackId = await track('Old Track', artistId: await artist('A'));
      await SearchIndexer(db).rebuildAll();

      await repository.saveAlbum(albumId, title: 'New Album');
      await repository.saveTrack(trackId, title: 'New Track');

      expect(await indexed(SearchEntity.album, albumId), ['New Album']);
      expect(await indexed(SearchEntity.track, trackId), ['New Track']);
    });

    test('a merged-away artist leaves the index', () async {
      final keep = await artist('Keep');
      final gone = await artist('Gone');
      await SearchIndexer(db).rebuildAll();

      await repository.mergeArtists(keep, [gone]);

      expect(await indexed(SearchEntity.artist, gone), isEmpty);
      expect(await indexed(SearchEntity.artist, keep), ['Keep']);
    });
  });
}
