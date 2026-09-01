import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/widgets/track_list.dart';

import '../support/silent_player.dart';

/// How a list broken into releases treats a release of one.
///
/// An artist page is mostly singles for a lot of the library, and a heading
/// above a single row says the album name twice at four times the height.
void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() => db.close());

  TrackRow track(int id, String title, String album) => TrackRow(
        id: id,
        title: title,
        credits: const [],
        durationMs: 200000,
        albumId: album.hashCode,
        albumTitle: album,
      );

  Future<void> pump(WidgetTester tester, List<TrackRow> tracks) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playbackEngineProvider.overrideWithValue(SilentEngine()),
          playerProvider.overrideWith(() => IdlePlayer(db)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TrackList(tracks: tracks, groupByAlbum: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a release of one track gets no heading of its own',
      (tester) async {
    await pump(tester, [
      track(1, 'Alpha one', 'Alpha'),
      track(2, 'Alpha two', 'Alpha'),
      track(3, 'A single', 'Just This'),
    ]);

    // The album with two tracks is still headed.
    expect(find.text('Alpha'), findsOneWidget);
    // The single is not: only the track row carries its name.
    expect(find.text('A single'), findsOneWidget);
    expect(find.text('2 tracks'), findsOneWidget);
    expect(find.text('1 track'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a release of several still gets one', (tester) async {
    await pump(tester, [
      track(1, 'Alpha one', 'Alpha'),
      track(2, 'Alpha two', 'Alpha'),
    ]);

    expect(find.text('2 tracks'), findsOneWidget);
  });

  testWidgets('the row actions are live without hovering first',
      (tester) async {
    // Turning a button from disabled to enabled rewrites its semantics node,
    // and the Windows accessibility bridge treats that as the node leaving and
    // a new one arriving: hovering twenty rows threw 85 AXTree errors. Keeping
    // them enabled throws one. Pinned here because the disabled-until-hovered
    // version looks perfectly reasonable in the source.
    await pump(tester, [track(1, 'Alpha one', 'Alpha')]);

    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.playlist_add),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('every track is still listed, headed or not', (tester) async {
    await pump(tester, [
      track(1, 'Alpha one', 'Alpha'),
      track(2, 'Alpha two', 'Alpha'),
      track(3, 'A single', 'Just This'),
      track(4, 'Another single', 'And This'),
    ]);

    for (final title in [
      'Alpha one',
      'Alpha two',
      'A single',
      'Another single',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
  });
}
