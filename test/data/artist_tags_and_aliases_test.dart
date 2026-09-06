import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/tag_repository.dart';

/// Finding an artist by the other things they are known as.
///
/// Two gaps that felt like one: a filter box only ever matched the words
/// printed on a card, so an artist filed under a romanised name could not be
/// found by the name their listeners actually use, and a tag put on a person
/// said nothing about a single song they made.
void main() {
  late MarmeladeDatabase db;
  late LibraryRepository library;
  late TagRepository tags;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    library = LibraryRepository(db);
    tags = TagRepository(db: db, searchIndexer: SearchIndexer(db));
  });
  tearDown(() => db.close());

  Future<int> artist(String name) =>
      db.into(db.artists).insert(ArtistsCompanion.insert(
            name: name,
            nameKey: name.toLowerCase(),
          ));

  Future<void> alias(int artistId, String text) =>
      db.into(db.artistAliases).insert(ArtistAliasesCompanion.insert(
            artistId: artistId,
            alias: text,
            aliasKey: text.toLowerCase(),
          ));

  Future<int> tag(String name) => db.into(db.tags).insert(TagsCompanion.insert(
        name: name,
        nameKey: name.toLowerCase(),
      ));

  Future<int> track(String title) =>
      db.into(db.tracks).insert(TracksCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
          ));

  Future<void> credit(int trackId, int artistId) =>
      db.into(db.trackCredits).insert(TrackCreditsCompanion.insert(
            trackId: trackId,
            artistId: artistId,
          ));

  group('what an artist card carries', () {
    test('every name they go by, so a filter can match one', () async {
      final id = await artist('PinocchioP');
      await alias(id, 'ピノキオピー');
      await credit(await track('Song'), id);

      final cards = await library.watchArtists().first;

      expect(cards.single.aliases, ['ピノキオピー']);
      expect(cards.single.aliasCount, 1, reason: 'still what the card prints');
    });

    test('their tags, so "chiptune" finds the people who make it', () async {
      final id = await artist('Camellia');
      final tagId = await tag('chiptune');
      await db.into(db.artistTags).insert(
            ArtistTagsCompanion.insert(artistId: id, tagId: tagId),
          );
      await credit(await track('Song'), id);

      final cards = await library.watchArtists().first;

      expect(cards.single.tags, ['chiptune']);
    });

    test('a name holding a comma survives being carried', () async {
      // group_concat joins on a separator, and a comma would split a name
      // like "Tyler, the Creator" into two half-names that match nothing.
      final id = await artist('Someone');
      await alias(id, 'Tyler, the Creator');
      await credit(await track('Song'), id);

      final cards = await library.watchArtists().first;

      expect(cards.single.aliases, ['Tyler, the Creator']);
    });
  });

  group('a tag on an artist', () {
    test('reaches the tracks they are credited on', () async {
      // The point of tagging a person: it says something about their music.
      final id = await artist('Camellia');
      final tagId = await tag('chiptune');
      await db.into(db.artistTags).insert(
            ArtistTagsCompanion.insert(artistId: id, tagId: tagId),
          );
      final trackId = await track('Song');
      await credit(trackId, id);

      final reached = await tags.watchTrackIdsWithTag(tagId).first;

      expect(reached, [trackId]);
    });

    test('counts a guest appearance, since that is still their work',
        () async {
      final host = await artist('Someone Else');
      final guest = await artist('Camellia');
      final tagId = await tag('chiptune');
      await db.into(db.artistTags).insert(
            ArtistTagsCompanion.insert(artistId: guest, tagId: tagId),
          );
      final trackId = await track('A collaboration');
      await credit(trackId, host);
      await credit(trackId, guest);

      expect(await tags.watchTrackIdsWithTag(tagId).first, [trackId]);
    });

    test('stays off the track\'s own tag line', () async {
      // Reaching a track and labelling it are different things. A song would
      // otherwise say more about its cast than about the recording, and the
      // chip would offer a removal that cannot work from there -- the tag
      // does not live on the track.
      final id = await artist('Camellia');
      final tagId = await tag('chiptune');
      await db.into(db.artistTags).insert(
            ArtistTagsCompanion.insert(artistId: id, tagId: tagId),
          );
      final trackId = await track('Song');
      await credit(trackId, id);

      final attached = await tags.watchTagsOf(TagTarget.track, trackId).first;

      expect(attached, isEmpty, reason: 'not shown on the track');
      expect(await tags.watchTrackIdsWithTag(tagId).first, [trackId],
          reason: 'but the tag still finds it');
    });

    test('does not travel the other way: a song tag stays on the song',
        () async {
      // A recording being live says nothing about the person who made it.
      final id = await artist('Camellia');
      final tagId = await tag('live');
      final trackId = await track('Song');
      await credit(trackId, id);
      await db.into(db.trackTags).insert(
            TrackTagsCompanion.insert(trackId: trackId, tagId: tagId),
          );

      expect(await tags.watchArtistIdsWithTag(tagId).first, isEmpty);
    });

    test('lists the artists wearing it, for the tag\'s own page', () async {
      final id = await artist('Camellia');
      final tagId = await tag('chiptune');
      await db.into(db.artistTags).insert(
            ArtistTagsCompanion.insert(artistId: id, tagId: tagId),
          );

      expect(await tags.watchArtistIdsWithTag(tagId).first, [id]);
    });
  });
}
