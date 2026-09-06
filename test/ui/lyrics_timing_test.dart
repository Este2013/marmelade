import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/data/repositories/lyrics_repository.dart';
import 'package:marmelade/data/repositories/queue_repository.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/features/lyrics/lyrics_editor_dialog.dart';
import 'package:marmelade/services/audio/playback_engine.dart' show PlaybackStatus;
import 'package:marmelade/services/audio/player_controller.dart';

import '../support/silent_player.dart';

/// Timing lyrics against the song by hand.
///
/// The job is one keypress per line for three minutes. A button beside the
/// scrubber can do it, but reaching for the mouse between every line is what
/// makes the work miserable -- and the pointer is nowhere near the words
/// anyway. So the keyboard has to do it, and it has to stamp the position the
/// song is *actually* at.
void main() {
  const trackId = 7;
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });
  tearDown(() => db.close());

  Future<void> pump(
    WidgetTester tester, {
    required bool thisTrackIsPlaying,
    Duration at = const Duration(minutes: 1, seconds: 12, milliseconds: 340),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playbackEngineProvider.overrideWithValue(SilentEngine()),
          playerProvider.overrideWith(
            () => thisTrackIsPlaying ? _PlayingThis(db) : IdlePlayer(db),
          ),
          playbackPositionProvider.overrideWith((ref) => Stream.value(at)),
          trackLyricsProvider(trackId).overrideWith(
            (ref) => Stream.value(const TrackLyrics(trackId: trackId)),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: LyricsEditorDialog(trackId: trackId)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Unmounts the tree while the test can still pump.
  ///
  /// Drift posts a zero-duration timer when a query stream is cancelled, and
  /// the scope is otherwise disposed after the last pump -- so the binding
  /// finds a timer pending after the tree is gone and fails the test on it.
  /// Closing the tree deliberately, then pumping once, lets that cleanup run
  /// where it belongs. Cheaper than faking every provider that happens to
  /// read the database.
  Future<void> closeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // A real duration, not zero: the cleanup is a Timer, and the fake clock
    // has to be moved for it to fire.
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> typeLines(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
  }

  /// Puts the caret at the very start, where a line begins.
  Future<void> caretToStart(WidgetTester tester) async {
    final field = tester.widget<TextField>(find.byType(TextField).last);
    field.controller!.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
  }

  testWidgets('Ctrl+Enter stamps the line at the position the song is at',
      (tester) async {
    await pump(tester, thisTrackIsPlaying: true);
    await typeLines(tester, 'first line\nsecond line');
    await caretToStart(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.controller!.text, startsWith('[01:12.34]first line'));
    await closeTree(tester);
  });

  testWidgets('and leaves the caret on the next line, ready for the next one',
      (tester) async {
    // The whole point: the same keystroke, over and over, down the song.
    await pump(tester, thisTrackIsPlaying: true);
    await typeLines(tester, 'first line\nsecond line');
    await caretToStart(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField).last);
    final text = field.controller!.text;
    expect(
      field.controller!.selection.baseOffset,
      text.indexOf('second line'),
      reason: 'the caret sits where the next stamp belongs',
    );
    await closeTree(tester);
  });

  testWidgets('does nothing while a different song is playing',
      (tester) async {
    // A position read off another track would write plausible nonsense --
    // timestamps that look right and line up with nothing.
    await pump(tester, thisTrackIsPlaying: false);
    await typeLines(tester, 'first line');
    await caretToStart(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.controller!.text, 'first line');
    await closeTree(tester);
  });
}

/// A player that says this very track is the one on.
class _PlayingThis extends PlayerController {
  _PlayingThis(MarmeladeDatabase db)
      : super(
          engine: SilentEngine(),
          queueRepository: QueueRepository(db),
          libraryRepository: LibraryRepository(db),
          db: db,
        );

  @override
  PlayerSnapshot build() => const PlayerSnapshot(
        status: PlaybackStatus.playing,
        currentIndex: 0,
        duration: Duration(minutes: 4),
        current: _entry,
      );

  static const _entry = PlayableTrack(
    trackId: 7,
    filePath: r'C:\Music\idol.flac',
    title: 'Idol',
    artistLine: 'YOASOBI',
    durationMs: 240000,
  );
}
