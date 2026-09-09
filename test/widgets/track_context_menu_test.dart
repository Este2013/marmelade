import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/features/library/bulk_actions.dart';
import 'package:marmelade/widgets/selection.dart' show MenuAction;

import '../support/silent_player.dart';

/// [trackContextMenu] is the one right-click menu shared by every place a
/// track row shows up -- Songs, an album, an artist, a tag, a playlist. What
/// it offers has to change with what the caller can actually do: no "go to
/// the album" from the album's own page, no per-row destination once several
/// rows are selected.
void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() => db.close());

  const trackWithCredit = TrackRow(
    id: 1,
    title: 'Landmarks',
    credits: [TrackCreditRef(artistId: 9, name: 'Intikus', role: 'mainArtist')],
    durationMs: 79542,
    albumId: 469,
    albumTitle: 'Rain World: Downpour (Original Soundtrack)',
  );

  const trackNoCredit = TrackRow(
    id: 2,
    title: 'Untitled',
    credits: [],
    durationMs: 1000,
  );

  /// Builds the menu inside a real widget tree, since [trackContextMenu]
  /// needs a [WidgetRef] and a [BuildContext] the same way every call site
  /// does.
  Future<List<MenuAction>> menuFor(
    WidgetTester tester, {
    required TrackRow track,
    List<int>? ids,
    void Function(int)? onOpenAlbum,
    void Function(int)? onOpenArtist,
    void Function(int)? onEditTrack,
  }) async {
    late List<MenuAction> result;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playbackEngineProvider.overrideWithValue(SilentEngine()),
          playerProvider.overrideWith(() => IdlePlayer(db)),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              result = trackContextMenu(
                context,
                ref,
                track,
                ids: ids,
                onOpenAlbum: onOpenAlbum,
                onOpenArtist: onOpenArtist,
                onEditTrack: onEditTrack,
              );
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    return result;
  }

  List<String> labels(List<MenuAction> menu) =>
      [for (final a in menu) if (!a.isSeparator) a.label];

  testWidgets('offers the transport basics for a single track',
      (tester) async {
    final menu = await menuFor(tester, track: trackWithCredit);
    expect(labels(menu), containsAll(['Play', 'Play next', 'Add to the queue']));
  });

  testWidgets('offers "Edit track" when the caller can edit', (tester) async {
    final menu = await menuFor(
      tester,
      track: trackWithCredit,
      onEditTrack: (_) {},
    );
    expect(labels(menu), contains('Edit track'));
  });

  testWidgets('has no "Edit track" without an edit callback', (tester) async {
    final menu = await menuFor(tester, track: trackWithCredit);
    expect(labels(menu), isNot(contains('Edit track')));
  });

  testWidgets('always offers "Open in Explorer" for a single track',
      (tester) async {
    // Enabled even for a track that may turn out to have no file at all --
    // that is exactly the case someone needs the log line for, not a reason
    // to grey the option out before they have clicked it.
    final menu = await menuFor(tester, track: trackWithCredit);
    expect(labels(menu), contains('Open in Explorer'));
  });

  testWidgets('offers "Go to the album" only when the caller has somewhere '
      'to send it', (tester) async {
    final withoutHandler = await menuFor(tester, track: trackWithCredit);
    expect(labels(withoutHandler), isNot(contains('Go to the album')));

    final withHandler = await menuFor(
      tester,
      track: trackWithCredit,
      onOpenAlbum: (_) {},
    );
    expect(labels(withHandler), contains('Go to the album'));
  });

  testWidgets('names the credited artist to go to', (tester) async {
    final menu = await menuFor(
      tester,
      track: trackWithCredit,
      onOpenArtist: (_) {},
    );
    expect(labels(menu), contains('Go to Intikus'));
  });

  testWidgets('has no artist destination for an uncredited track',
      (tester) async {
    final menu = await menuFor(
      tester,
      track: trackNoCredit,
      onOpenArtist: (_) {},
    );
    expect(labels(menu).where((l) => l.startsWith('Go to')), isEmpty);
  });

  testWidgets('drops every per-row action once several tracks are selected',
      (tester) async {
    final menu = await menuFor(
      tester,
      track: trackWithCredit,
      ids: [1, 2, 3],
      onOpenAlbum: (_) {},
      onOpenArtist: (_) {},
      onEditTrack: (_) {},
    );
    final shown = labels(menu);
    expect(shown, contains('Play these 3'));
    expect(shown, isNot(contains('Go to the album')));
    expect(shown, isNot(contains('Edit track')));
    expect(shown, isNot(contains('Open in Explorer')));
  });
}
