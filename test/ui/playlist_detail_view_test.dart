import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/playlist_repository.dart'
    show PlaylistEntry;
import 'package:marmelade/data/repositories/tag_repository.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/features/playlists/playlist_detail_view.dart';

import '../support/silent_player.dart';

/// The playlist header: what replaced the full "Tags" card.
///
/// Tags now show the same way an album's do -- a line in the header, not a
/// card of their own below the query and the track list.
void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() => db.close());

  const playlist = PlaylistCard(
    id: 5,
    name: 'Late Night Coding',
    kind: 'manual',
    trackCount: 0,
  );

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playbackEngineProvider.overrideWithValue(SilentEngine()),
          playerProvider.overrideWith(() => IdlePlayer(db)),
          playlistProvider(5).overrideWith((ref) => Stream.value(playlist)),
          playlistTracksProvider(5)
              .overrideWith((ref) => Stream.value(const <TrackRow>[])),
          playlistEntriesProvider(5)
              .overrideWith((ref) => Stream.value(const <PlaylistEntry>[])),
          taggedProvider.overrideWith((ref) => Stream.value(const [])),
          attachedTagsProvider((target: TagTarget.playlist, id: 5))
              .overrideWith((ref) => Stream.value(const <AttachedTag>[])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PlaylistDetailView(
              playlistId: 5,
              onBack: () {},
              onOpenPlaylist: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tags show as a line, not the old card', (tester) async {
    await pump(tester);

    expect(tester.takeException(), isNull);
    // The old card's own heading and explanation are gone.
    expect(find.text('Tags'), findsNothing);
    expect(
      find.textContaining('describe the artist'),
      findsNothing,
    );
    // The compact line is there instead, reachable the same way an album's is.
    expect(find.text('Add a tag'), findsOneWidget);
  });
}
