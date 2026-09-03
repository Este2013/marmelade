import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/settings_repository.dart';
import 'package:marmelade/data/transfer/library_sync.dart';
import 'package:marmelade/data/transfer/transfer_bundle.dart';
import 'package:marmelade/features/settings/transfer_section.dart';

/// The multi-computer settings.
///
/// The two things worth pinning down in the UI: that the expensive option is
/// off until asked for, and that the page says which computer this is and
/// what it is sharing with -- because the whole feature is invisible
/// otherwise, and an invisible sync is one nobody trusts.
void main() {
  /// Set MARMELADE_UI_SHOTS to a directory to keep a PNG of the section.
  /// The same escape hatch `app_render_test.dart` uses, and the only way to
  /// actually look at this UI: every OS-level capture of the real window on
  /// Windows comes back blank, and pointing the real app at the real library
  /// is not something a test should do.
  final shotDir = Platform.environment['MARMELADE_UI_SHOTS'];

  Future<void> capture(WidgetTester tester, String name) async {
    if (shotDir == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ImageByteFormat.png);
      image.dispose();
      if (bytes == null) return;
      final file = File(p.join(shotDir, '$name.png'));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes.buffer.asUint8List());
    });
  }

  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() => db.close());

  const identity = TransferOrigin(
    machineId: 'abc123',
    machineName: 'Work PC',
    appVersion: '1.0.0',
  );

  Future<void> pump(
    WidgetTester tester, {
    String folder = '',
    List<SyncPeer> peers = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    if (folder.isNotEmpty) {
      await SettingsRepository(db).set(SettingKeys.syncFolder, folder);
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          // Real PackageInfo needs a platform channel, and the version is
          // only stamped into the bundle for debugging.
          machineIdentityProvider.overrideWith((ref) async => identity),
          syncPeersProvider.overrideWith((ref) async => peers),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: TransferSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('says which computer this is', (tester) async {
    await pump(tester);

    expect(find.text('Another computer'), findsOneWidget);
    expect(find.textContaining('Work PC'), findsOneWidget);
  });

  testWidgets('the music files are off until asked for', (tester) async {
    // The user's own caution: a shared folder is often metered, so metadata
    // travels by default and gigabytes do not.
    await pump(tester);

    final audio = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Include the music files'),
    );
    expect(audio.value, isFalse);

    final artwork = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Include artwork'),
    );
    expect(artwork.value, isTrue);
  });

  testWidgets('turning the music files on is remembered', (tester) async {
    await pump(tester);

    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Include the music files'),
    );
    await tester.pumpAndSettle();

    expect(
      await SettingsRepository(db).get(SettingKeys.syncIncludeAudio, false),
      isTrue,
    );
  });

  testWidgets('with no folder set, it offers to pick one', (tester) async {
    await pump(tester);

    expect(find.text('Share through a folder'), findsOneWidget);
    expect(find.text('Share now'), findsNothing);
    expect(find.textContaining('Google Drive'), findsOneWidget);
  });

  testWidgets('with a folder set, it offers to share and says where',
      (tester) async {
    await pump(tester, folder: r'D:\Drive\marmelade');

    expect(find.text(r'D:\Drive\marmelade'), findsOneWidget);
    expect(find.text('Share now'), findsOneWidget);
    expect(find.text('Change folder'), findsOneWidget);
  });

  testWidgets('a folder with no other computers in it says so', (tester) async {
    await pump(tester, folder: r'D:\Drive\marmelade');

    expect(find.text('No other computers yet'), findsOneWidget);
  });

  testWidgets('another computer is listed with what it holds', (tester) async {
    await pump(
      tester,
      folder: r'D:\Drive\marmelade',
      peers: [
        SyncPeer(
          origin: const TransferOrigin(
            machineId: 'home',
            machineName: 'Home PC',
          ),
          directory: Directory(r'D:\Drive\marmelade\machines\home'),
          exportedAt: DateTime.now().toUtc().subtract(const Duration(hours: 3)),
          counts: const {'tracks': 1200, 'playlists': 8},
          isSelf: false,
          hasAudio: false,
        ),
      ],
    );

    expect(find.text('Home PC'), findsOneWidget);
    expect(find.textContaining('1200 tracks'), findsOneWidget);
    expect(find.textContaining('3 hours ago'), findsOneWidget);
    // Never read yet, so the tile says there is something to fetch.
    expect(find.textContaining('not read yet'), findsOneWidget);

    await capture(tester, 'transfer-section-sharing');
  });

  testWidgets('renders without a folder set, for a look at the empty state',
      (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    await capture(tester, 'transfer-section-unset');
  });
}
