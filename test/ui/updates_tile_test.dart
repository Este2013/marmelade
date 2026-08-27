import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/features/settings/updates_tile.dart';
import 'package:marmelade/services/updates/update_service.dart';

/// The update tile, driven the way a person drives it.
///
/// The service has its own tests; what this covers is the wiring, and the one
/// thing that must never go wrong in the UI: a check that could not be made
/// must not read as "up to date".
void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() => db.close());

  Future<void> pump(
    WidgetTester tester, {
    required Object? body,
    int status = 200,
    String current = '1.0.0',
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appVersionProvider.overrideWith((ref) async => current),
          updateServiceProvider.overrideWith(
            (ref) async => UpdateService(
              repository: 'Este2013/marmelade',
              currentVersion: current,
              client: MockClient(
                (request) async => http.Response(
                  jsonEncode(body),
                  status,
                  headers: {'content-type': 'application/json'},
                ),
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: UpdatesTile())),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> check(WidgetTester tester) async {
    await tester.tap(find.text('Check for updates'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  List<Map<String, dynamic>> releases(String tag) => [
        {
          'tag_name': tag,
          'draft': false,
          'prerelease': false,
          'html_url': 'https://example.invalid/releases/$tag',
          'published_at': '2026-08-01T10:00:00Z',
          'body': 'What changed',
        }
      ];

  testWidgets('it shows the running version before anything is checked',
      (tester) async {
    await pump(tester, body: releases('v1.0.0'));

    expect(find.text('marmelade 1.0.0'), findsOneWidget);
    expect(find.textContaining('Nothing is downloaded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a newer release is announced, with a way to get it',
      (tester) async {
    await pump(tester, body: releases('v1.4.0'));
    await check(tester);

    expect(find.text('marmelade 1.4.0 is out'), findsOneWidget);
    expect(find.text('Open the release'), findsOneWidget);
    expect(find.text('What changed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the newest release says so', (tester) async {
    await pump(tester, body: releases('v1.0.0'));
    await check(tester);

    expect(find.text('This is the newest release.'), findsOneWidget);
    expect(find.text('Open the release'), findsNothing);
  });

  testWidgets('a failed check never reads as up to date', (tester) async {
    // The whole point. GitHub rate-limits unauthenticated callers, and an app
    // that answers "you are up to date" to a 403 is an app whose update check
    // is worse than none.
    await pump(tester, body: const [], status: 403);
    await check(tester);

    expect(find.text('This is the newest release.'), findsNothing);
    expect(find.textContaining('403'), findsOneWidget);
  });

  testWidgets('the pre-release switch is off until asked for', (tester) async {
    await pump(tester, body: releases('v1.0.0'));

    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.value, isFalse);
  });
}
