import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/transfer/library_exporter.dart';
import 'package:marmelade/data/transfer/transfer_bundle.dart';

/// Moving hand-entered data between two computers.
///
/// The scenario every test here is a variation of: the same music sits on two
/// machines, work was done on one of them, and none of it should have to be
/// done twice. What makes that hard is that both sides drift -- so the tests
/// care less about "did the field copy" than about "did importing lose
/// something that was only here".
void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() => db.close());

  const origin = TransferOrigin(
    machineId: 'machine-a',
    machineName: 'Work PC',
    appVersion: '1.0.0',
  );

  /// A library folder, needed because every file row hangs off one.
  Future<int> folder([String path = r'C:\Music']) =>
      db.into(db.libraryFolders).insert(
            LibraryFoldersCompanion.insert(path: path),
          );

  Future<int> artist(
    String name, {
    bool neverSplit = false,
    bool isVerified = false,
    String? disambiguation,
  }) =>
      db.into(db.artists).insert(ArtistsCompanion.insert(
            name: name,
            nameKey: name.toLowerCase(),
            neverSplit: Value(neverSplit),
            isVerified: Value(isVerified),
            disambiguation: Value(disambiguation),
          ));

  Future<int> album(String title, {int? year, int? artistId}) =>
      db.into(db.albums).insert(AlbumsCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
            releaseYear: Value(year),
            albumArtistId: Value(artistId),
          ));

  Future<int> track(
    String title, {
    int? albumId,
    int? rating,
    bool isFavorite = false,
    int playCount = 0,
    int? trackNo,
  }) =>
      db.into(db.tracks).insert(TracksCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
            albumId: Value(albumId),
            rating: Value(rating),
            isFavorite: Value(isFavorite),
            playCount: Value(playCount),
            trackNo: Value(trackNo),
          ));

  /// A file for a track, with the payload fingerprint that makes it findable
  /// on another machine.
  Future<int> file(
    int trackId, {
    required int folderId,
    String name = 'song.flac',
    String? quickKey = 'qk-1',
    int sizeBytes = 5000000,
    int? durationMs = 210000,
    String? relativePath,
  }) =>
      db.into(db.mediaFiles).insert(MediaFilesCompanion.insert(
            folderId: folderId,
            relativePath: relativePath ?? 'Artist/Album/$name',
            fileName: name,
            extension: 'flac',
            sizeBytes: sizeBytes,
            modifiedAt: DateTime.utc(2026),
            quickKey: Value(quickKey),
            durationMs: Value(durationMs),
            trackId: Value(trackId),
            status: const Value(FileStatus.present),
          ));

  Future<void> credit(
    int trackId,
    int artistId, {
    String? creditedAs,
    CreditRole role = CreditRole.mainArtist,
    DataSource source = DataSource.user,
  }) =>
      db.into(db.trackCredits).insert(TrackCreditsCompanion.insert(
            trackId: trackId,
            artistId: artistId,
            role: Value(role),
            creditedAs: Value(creditedAs),
            source: Value(source),
          ));

  Future<int> tag(String name, {int? categoryId}) =>
      db.into(db.tags).insert(TagsCompanion.insert(
            name: name,
            nameKey: name.toLowerCase(),
            categoryId: Value(categoryId),
          ));

  Future<void> tagTrack(int trackId, int tagId) =>
      db.into(db.trackTags).insert(
            TrackTagsCompanion.insert(trackId: trackId, tagId: tagId),
          );

  Future<TransferBundle> exported() =>
      LibraryExporter(db: db).buildBundle(origin: origin);

  group('exporting', () {
    test('carries the credits, with the spelling the release used', () async {
      // The reason the app exists: "Name1 x Name2" is two artists. That
      // split, and how each was spelled, is the most expensive thing to lose.
      final koiflower = await artist('Koiflower');
      final bangler = await artist('Bangler');
      final id = await track('Feel Right');
      await credit(id, koiflower, creditedAs: 'こいふらわー');
      await credit(id, bangler, role: CreditRole.featured);

      final bundle = await exported();
      final exportedTrack = bundle.tracks.single;

      expect(exportedTrack.credits, hasLength(2));
      final byArtist = {
        for (final c in exportedTrack.credits) c.artistId: c,
      };
      expect(byArtist[koiflower]!.creditedAs, 'こいふらわー');
      expect(byArtist[koiflower]!.role, 'mainArtist');
      expect(byArtist[bangler]!.role, 'featured');
    });

    test('carries a file fingerprint for every file of a track', () async {
      final folderId = await folder();
      final id = await track('Ghost');
      await file(id, folderId: folderId, name: 'ghost.flac', quickKey: 'qk-a');
      await file(id, folderId: folderId, name: 'ghost.mp3', quickKey: 'qk-b');

      final bundle = await exported();
      expect(
        bundle.tracks.single.files.map((f) => f.quickKey),
        ['qk-a', 'qk-b'],
      );
      expect(bundle.tracks.single.files.first.sizeBytes, 5000000);
    });

    test('relative paths are forward-slashed, whatever wrote them', () async {
      // The string is compared against a path built on the other machine,
      // which may not be Windows.
      final folderId = await folder();
      final id = await track('Ghost');
      await file(
        id,
        folderId: folderId,
        relativePath: r'Camellia\Album\01 Ghost.flac',
      );

      expect(
        (await exported()).tracks.single.files.single.relativePath,
        'Camellia/Album/01 Ghost.flac',
      );
    });

    test('carries ratings, favourites and counters', () async {
      await track('Loved', rating: 90, isFavorite: true, playCount: 12);

      final t = (await exported()).tracks.single;
      expect(t.rating, 90);
      expect(t.isFavorite, isTrue);
      expect(t.playCount, 12);
    });

    test('carries the never-split decision on an artist', () async {
      // A question the app asked and a person answered. Losing it means
      // being asked again on the other machine.
      await artist('AC/DC', neverSplit: true, isVerified: true);

      final a = (await exported()).artists.single;
      expect(a.neverSplit, isTrue);
      expect(a.isVerified, isTrue);
    });

    test('carries tags, their categories and what they are on', () async {
      // A fresh database already ships genre/language/mood categories, so
      // this adds one of its own -- and the seeded ones must travel too,
      // since an import has to recognise them rather than duplicate them.
      final categoryId = await db.into(db.tagCategories).insert(
            TagCategoriesCompanion.insert(name: 'Occasion', slug: 'occasion'),
          );
      final tagId = await tag('Hype', categoryId: categoryId);
      final trackId = await track('Ghost');
      await tagTrack(trackId, tagId);

      final bundle = await exported();
      expect(
        bundle.tagCategories.map((c) => c.slug),
        containsAll(<String>['genre', 'mood', 'occasion']),
      );
      expect(bundle.tags.single.name, 'Hype');
      expect(bundle.tags.single.categoryId, categoryId);
      expect(bundle.tracks.single.tagIds, [tagId]);
    });

    test('carries a smart playlist as its query, not its results', () async {
      // The query is portable by construction: it names artists and tags,
      // which exist on both machines, rather than row ids that do not.
      final id = await db.into(db.playlists).insert(PlaylistsCompanion.insert(
            name: 'Hardcore',
            nameKey: 'hardcore',
            kind: const Value(PlaylistKind.smart),
            query: const Value('tag=hardcore year:>=2015'),
          ));

      final playlist = (await exported()).playlists.single;
      expect(playlist.id, id);
      expect(playlist.kind, 'smart');
      expect(playlist.query, 'tag=hardcore year:>=2015');
    });

    test('carries a manual playlist as ordered references to its tracks',
        () async {
      final first = await track('First');
      final second = await track('Second');
      final playlistId = await db.into(db.playlists).insert(
            PlaylistsCompanion.insert(name: 'Mix', nameKey: 'mix'),
          );
      await db.into(db.playlistItems).insert(PlaylistItemsCompanion.insert(
            playlistId: playlistId,
            trackId: Value(second),
            position: 0,
          ));
      await db.into(db.playlistItems).insert(PlaylistItemsCompanion.insert(
            playlistId: playlistId,
            trackId: Value(first),
            position: 1,
          ));

      final items = (await exported()).playlists.single.items;
      expect(items.map((i) => i.trackId), [second, first]);
    });

    test('nested playlists keep their nesting', () async {
      final parent = await db.into(db.playlists).insert(
            PlaylistsCompanion.insert(name: 'Parent', nameKey: 'parent'),
          );
      final child = await db.into(db.playlists).insert(
            PlaylistsCompanion.insert(
              name: 'Child',
              nameKey: 'child',
              parentId: Value(parent),
            ),
          );

      final bundle = await exported();
      final childRow = bundle.playlists.firstWhere((p) => p.id == child);
      expect(childRow.parentId, parent);
    });

    test('an empty library exports an empty bundle rather than failing',
        () async {
      final bundle = await exported();
      expect(bundle.isEmpty, isTrue);
      expect(bundle.origin.machineName, 'Work PC');
    });
  });

  group('the bundle format', () {
    test('survives a round trip through JSON', () async {
      final artistId = await artist('Camellia', neverSplit: true);
      final albumId = await album('Album', year: 2021, artistId: artistId);
      final trackId = await track(
        'Ghost',
        albumId: albumId,
        rating: 80,
        isFavorite: true,
        trackNo: 3,
      );
      await credit(trackId, artistId, creditedAs: 'かめりあ');
      final folderId = await folder();
      await file(trackId, folderId: folderId);
      final tagId = await tag('Hardcore');
      await tagTrack(trackId, tagId);

      final before = await exported();
      final after = TransferBundle.decode(before.encode());

      expect(after.schema, transferSchemaVersion);
      expect(after.origin.machineId, 'machine-a');
      expect(after.artists.single.neverSplit, isTrue);
      expect(after.albums.single.releaseYear, 2021);
      expect(after.albums.single.albumArtistId, artistId);

      final t = after.tracks.single;
      expect(t.title, 'Ghost');
      expect(t.rating, 80);
      expect(t.isFavorite, isTrue);
      expect(t.trackNo, 3);
      expect(t.albumId, albumId);
      expect(t.credits.single.creditedAs, 'かめりあ');
      expect(t.files.single.quickKey, 'qk-1');
      expect(t.tagIds, [tagId]);
    });

    test('refuses a file that is not a bundle', () {
      expect(
        () => TransferBundle.decode('{"kind": "something-else"}'),
        throwsA(isA<TransferFormatException>()),
      );
      expect(
        () => TransferBundle.decode('not json at all'),
        throwsA(isA<TransferFormatException>()),
      );
    });

    test('refuses a bundle from a newer version, and says why', () {
      // Better than importing half of it and leaving the user to work out
      // which half.
      expect(
        () => TransferBundle.decode(
          '{"kind": "marmelade-library", "schema": 99}',
        ),
        throwsA(
          isA<TransferFormatException>().having(
            (e) => e.message,
            'message',
            contains('newer version'),
          ),
        ),
      );
    });

    test('an unknown field is ignored rather than fatal', () {
      // Forward compatibility within a schema version: a bundle written by a
      // build that knows one more field must still import.
      final bundle = TransferBundle.decode(
        '{"kind": "marmelade-library", "schema": 1, '
        '"exportedAt": "2026-09-03T00:00:00.000Z", '
        '"somethingNew": {"a": 1}, '
        '"tracks": [{"id": 1, "title": "Ghost", "nameKey": "ghost", '
        '"unknownField": true}]}',
      );
      expect(bundle.tracks.single.title, 'Ghost');
    });
  });
}
