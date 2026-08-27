import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/app/theme/app_theme.dart';
import 'package:marmelade/data/db/enums.dart';
import 'package:marmelade/data/repositories/edit_repository.dart';
import 'package:marmelade/features/edit/album_editor_view.dart';
import 'package:marmelade/features/edit/artist_editor_view.dart';
import 'package:marmelade/features/edit/track_editor_view.dart';
import 'package:marmelade/services/art/art_store.dart';

/// Renders the editors and checks they lay out.
///
/// Fed from overridden providers rather than a database, for the same reason as
/// the rest of the widget tests: cancelling a drift query stream schedules a
/// cleanup timer that the test binding's fake clock never drains, and the test
/// hangs rather than failing. What the editors *write* is covered against a
/// real schema in test/data/edit_repository_test.dart, which is the right place
/// for it.
///
/// A layout overflow is reported as a FlutterError, so `takeException` catches
/// it. That is how the dropdowns which sized themselves to their widest item
/// and burst out of their boxes were found -- these tests exist mostly to stop
/// that happening again.
void main() {
  late Directory artRoot;

  setUp(() {
    artRoot = Directory.systemTemp.createTempSync('marmelade_editor_art_');
  });

  tearDown(() {
    if (artRoot.existsSync()) artRoot.deleteSync(recursive: true);
  });

  ArtistEdit artistEdit({
    String name = 'Koiflower,Bangler',
    ArtistKind kind = ArtistKind.unknown,
    List<AliasRow> aliases = const [],
    List<MembershipRow> members = const [],
    List<MembershipRow> memberOf = const [],
    List<LinkRow> links = const [],
  }) =>
      ArtistEdit(
        id: 1,
        name: name,
        kind: kind,
        neverSplit: false,
        isVerified: false,
        trackCount: 3,
        aliases: aliases,
        links: links,
        members: members,
        memberOf: memberOf,
      );

  const albumEdit = AlbumEdit(
    id: 1,
    title: 'AD:HOUSE Winter 4',
    isVariousArtists: false,
    isVerified: false,
    trackCount: 18,
    releaseYear: 2024,
    albumArtistId: 7,
    albumArtistName: 'Diverse System',
  );

  const trackEdit = TrackEdit(
    id: 1,
    title: 'Feel Right',
    isVerified: false,
    trackNo: 2,
    albumId: 1,
    albumTitle: 'AD:HOUSE Winter 4',
    credits: [
      CreditEdit(artistId: 5, name: 'Koiflower', role: CreditRole.mainArtist),
      CreditEdit(artistId: 6, name: 'Bangler', role: CreditRole.featured),
    ],
  );

  Widget wrap(
    Widget child, {
    ArtistEdit? artist,
    AlbumEdit? album,
    TrackEdit? track,
  }) =>
      ProviderScope(
        overrides: [
          artStoreProvider.overrideWithValue(ArtStore(artRoot)),
          artistEditProvider.overrideWith((ref, id) => Stream.value(artist)),
          albumEditProvider.overrideWith((ref, id) => Stream.value(album)),
          trackEditProvider.overrideWith((ref, id) => Stream.value(track)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          darkTheme:
              buildTheme(seed: marmeladeSeed, brightness: Brightness.dark),
          home: Scaffold(body: child),
        ),
      );

  Future<void> open(WidgetTester tester, Widget app,
      {Size size = const Size(1200, 900)}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// The Save button, so its enabled state can be checked.
  FilledButton saveButton(WidgetTester tester) => tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Save'),
          matching: find.byType(FilledButton),
        ),
      );

  group('artist editor', () {
    testWidgets('shows every part of the artist', (tester) async {
      await open(
        tester,
        wrap(
          const ArtistEditorView(artistId: 1, onBack: _noop),
          artist: artistEdit(
            aliases: const [
              AliasRow(id: 1, alias: 'ピノキオピー', kind: AliasKind.nativeScript),
            ],
            links: const [
              LinkRow(id: 1, url: 'https://example.test', kind: LinkKind.website),
            ],
          ),
        ),
        // Tall enough that the lazy list builds every section: this test is
        // about what the editor offers, not about its scrolling.
        size: const Size(1200, 1800),
      );

      expect(find.text('Other names'), findsOne);
      expect(find.text('ピノキオピー'), findsOne);
      expect(find.text('Part of'), findsOne);
      expect(find.text('Links'), findsOne);
      expect(find.text('Split or merge'), findsOne);
      // Both structural operations are offered, and both are explained.
      expect(find.text('Split'), findsOne);
      expect(find.text('Merge'), findsOne);
      // Save is inert until something actually changes.
      expect(saveButton(tester).onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a person has no members section', (tester) async {
      await open(
        tester,
        wrap(
          const ArtistEditorView(artistId: 1, onBack: _noop),
          artist: artistEdit(kind: ArtistKind.person),
        ),
      );
      expect(find.text('Members'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a group lists its members', (tester) async {
      await open(
        tester,
        wrap(
          const ArtistEditorView(artistId: 1, onBack: _noop),
          artist: artistEdit(
            name: 'Xista',
            kind: ArtistKind.group,
            members: const [
              MembershipRow(
                id: 1,
                artistId: 2,
                name: 'xi',
                kind: ArtistKind.person,
                role: 'composer',
                trackCount: 12,
              ),
            ],
          ),
        ),
      );
      expect(find.text('Members'), findsOne);
      expect(find.text('xi'), findsOne);
      expect(find.textContaining('composer'), findsOne);
      expect(tester.takeException(), isNull);
    });

    testWidgets('typing a new name enables Save', (tester) async {
      await open(
        tester,
        wrap(
          const ArtistEditorView(artistId: 1, onBack: _noop),
          artist: artistEdit(name: 'LukHassh'),
        ),
      );
      expect(saveButton(tester).onPressed, isNull);

      await tester.enterText(
        find.widgetWithText(TextField, 'LukHassh'),
        'LukHash',
      );
      await tester.pump();
      expect(saveButton(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a missing artist says so rather than showing a blank form',
        (tester) async {
      await open(
        tester,
        wrap(const ArtistEditorView(artistId: 1, onBack: _noop)),
      );
      expect(find.text('That artist is gone'), findsOne);
    });

    testWidgets('lays out at the narrowest window the app allows',
        (tester) async {
      // Where the overflowing dropdowns showed up.
      await open(
        tester,
        wrap(
          const ArtistEditorView(artistId: 1, onBack: _noop),
          artist: artistEdit(kind: ArtistKind.group),
        ),
        size: const Size(860, 620),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('album editor', () {
    testWidgets('shows the release and its album artist', (tester) async {
      await open(
        tester,
        wrap(
          const AlbumEditorView(albumId: 1, onBack: _noop),
          album: albumEdit,
        ),
      );

      expect(find.text('Diverse System'), findsOne);
      expect(find.text('Various artists'), findsOne);
      expect(find.widgetWithText(TextField, '2024'), findsOne);
      expect(saveButton(tester).onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lays out at the narrowest window', (tester) async {
      await open(
        tester,
        wrap(
          const AlbumEditorView(albumId: 1, onBack: _noop),
          album: albumEdit,
        ),
        size: const Size(860, 620),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('track editor', () {
    testWidgets('shows the track and every credit with its role',
        (tester) async {
      await open(
        tester,
        wrap(
          const TrackEditorView(trackId: 1, onBack: _noop),
          track: trackEdit,
        ),
      );

      expect(find.text('Credits'), findsOne);
      expect(find.text('Koiflower'), findsOne);
      expect(find.text('Bangler'), findsOne);
      expect(find.text('Main artist'), findsOne);
      expect(find.text('Featured'), findsOne);
      expect(find.byTooltip('Remove'), findsExactly(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('removing a credit enables Save', (tester) async {
      await open(
        tester,
        wrap(
          const TrackEditorView(trackId: 1, onBack: _noop),
          track: trackEdit,
        ),
      );
      expect(saveButton(tester).onPressed, isNull);

      await tester.tap(find.byTooltip('Remove').first);
      await tester.pump();

      expect(find.byTooltip('Remove'), findsOne);
      expect(saveButton(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lays out at the narrowest window', (tester) async {
      await open(
        tester,
        wrap(
          const TrackEditorView(trackId: 1, onBack: _noop),
          track: trackEdit,
        ),
        size: const Size(860, 620),
      );
      expect(tester.takeException(), isNull);
    });
  });
}

void _noop() {}
