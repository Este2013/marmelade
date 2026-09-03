import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/settings_repository.dart';
import 'package:marmelade/data/transfer/library_exporter.dart';
import 'package:marmelade/data/transfer/library_importer.dart';
import 'package:marmelade/data/transfer/library_sync.dart';
import 'package:marmelade/data/transfer/transfer_bundle.dart';
import 'package:marmelade/data/transfer/transfer_report.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'package:path/path.dart' as p;

/// Moving hand-entered data between two computers.
///
/// The scenario every test here is a variation of: the same music sits on two
/// machines, work was done on one of them, and none of it should have to be
/// done twice. What makes that hard is that *both* sides drift -- so most of
/// these care less about "did the field copy across" than about "did
/// importing quietly lose something that only existed here".
void main() {
  late _Machine work;
  late _Machine home;

  setUpAll(() {
    // Two libraries open at once is the entire subject of this file, and
    // they are separate in-memory databases rather than the same file, so
    // drift's race warning does not apply.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() async {
    work = await _Machine.open('Work PC');
    home = await _Machine.open('Home PC');
  });

  tearDown(() async {
    await work.db.close();
    await home.db.close();
  });

  group('exporting', () {
    test('carries the credits, with the spelling the release used', () async {
      // The reason the app exists: "Name1 x Name2" is two artists. That
      // split, and how each was spelled, is the most expensive thing to lose.
      final koiflower = await work.artist('Koiflower');
      final bangler = await work.artist('Bangler');
      final id = await work.track('Feel Right');
      await work.credit(id, koiflower, creditedAs: 'こいふらわー');
      await work.credit(id, bangler, role: CreditRole.featured);

      final exported = await work.export();
      final byArtist = {
        for (final c in exported.tracks.single.credits) c.artistId: c,
      };
      expect(byArtist[koiflower]!.creditedAs, 'こいふらわー');
      expect(byArtist[koiflower]!.role, 'mainArtist');
      expect(byArtist[bangler]!.role, 'featured');
    });

    test('carries a file fingerprint for every file of a track', () async {
      final id = await work.track('Ghost');
      await work.file(id, name: 'ghost.flac', quickKey: 'qk-a');
      await work.file(id, name: 'ghost.mp3', quickKey: 'qk-b');

      final files = (await work.export()).tracks.single.files;
      expect(files.map((f) => f.quickKey), ['qk-a', 'qk-b']);
      expect(files.first.sizeBytes, 5000000);
    });

    test('relative paths are forward-slashed, whatever wrote them', () async {
      // The string is compared against a path built on the other machine,
      // which may not be Windows.
      final id = await work.track('Ghost');
      await work.file(id, relativePath: r'Camellia\Album\01 Ghost.flac');

      expect(
        (await work.export()).tracks.single.files.single.relativePath,
        'Camellia/Album/01 Ghost.flac',
      );
    });

    test('carries ratings, favourites and counters', () async {
      await work.track('Loved', rating: 90, isFavorite: true, playCount: 12);

      final t = (await work.export()).tracks.single;
      expect(t.rating, 90);
      expect(t.isFavorite, isTrue);
      expect(t.playCount, 12);
    });

    test('carries the never-split decision on an artist', () async {
      // A question the app asked and a person answered. Losing it means
      // being asked again on the other machine.
      await work.artist('AC/DC', neverSplit: true, isVerified: true);

      final a = (await work.export()).artists.single;
      expect(a.neverSplit, isTrue);
      expect(a.isVerified, isTrue);
    });

    test('carries tags, their categories and what they are on', () async {
      // A fresh database already ships genre/language/mood categories, so
      // this adds one of its own -- and the seeded ones travel too, since an
      // import has to recognise them rather than duplicate them.
      final categoryId = await work.tagCategory('Occasion', 'occasion');
      final tagId = await work.tag('Hype', categoryId: categoryId);
      final trackId = await work.track('Ghost');
      await work.tagTrack(trackId, tagId);

      final bundle = await work.export();
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
      await work.playlist(
        'Hardcore',
        kind: PlaylistKind.smart,
        query: 'tag=hardcore year:>=2015',
      );

      final playlist = (await work.export()).playlists.single;
      expect(playlist.kind, 'smart');
      expect(playlist.query, 'tag=hardcore year:>=2015');
    });

    test('an empty library exports an empty bundle rather than failing',
        () async {
      final bundle = await work.export();
      expect(bundle.isEmpty, isTrue);
      expect(bundle.origin.machineName, 'Work PC');
    });
  });

  group('the bundle format', () {
    test('survives a round trip through JSON', () async {
      final artistId = await work.artist('Camellia', neverSplit: true);
      final albumId = await work.album('Album', year: 2021, artistId: artistId);
      final trackId = await work.track(
        'Ghost',
        albumId: albumId,
        rating: 80,
        isFavorite: true,
        trackNo: 3,
      );
      await work.credit(trackId, artistId, creditedAs: 'かめりあ');
      await work.file(trackId);
      await work.tagTrack(trackId, await work.tag('Hardcore'));

      final after = TransferBundle.decode((await work.export()).encode());

      expect(after.schema, transferSchemaVersion);
      expect(after.artists.single.neverSplit, isTrue);
      expect(after.albums.single.releaseYear, 2021);
      expect(after.albums.single.albumArtistId, artistId);

      final t = after.tracks.single;
      expect(t.rating, 80);
      expect(t.isFavorite, isTrue);
      expect(t.trackNo, 3);
      expect(t.credits.single.creditedAs, 'かめりあ');
      expect(t.files.single.quickKey, 'qk-1');
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
        () => TransferBundle.decode('{"kind": "marmelade-library", "schema": 99}'),
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
      // Forward compatibility inside a schema version: a bundle written by a
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

  group('importing onto the same music', () {
    /// The setup the whole feature exists for: both machines hold the same
    /// file, and only one of them has had the work done on it.
    Future<int> sameTrackOnBoth({String quickKey = 'qk-1'}) async {
      final homeTrack = await home.track('Feel Right');
      await home.file(homeTrack, quickKey: quickKey);
      final workTrack = await work.track('Feel Right');
      await work.file(workTrack, quickKey: quickKey);
      return workTrack;
    }

    test('a split credit arrives with its spelling', () async {
      final workTrack = await sameTrackOnBoth();
      final koiflower = await work.artist('Koiflower');
      final bangler = await work.artist('Bangler');
      await work.credit(workTrack, koiflower, creditedAs: 'こいふらわー');
      await work.credit(workTrack, bangler, role: CreditRole.featured);

      final report = await home.importFrom(work);

      expect(report.tracksMatched, 1);
      expect(report.missingTracks, isEmpty);
      expect(
        await home.creditsOf('Feel Right'),
        {
          'Koiflower|mainArtist|こいふらわー',
          'Bangler|featured|',
        },
      );
    });

    test('tags, ratings and favourites arrive', () async {
      final workTrack = await sameTrackOnBoth();
      await work.rate(workTrack, 90, favorite: true);
      await work.tagTrack(workTrack, await work.tag('Hardcore'));

      await home.importFrom(work);

      final row = await home.trackRow('Feel Right');
      expect(row.readNullable<int>('rating'), 90);
      expect(row.read<int>('is_favorite'), 1);
      expect(await home.tagsOf('Feel Right'), {'Hardcore'});
    });

    test('a tag only this machine has is left alone', () async {
      // The property that makes this a merge and not a restore: a bundle
      // cannot tell "deleted over there" from "added here since the export",
      // so it never removes anything.
      final workTrack = await sameTrackOnBoth();
      await work.tagTrack(workTrack, await work.tag('Hardcore'));

      final homeTrack = await home.trackIdOf('Feel Right');
      await home.tagTrack(homeTrack, await home.tag('Mine'));

      await home.importFrom(work);

      expect(await home.tagsOf('Feel Right'), {'Mine', 'Hardcore'});
    });

    test('an empty rating is filled, a different one is kept and counted',
        () async {
      final workTrack = await sameTrackOnBoth();
      await work.rate(workTrack, 90);

      final homeTrack = await home.trackIdOf('Feel Right');
      await home.rate(homeTrack, 40);

      final report = await home.importFrom(work);

      expect(
        (await home.trackRow('Feel Right')).readNullable<int>('rating'),
        40,
        reason: 'this machine had a rating already, so it wins by default',
      );
      expect(report.conflictsKept, greaterThan(0));
    });

    test('prefer-theirs takes the incoming rating instead', () async {
      final workTrack = await sameTrackOnBoth();
      await work.rate(workTrack, 90);
      final homeTrack = await home.trackIdOf('Feel Right');
      await home.rate(homeTrack, 40);

      await home.importFrom(
        work,
        options: const TransferImportOptions(
          conflicts: TransferConflictPolicy.preferTheirs,
        ),
      );

      expect(
        (await home.trackRow('Feel Right')).readNullable<int>('rating'),
        90,
      );
    });

    test('a favourite here is not un-favourited by a bundle that lacks it',
        () async {
      // `false` is what a row looks like when nobody was ever asked, so it
      // must not overwrite a yes.
      final workTrack = await sameTrackOnBoth();
      await work.rate(workTrack, null, favorite: false);
      final homeTrack = await home.trackIdOf('Feel Right');
      await home.rate(homeTrack, null, favorite: true);

      await home.importFrom(work);

      expect((await home.trackRow('Feel Right')).read<int>('is_favorite'), 1);
    });

    test('play counts take the larger side rather than adding up', () async {
      // Adding would double-count every play from before the two libraries
      // diverged.
      final workTrack = await sameTrackOnBoth();
      await work.setPlayCount(workTrack, 30);
      final homeTrack = await home.trackIdOf('Feel Right');
      await home.setPlayCount(homeTrack, 12);

      await home.importFrom(work);
      expect((await home.trackRow('Feel Right')).read<int>('play_count'), 30);

      // And the other way round: a bigger local count is not reduced.
      await home.setPlayCount(homeTrack, 99);
      await home.importFrom(work);
      expect((await home.trackRow('Feel Right')).read<int>('play_count'), 99);
    });

    test('importing the same bundle twice changes nothing the second time',
        () async {
      // The property that makes it safe to press the button again, and the
      // one a sync folder depends on completely.
      final workTrack = await sameTrackOnBoth();
      final artistId = await work.artist('Camellia', neverSplit: true);
      await work.credit(workTrack, artistId, creditedAs: 'かめりあ');
      await work.rate(workTrack, 90, favorite: true);
      await work.tagTrack(workTrack, await work.tag('Hardcore'));
      await work.playlist('Mix', tracks: [workTrack]);

      final bundle = await work.export();
      final first = await home.import(bundle);
      expect(first.changeCount, greaterThan(0));

      final second = await home.import(bundle);
      expect(second.changedNothing, isTrue, reason: second.summarize());
      expect(second.summarize(), contains('already up to date'));
    });

    test('a renamed or moved file still matches on its fingerprint', () async {
      // The quick key covers the audio payload, so moving a file, renaming it
      // or retagging it does not change what it is.
      final homeTrack = await home.track('Feel Right');
      await home.file(
        homeTrack,
        quickKey: 'qk-same',
        name: 'renamed here.flac',
        relativePath: 'Somewhere/Else/renamed here.flac',
      );
      final workTrack = await work.track('Feel Right');
      await work.file(
        workTrack,
        quickKey: 'qk-same',
        name: '01 Feel Right.flac',
        relativePath: 'Camellia/Album/01 Feel Right.flac',
      );
      await work.rate(workTrack, 70);

      final report = await home.importFrom(work);

      expect(report.tracksMatched, 1);
      expect(
        (await home.trackRow('Feel Right')).readNullable<int>('rating'),
        70,
      );
    });

    test('a retagged file still matches, though its size changed', () async {
      // Editing tags rewrites the tag block, so the file grows or shrinks
      // while the audio is untouched. The quick key covers the payload only
      // -- and already folds the payload's length in -- so the same key with
      // a different file size means "same song, different tags", which is
      // exactly when ratings and playlists must still find their track.
      final homeTrack = await home.track('Feel Right');
      await home.file(homeTrack, quickKey: 'qk-x', sizeBytes: 5001000, name: 'a.flac');
      final workTrack = await work.track('Feel Right');
      await work.file(workTrack, quickKey: 'qk-x', sizeBytes: 5002400, name: 'b.flac');
      await work.rate(workTrack, 70);

      final report = await home.importFrom(work);

      expect(report.tracksMatched, 1);
      expect(
        (await home.trackRow('Feel Right')).readNullable<int>('rating'),
        70,
      );
    });

    test('a different encode matches only when asked to match by tags',
        () async {
      // No shared fingerprint: a re-download, or a FLAC here and an MP3
      // there. Off by default, because a title and album are a guess.
      final albumHome = await home.album('Album');
      final homeTrack = await home.track('Feel Right', albumId: albumHome, trackNo: 1);
      await home.file(homeTrack, quickKey: 'qk-home', name: 'home.mp3');

      final albumWork = await work.album('Album');
      final workTrack = await work.track('Feel Right', albumId: albumWork, trackNo: 1);
      await work.file(workTrack, quickKey: 'qk-work', name: 'work.flac');
      await work.rate(workTrack, 60);

      final strict = await home.importFrom(work);
      expect(strict.tracksMatched, 0);
      expect(strict.missingTracks, hasLength(1));
      expect(
        (await home.trackRow('Feel Right')).readNullable<int>('rating'),
        isNull,
      );

      final loose = await home.importFrom(
        work,
        options: const TransferImportOptions(
          matching: TransferMatchMode.alsoByTags,
        ),
      );
      expect(loose.tracksMatched, 1);
      expect(
        (await home.trackRow('Feel Right')).readNullable<int>('rating'),
        60,
      );
    });

    test('a track this machine does not have is reported, not invented',
        () async {
      // A track row with no file behind it would show up in every list and
      // play nothing. The fix is to copy the audio across, which is what the
      // report says.
      final workTrack = await work.track('Brand New Song');
      await work.file(workTrack, quickKey: 'qk-new');
      final artistId = await work.artist('Camellia');
      await work.credit(workTrack, artistId);

      final report = await home.importFrom(work);

      expect(report.tracksMatched, 0);
      expect(report.missingTracks, hasLength(1));
      expect(report.missingTracks.single.title, 'Brand New Song');
      expect(report.missingTracks.single.artist, 'Camellia');
      expect(await home.trackCount(), 0);
      expect(report.summarize(), contains('not on this computer yet'));
    });

    test('the credited-as spelling fills into a credit that lacks it',
        () async {
      // The local scan found the artist but not how this release spelled the
      // name; the bundle knows both.
      final workTrack = await sameTrackOnBoth();
      final workArtist = await work.artist('Camellia');
      await work.credit(workTrack, workArtist, creditedAs: 'かめりあ');

      final homeTrack = await home.trackIdOf('Feel Right');
      final homeArtist = await home.artist('Camellia');
      await home.credit(homeTrack, homeArtist, source: DataSource.fileMetadata);

      await home.importFrom(work);

      expect(
        await home.creditsOf('Feel Right'),
        {'Camellia|mainArtist|かめりあ'},
      );
    });
  });

  group('importing artists, albums and tags', () {
    test('an artist that is new here is created with its decisions', () async {
      await work.artist('AC/DC', neverSplit: true, isVerified: true);

      final report = await home.importFrom(work);

      final artist = await home.artistRow('AC/DC');
      expect(artist, isNotNull);
      expect(artist!.read<int>('never_split'), 1);
      expect(artist.read<int>('is_verified'), 1);
      expect(report.artistsCreated, 1);
    });

    test('a never-split decision from either machine is kept', () async {
      await work.artist('AC/DC', neverSplit: true);
      await home.artist('AC/DC');

      await home.importFrom(work);

      expect((await home.artistRow('AC/DC'))!.read<int>('never_split'), 1);
      expect(await home.artistCount('AC/DC'), 1, reason: 'not duplicated');
    });

    test('two artists sharing a name are not guessed between', () async {
      // Exactly the case disambiguation exists for. Attaching one machine's
      // credits to the wrong person would be worse than creating a row.
      await home.artist('Wave', disambiguation: 'the producer');
      await home.artist('Wave', disambiguation: 'the band');
      await work.artist('Wave');

      await home.importFrom(work);

      expect(await home.artistCount('Wave'), 3);
    });

    test('a seeded tag category is matched by slug, not duplicated', () async {
      final tagId = await work.tag('Hype', categoryId: await work.categoryOf('mood'));
      final trackId = await work.track('Ghost');
      await work.file(trackId, quickKey: 'qk-1');
      await work.tagTrack(trackId, tagId);

      final homeTrack = await home.track('Ghost');
      await home.file(homeTrack, quickKey: 'qk-1');

      await home.importFrom(work);

      expect(await home.categoryCount('mood'), 1);
      expect(await home.tagsOf('Ghost'), {'Hype'});
      expect(
        await home.categoryNameOfTag('Hype'),
        'Mood',
        reason: 'the tag lands under the same category it had',
      );
    });

    test('an album is matched on name, artist and year rather than duplicated',
        () async {
      final workArtist = await work.artist('Camellia');
      final workAlbum = await work.album('Album', year: 2021, artistId: workArtist);
      await work.setAlbumFavourite(workAlbum);

      final homeArtist = await home.artist('Camellia');
      await home.album('Album', year: 2021, artistId: homeArtist);

      final report = await home.importFrom(work);

      expect(report.albumsCreated, 0);
      expect(await home.albumCount('Album'), 1);
      expect((await home.albumRow('Album'))!.read<int>('is_favorite'), 1);
    });
  });

  group('importing playlists', () {
    test('a playlist arrives with its tracks in order', () async {
      final first = await work.track('First');
      await work.file(first, quickKey: 'qk-1');
      final second = await work.track('Second');
      await work.file(second, quickKey: 'qk-2');
      await work.playlist('Mix', tracks: [second, first]);

      final homeFirst = await home.track('First');
      await home.file(homeFirst, quickKey: 'qk-1');
      final homeSecond = await home.track('Second');
      await home.file(homeSecond, quickKey: 'qk-2');

      final report = await home.importFrom(work);

      expect(report.playlistsCreated, 1);
      expect(await home.playlistTitles('Mix'), ['Second', 'First']);
    });

    test('entries this machine already has are not added twice', () async {
      final workTrack = await work.track('Ghost');
      await work.file(workTrack, quickKey: 'qk-1');
      await work.playlist('Mix', tracks: [workTrack]);

      final homeTrack = await home.track('Ghost');
      await home.file(homeTrack, quickKey: 'qk-1');
      await home.playlist('Mix', tracks: [homeTrack]);

      final report = await home.importFrom(work);

      expect(report.playlistItemsAdded, 0);
      expect(await home.playlistTitles('Mix'), ['Ghost']);
    });

    test('a playlist keeps entries the bundle does not know about', () async {
      final workTrack = await work.track('Theirs');
      await work.file(workTrack, quickKey: 'qk-t');
      await work.playlist('Mix', tracks: [workTrack]);

      final mine = await home.track('Mine');
      await home.file(mine, quickKey: 'qk-m');
      final theirs = await home.track('Theirs');
      await home.file(theirs, quickKey: 'qk-t');
      await home.playlist('Mix', tracks: [mine]);

      await home.importFrom(work);

      expect(await home.playlistTitles('Mix'), ['Mine', 'Theirs']);
    });

    test('a smart playlist arrives as its query', () async {
      await work.playlist(
        'Hardcore',
        kind: PlaylistKind.smart,
        query: 'tag=hardcore',
      );

      await home.importFrom(work);

      expect(await home.playlistQuery('Hardcore'), 'tag=hardcore');
    });

    test('a query this machine already has is not overwritten', () async {
      // A playlist is something a person built; changing what it means
      // without being asked is worse than not syncing it.
      await work.playlist('Hardcore', kind: PlaylistKind.smart, query: 'tag=hardcore');
      await home.playlist('Hardcore', kind: PlaylistKind.smart, query: 'is:Favourite');

      final report = await home.importFrom(work);

      expect(await home.playlistQuery('Hardcore'), 'is:Favourite');
      expect(report.conflictsKept, greaterThan(0));
    });

    test('nesting is rebuilt on the other side', () async {
      final parent = await work.playlist('Parent');
      await work.playlist('Child', parentId: parent);

      await home.importFrom(work);

      expect(await home.playlistParentName('Child'), 'Parent');
    });

    test('playlists can be left out of an import', () async {
      await work.playlist('Mix', kind: PlaylistKind.smart, query: 'tag=x');

      final report = await home.importFrom(
        work,
        options: const TransferImportOptions(importPlaylists: false),
      );

      expect(report.playlistsCreated, 0);
      expect(await home.playlistQuery('Mix'), isNull);
    });
  });

  group('importing learned rules', () {
    test('a split rule arrives with its artists remapped', () async {
      // The highest-value thing in a bundle: a question the app asked and a
      // person answered. Its stored form holds local row ids, so it only
      // survives the trip if those are translated.
      final koiflower = await work.artist('Koiflower');
      final bangler = await work.artist('Bangler');
      await work.splitRule('Koiflower x Bangler', [koiflower, bangler]);

      // Home already knows one of the two, with a different row id.
      await home.artist('Filler');
      await home.artist('Bangler');

      final report = await home.importFrom(work);

      expect(report.splitRulesAdded, 1);
      final resolved = await home.splitRuleArtists('Koiflower x Bangler');
      expect(resolved, ['Koiflower', 'Bangler']);
    });

    test('a rule whose artists cannot be resolved is skipped, not half-applied',
        () async {
      final koiflower = await work.artist('Koiflower');
      await work.splitRule('Broken', [koiflower]);

      // Strip the artist out of the bundle, leaving the rule dangling.
      final bundle = await work.export();
      final crippled = TransferBundle(
        origin: bundle.origin,
        exportedAt: bundle.exportedAt,
        splitRules: bundle.splitRules,
      );

      final report = await home.import(crippled);
      expect(report.splitRulesAdded, 0);
    });

    test('a user-added separator token travels', () async {
      await work.separator(' vs ');

      final report = await home.importFrom(work);

      expect(report.separatorsAdded, greaterThan(0));
      expect(await home.hasSeparator(' vs '), isTrue);
    });
  });

  group('sharing through a folder', () {
    late Directory shared;

    setUp(() async {
      shared = await Directory.systemTemp.createTemp('marmelade-sync');
    });

    tearDown(() async {
      if (await shared.exists()) await shared.delete(recursive: true);
    });

    test('each machine writes only its own subfolder', () async {
      // The property the whole design rests on: two computers never write
      // the same file, so a cloud client syncing whenever it likes cannot
      // produce a conflict.
      await work.track('Ghost').then(work.file);
      await work.sync(shared);
      await home.sync(shared);

      final machines = Directory(p.join(shared.path, 'machines'));
      final folders = await machines
          .list()
          .where((e) => e is Directory)
          .map((e) => p.basename(e.path))
          .toList();

      expect(folders, hasLength(2));
      expect(
        await File(p.join(machines.path, folders.first, 'library.json'))
            .exists(),
        isTrue,
      );
    });

    test('work done on one machine reaches the other', () async {
      final workTrack = await work.track('Feel Right');
      await work.file(workTrack, quickKey: 'qk-1');
      final camellia = await work.artist('Camellia');
      await work.credit(workTrack, camellia, creditedAs: 'かめりあ');
      await work.rate(workTrack, 95, favorite: true);
      await work.tagTrack(workTrack, await work.tag('Hardcore'));

      final homeTrack = await home.track('Feel Right');
      await home.file(homeTrack, quickKey: 'qk-1');

      await work.sync(shared);
      final outcome = await home.sync(shared);

      expect(outcome.imported, hasLength(1));
      expect(outcome.imported.single.origin, 'Work PC');
      expect(await home.tagsOf('Feel Right'), {'Hardcore'});
      expect(await home.creditsOf('Feel Right'), {'Camellia|mainArtist|かめりあ'});
      expect(
        (await home.trackRow('Feel Right')).readNullable<int>('rating'),
        95,
      );
    });

    test('a second sync skips a machine that has not changed', () async {
      await work.track('Ghost').then(work.file);
      await work.sync(shared);

      final first = await home.sync(shared);
      expect(first.imported, hasLength(1));

      final second = await home.sync(shared);
      expect(second.imported, isEmpty);
      expect(second.upToDate.map((p) => p.origin.machineName), ['Work PC']);
      expect(second.summarize(), contains('already up to date'));
    });

    test('and picks it up again once that machine re-exports', () async {
      final workTrack = await work.track('Ghost');
      await work.file(workTrack, quickKey: 'qk-1');
      await work.sync(shared);

      final homeTrack = await home.track('Ghost');
      await home.file(homeTrack, quickKey: 'qk-1');
      await home.sync(shared);

      // Something happens at work, and it publishes again.
      await work.rate(workTrack, 70);
      await work.sync(shared);

      final outcome = await home.sync(shared);
      expect(outcome.imported, hasLength(1));
      expect(
        (await home.trackRow('Ghost')).readNullable<int>('rating'),
        70,
      );
    });

    test('both machines converge, whoever syncs first', () async {
      // Divergence on both sides at once, which is the normal state after a
      // week of using two computers.
      final workTrack = await work.track('Shared');
      await work.file(workTrack, quickKey: 'qk-1');
      await work.tagTrack(workTrack, await work.tag('FromWork'));

      final homeTrack = await home.track('Shared');
      await home.file(homeTrack, quickKey: 'qk-1');
      await home.tagTrack(homeTrack, await home.tag('FromHome'));

      await work.sync(shared);
      await home.sync(shared);
      // Work reads what home published, and home reads work's second write.
      await work.sync(shared);
      await home.sync(shared);

      expect(await work.tagsOf('Shared'), {'FromWork', 'FromHome'});
      expect(await home.tagsOf('Shared'), {'FromWork', 'FromHome'});
    });

    test('a machine lists its peers without importing them', () async {
      await work.track('Ghost').then(work.file);
      await work.sync(shared);

      final peers = await home.peers(shared);
      expect(peers.map((p) => p.origin.machineName), ['Work PC']);
      expect(peers.single.isSelf, isFalse);
      expect(peers.single.counts['tracks'], 1);
      expect(await home.trackCount(), 0, reason: 'listing imports nothing');
    });

    test('rubbish in the shared folder is skipped, not fatal', () async {
      // A half-synced file, or a folder someone dropped something else into.
      final rogue = Directory(p.join(shared.path, 'machines', 'nonsense'));
      await rogue.create(recursive: true);
      await File(p.join(rogue.path, 'library.json')).writeAsString('{oops');

      await work.track('Ghost').then(work.file);
      await work.sync(shared);

      final outcome = await home.sync(shared);
      expect(outcome.imported, hasLength(1));
      expect(outcome.imported.single.origin, 'Work PC');
    });

    test('this computer keeps its identity across syncs', () async {
      final first = await work.identity();
      final second = await work.identity();
      expect(second.machineId, first.machineId);
      expect(second.machineId, isNotEmpty);
      expect(second.machineName, 'Work PC');
    });

    test('audio only travels when it is asked for', () async {
      // The user's own caution: a bundle often goes somewhere metered, so
      // the audio is opt-in and the metadata is not.
      final trackId = await work.track('Ghost');
      await work.file(trackId, quickKey: 'qk-1');

      await work.sync(shared);
      final own = Directory(p.join(
        shared.path,
        'machines',
        (await work.identity()).machineId,
      ));
      expect(
        await Directory(p.join(own.path, 'audio')).exists(),
        isFalse,
        reason: 'audio is off by default',
      );
      expect(await File(p.join(own.path, 'library.json')).exists(), isTrue);

      await work.sync(
        shared,
        export: const TransferExportOptions(includeAudio: true),
      );
      expect(await Directory(p.join(own.path, 'audio')).exists(), isTrue);
    });
  });

  group('artwork', () {
    late Directory scratch;

    /// A one-pixel PNG, so `ImageProbe` recognises real bytes rather than
    /// this having to fake the store.
    final onePixelPng = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAF'
      'AAH/q842iQAAAABJRU5ErkJggg==',
    );

    setUp(() async {
      scratch = await Directory.systemTemp.createTemp('marmelade-art');
    });

    tearDown(() async {
      if (await scratch.exists()) await scratch.delete(recursive: true);
    });

    test('a picture chosen by hand travels with the bundle', () async {
      // Artwork is the one thing that cannot be carried as a reference: the
      // store is content-addressed, so the digest is the identity and the
      // bytes have to arrive for the row to mean anything.
      final workStore =
          await ArtStore.open(Directory(p.join(scratch.path, 'work-art')));
      final homeStore =
          await ArtStore.open(Directory(p.join(scratch.path, 'home-art')));
      final bundleDir = Directory(p.join(scratch.path, 'bundle'));

      final stored = await workStore.putBytes(onePixelPng);
      final imageId = await work.image(stored!);
      final albumId = await work.album('Album');
      await work.setAlbumImage(albumId, imageId);
      await home.album('Album');

      await LibraryExporter(db: work.db, artStore: workStore).exportTo(
        bundleDir,
        origin: work.origin,
      );

      // The bytes are in the bundle, named by their digest.
      final copied = Directory(p.join(bundleDir.path, 'artwork'));
      expect(await copied.exists(), isTrue);
      expect(await copied.list().length, 1);

      final bundle = TransferBundle.decode(
        await File(p.join(bundleDir.path, 'library.json')).readAsString(),
      );
      final report = await LibraryImporter(db: home.db, artStore: homeStore)
          .import(bundle, bundleDirectory: bundleDir);

      expect(report.imagesAdded, 1);
      final homeImage = await home.albumImageDigest('Album');
      expect(homeImage, stored.sha256);
      // And the file is really in this machine's store, not just referenced.
      expect(await homeStore.exists(stored.storedPath), isTrue);
    });

    test('an image already here is recognised rather than stored twice',
        () async {
      final workStore =
          await ArtStore.open(Directory(p.join(scratch.path, 'work-art')));
      final homeStore =
          await ArtStore.open(Directory(p.join(scratch.path, 'home-art')));
      final bundleDir = Directory(p.join(scratch.path, 'bundle'));

      final stored = await workStore.putBytes(onePixelPng);
      final imageId = await work.image(stored!);
      final albumId = await work.album('Album');
      await work.setAlbumImage(albumId, imageId);

      // Home has the same picture already -- the digest is the same, because
      // the digest is the bytes.
      final hereToo = await homeStore.putBytes(onePixelPng);
      await home.image(hereToo!);
      await home.album('Album');

      await LibraryExporter(db: work.db, artStore: workStore)
          .exportTo(bundleDir, origin: work.origin);
      final report = await LibraryImporter(db: home.db, artStore: homeStore)
          .import(
        TransferBundle.decode(
          await File(p.join(bundleDir.path, 'library.json')).readAsString(),
        ),
        bundleDirectory: bundleDir,
      );

      expect(report.imagesAdded, 0, reason: 'the row was already here');
      expect(await home.imageCount(), 1);
      expect(await home.albumImageDigest('Album'), stored.sha256);
    });

    test('a bundle with no artwork folder still imports its metadata',
        () async {
      // Metadata-only is the common case: it is what a sync folder on a
      // metered connection should carry.
      final workStore =
          await ArtStore.open(Directory(p.join(scratch.path, 'work-art')));
      final bundleDir = Directory(p.join(scratch.path, 'bundle'));

      final stored = await workStore.putBytes(onePixelPng);
      final imageId = await work.image(stored!);
      final albumId = await work.album('Album', year: 2021);
      await work.setAlbumImage(albumId, imageId);
      await work.setAlbumFavourite(albumId);

      await LibraryExporter(db: work.db, artStore: workStore).exportTo(
        bundleDir,
        origin: work.origin,
        options: const TransferExportOptions(includeArtwork: false),
      );
      expect(
        await Directory(p.join(bundleDir.path, 'artwork')).exists(),
        isFalse,
      );

      await home.album('Album', year: 2021);
      final report = await LibraryImporter(db: home.db).import(
        TransferBundle.decode(
          await File(p.join(bundleDir.path, 'library.json')).readAsString(),
        ),
        bundleDirectory: bundleDir,
      );

      // The album's own data arrived; the picture did not, and nothing
      // points at a file this machine does not have.
      expect((await home.albumRow('Album'))!.read<int>('is_favorite'), 1);
      expect(report.imagesAdded, 0);
      expect(await home.albumImageDigest('Album'), isNull);
    });
  });

  group('previewing', () {
    test('reports what would change without writing anything', () async {
      // The same code path as a real import, rolled back -- so the preview
      // cannot drift away from what pressing the button does.
      final workTrack = await work.track('Feel Right');
      await work.file(workTrack, quickKey: 'qk-1');
      await work.rate(workTrack, 90, favorite: true);
      await work.tagTrack(workTrack, await work.tag('Hardcore'));
      await work.artist('AC/DC', neverSplit: true);

      final homeTrack = await home.track('Feel Right');
      await home.file(homeTrack, quickKey: 'qk-1');

      final preview = await home.import(await work.export(), preview: true);

      expect(preview.preview, isTrue);
      expect(preview.tracksMatched, 1);
      expect(preview.tracksUpdated, 1);
      expect(preview.artistsCreated, 1);
      expect(preview.tagLinksAdded, 1);

      // Nothing landed.
      expect(
        (await home.trackRow('Feel Right')).readNullable<int>('rating'),
        isNull,
      );
      expect(await home.tagsOf('Feel Right'), isEmpty);
      expect(await home.artistRow('AC/DC'), isNull);
    });

    test('a preview followed by the real import lands the same changes',
        () async {
      final workTrack = await work.track('Feel Right');
      await work.file(workTrack, quickKey: 'qk-1');
      await work.rate(workTrack, 90);
      final homeTrack = await home.track('Feel Right');
      await home.file(homeTrack, quickKey: 'qk-1');

      final bundle = await work.export();
      final preview = await home.import(bundle, preview: true);
      final applied = await home.import(bundle);

      expect(applied.changeCount, preview.changeCount);
      expect(
        (await home.trackRow('Feel Right')).readNullable<int>('rating'),
        90,
      );
    });
  });
}

/// One computer's library, with the fixtures and read-backs a transfer test
/// needs. Two of these is the whole point.
class _Machine {
  _Machine(this.db, this.name);

  final MarmeladeDatabase db;
  final String name;
  int? _folderId;
  var _fileCounter = 0;

  static Future<_Machine> open(String name) async {
    final db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    return _Machine(db, name);
  }

  TransferOrigin get origin => TransferOrigin(
        machineId: name.toLowerCase().replaceAll(' ', '-'),
        machineName: name,
      );

  Future<TransferBundle> export() =>
      LibraryExporter(db: db).buildBundle(origin: origin);

  Future<TransferReport> import(
    TransferBundle bundle, {
    TransferImportOptions options = const TransferImportOptions(),
    bool preview = false,
  }) =>
      LibraryImporter(db: db).import(bundle, options: options, preview: preview);

  Future<TransferReport> importFrom(
    _Machine other, {
    TransferImportOptions options = const TransferImportOptions(),
  }) async =>
      import(await other.export(), options: options);

  // ------------------------------------------------------ the shared folder

  LibrarySync get _sync => LibrarySync(
        exporter: LibraryExporter(db: db),
        importer: LibraryImporter(db: db),
        settings: SettingsRepository(db),
      );

  /// Resolves this machine's identity, forcing the name so a test can read
  /// it back rather than depending on the hostname of whatever runs it.
  Future<TransferOrigin> identity() async {
    final settings = SettingsRepository(db);
    if ((await settings.get(SettingKeys.machineName, '')).isEmpty) {
      await settings.set(SettingKeys.machineName, name);
    }
    return _sync.identity();
  }

  Future<SyncOutcome> sync(
    Directory folder, {
    TransferExportOptions export = const TransferExportOptions(),
  }) async =>
      _sync.syncNow(
        folder: folder,
        origin: await identity(),
        export: export,
      );

  Future<List<SyncPeer>> peers(Directory folder) async =>
      _sync.peers(folder, origin: await identity());

  // ----------------------------------------------------------------- writing

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
    String? name,
    String? quickKey = 'qk-1',
    int sizeBytes = 5000000,
    int? durationMs = 210000,
    String? relativePath,
  }) async {
    final folderId = _folderId ??= await db.into(db.libraryFolders).insert(
          LibraryFoldersCompanion.insert(path: r'C:\Music'),
        );
    final fileName = name ?? 'song${_fileCounter++}.flac';
    return db.into(db.mediaFiles).insert(MediaFilesCompanion.insert(
          folderId: folderId,
          relativePath: relativePath ?? 'Artist/Album/$fileName',
          fileName: fileName,
          extension: 'flac',
          sizeBytes: sizeBytes,
          modifiedAt: DateTime.utc(2026),
          quickKey: Value(quickKey),
          durationMs: Value(durationMs),
          trackId: Value(trackId),
          status: const Value(FileStatus.present),
        ));
  }

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

  Future<int> tagCategory(String name, String slug) =>
      db.into(db.tagCategories).insert(
            TagCategoriesCompanion.insert(name: name, slug: slug),
          );

  Future<int?> categoryOf(String slug) async {
    final row = await db
        .customSelect(
          'SELECT id FROM tag_categories WHERE slug = ?1',
          variables: [Variable(slug)],
        )
        .getSingleOrNull();
    return row?.read<int>('id');
  }

  Future<int> tag(String name, {int? categoryId}) =>
      db.into(db.tags).insert(TagsCompanion.insert(
            name: name,
            nameKey: name.toLowerCase(),
            categoryId: Value(categoryId),
          ));

  Future<void> tagTrack(int trackId, int tagId) => db.into(db.trackTags).insert(
        TrackTagsCompanion.insert(trackId: trackId, tagId: tagId),
      );

  Future<void> rate(int trackId, int? rating, {bool favorite = false}) =>
      (db.update(db.tracks)..where((t) => t.id.equals(trackId))).write(
        TracksCompanion(rating: Value(rating), isFavorite: Value(favorite)),
      );

  Future<void> setPlayCount(int trackId, int count) =>
      (db.update(db.tracks)..where((t) => t.id.equals(trackId)))
          .write(TracksCompanion(playCount: Value(count)));

  Future<void> setAlbumFavourite(int albumId) =>
      (db.update(db.albums)..where((t) => t.id.equals(albumId)))
          .write(const AlbumsCompanion(isFavorite: Value(true)));

  Future<int> playlist(
    String name, {
    PlaylistKind kind = PlaylistKind.manual,
    String? query,
    int? parentId,
    List<int> tracks = const [],
  }) async {
    final id = await db.into(db.playlists).insert(PlaylistsCompanion.insert(
          name: name,
          nameKey: name.toLowerCase(),
          kind: Value(kind),
          query: Value(query),
          parentId: Value(parentId),
        ));
    for (final (index, trackId) in tracks.indexed) {
      await db.into(db.playlistItems).insert(PlaylistItemsCompanion.insert(
            playlistId: id,
            trackId: Value(trackId),
            position: index,
          ));
    }
    return id;
  }

  Future<void> splitRule(String raw, List<int> artistIds) =>
      db.into(db.creditSplitRules).insert(CreditSplitRulesCompanion.insert(
            rawCredit: raw,
            rawCreditKey: raw.toLowerCase(),
            resolution: '['
                '${artistIds.map((id) => '{"artistId": $id, "role": "mainArtist"}').join(',')}'
                ']',
            isUserConfirmed: const Value(true),
          ));

  Future<void> separator(String token) =>
      db.into(db.separatorTokens).insert(SeparatorTokensCompanion.insert(
            token: token,
            requiresSpaces: const Value(true),
          ));

  Future<int> image(StoredImage stored) =>
      db.into(db.images).insert(ImagesCompanion.insert(
            sha256: stored.sha256,
            kind: ImageKind.userProvided,
            mimeType: stored.mimeType,
            byteSize: stored.byteSize,
            storedPath: stored.storedPath,
            width: Value(stored.width),
            height: Value(stored.height),
          ));

  Future<void> setAlbumImage(int albumId, int imageId) =>
      (db.update(db.albums)..where((t) => t.id.equals(albumId)))
          .write(AlbumsCompanion(imageId: Value(imageId)));

  // ----------------------------------------------------------------- reading

  Future<QueryRow> trackRow(String title) => db
      .customSelect(
        'SELECT * FROM tracks WHERE title = ?1',
        variables: [Variable(title)],
      )
      .getSingle();

  Future<int> trackIdOf(String title) async =>
      (await trackRow(title)).read<int>('id');

  Future<int> trackCount() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM tracks').getSingle())
          .read<int>('n');

  Future<Set<String>> tagsOf(String title) async {
    final rows = await db
        .customSelect(
          'SELECT g.name AS name FROM track_tags tt '
          'JOIN tags g ON g.id = tt.tag_id '
          'JOIN tracks t ON t.id = tt.track_id WHERE t.title = ?1',
          variables: [Variable(title)],
        )
        .get();
    return {for (final row in rows) row.read<String>('name')};
  }

  /// Credits as `name|role|creditedAs`, which is everything a credit means.
  Future<Set<String>> creditsOf(String title) async {
    final rows = await db
        .customSelect(
          'SELECT a.name AS name, tc.role AS role, '
          'COALESCE(tc.credited_as, \'\') AS credited_as FROM track_credits tc '
          'JOIN artists a ON a.id = tc.artist_id '
          'JOIN tracks t ON t.id = tc.track_id WHERE t.title = ?1',
          variables: [Variable(title)],
        )
        .get();
    return {
      for (final row in rows)
        '${row.read<String>('name')}|${row.read<String>('role')}|'
            '${row.read<String>('credited_as')}',
    };
  }

  Future<QueryRow?> artistRow(String name) => db
      .customSelect(
        'SELECT * FROM artists WHERE name = ?1 LIMIT 1',
        variables: [Variable(name)],
      )
      .getSingleOrNull();

  Future<int> artistCount(String name) async => (await db
          .customSelect(
            'SELECT COUNT(*) AS n FROM artists WHERE name = ?1',
            variables: [Variable(name)],
          )
          .getSingle())
      .read<int>('n');

  Future<QueryRow?> albumRow(String title) => db
      .customSelect(
        'SELECT * FROM albums WHERE title = ?1 LIMIT 1',
        variables: [Variable(title)],
      )
      .getSingleOrNull();

  Future<int> albumCount(String title) async => (await db
          .customSelect(
            'SELECT COUNT(*) AS n FROM albums WHERE title = ?1',
            variables: [Variable(title)],
          )
          .getSingle())
      .read<int>('n');

  Future<int> categoryCount(String slug) async => (await db
          .customSelect(
            'SELECT COUNT(*) AS n FROM tag_categories WHERE slug = ?1',
            variables: [Variable(slug)],
          )
          .getSingle())
      .read<int>('n');

  Future<String?> categoryNameOfTag(String tagName) async {
    final row = await db
        .customSelect(
          'SELECT c.name AS name FROM tags g '
          'JOIN tag_categories c ON c.id = g.category_id WHERE g.name = ?1',
          variables: [Variable(tagName)],
        )
        .getSingleOrNull();
    return row?.read<String>('name');
  }

  Future<List<String>> playlistTitles(String playlist) async {
    final rows = await db
        .customSelect(
          'SELECT t.title AS title FROM playlist_items i '
          'JOIN tracks t ON t.id = i.track_id '
          'JOIN playlists p ON p.id = i.playlist_id '
          'WHERE p.name = ?1 AND i.is_exclusion = 0 ORDER BY i.position, i.id',
          variables: [Variable(playlist)],
        )
        .get();
    return [for (final row in rows) row.read<String>('title')];
  }

  Future<String?> playlistQuery(String name) async {
    final row = await db
        .customSelect(
          'SELECT query FROM playlists WHERE name = ?1',
          variables: [Variable(name)],
        )
        .getSingleOrNull();
    return row?.readNullable<String>('query');
  }

  Future<String?> playlistParentName(String name) async {
    final row = await db
        .customSelect(
          'SELECT parent.name AS name FROM playlists child '
          'JOIN playlists parent ON parent.id = child.parent_id '
          'WHERE child.name = ?1',
          variables: [Variable(name)],
        )
        .getSingleOrNull();
    return row?.read<String>('name');
  }

  /// The artists a stored split rule resolves to, in order -- which is what
  /// proves the local ids inside its JSON were translated.
  Future<List<String>> splitRuleArtists(String raw) async {
    final row = await db
        .customSelect(
          'SELECT resolution FROM credit_split_rules WHERE raw_credit = ?1',
          variables: [Variable(raw)],
        )
        .getSingleOrNull();
    if (row == null) return const [];
    final ids = RegExp(r'"artistId":\s*(\d+)')
        .allMatches(row.read<String>('resolution'))
        .map((m) => int.parse(m.group(1)!))
        .toList();
    final names = <String>[];
    for (final id in ids) {
      final artist = await db
          .customSelect(
            'SELECT name FROM artists WHERE id = ?1',
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (artist != null) names.add(artist.read<String>('name'));
    }
    return names;
  }

  /// The digest of the picture an album points at, which is the only
  /// machine-independent thing about an image row.
  Future<String?> albumImageDigest(String title) async {
    final row = await db
        .customSelect(
          'SELECT i.sha256 AS sha256 FROM albums a '
          'JOIN images i ON i.id = a.image_id WHERE a.title = ?1',
          variables: [Variable(title)],
        )
        .getSingleOrNull();
    return row?.read<String>('sha256');
  }

  Future<int> imageCount() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM images').getSingle())
          .read<int>('n');

  Future<bool> hasSeparator(String token) async {
    final row = await db
        .customSelect(
          'SELECT 1 FROM separator_tokens WHERE token = ?1',
          variables: [Variable(token)],
        )
        .getSingleOrNull();
    return row != null;
  }
}
