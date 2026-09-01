import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/edit_repository.dart';
import 'package:marmelade/features/edit/artist_links_dialog.dart';
import 'package:marmelade/features/edit/link_visuals.dart';
import 'package:marmelade/services/art/art_store.dart';

/// A repository that keeps its links in memory rather than in the database.
///
/// A real drift stream cannot be watched from a widget test: cancelling one
/// schedules a cleanup timer the test binding's fake clock never drains (see
/// app_render_test.dart). This dialog is reactive by design -- a preset click
/// has to make a new row appear -- so the fake has to be reactive too, not
/// just a recorder.
class _RecordingEditRepository extends EditRepository {
  _RecordingEditRepository(MarmeladeDatabase db)
      : super(
          db: db,
          searchIndexer: SearchIndexer(db),
          artStore: ArtStore(Directory.systemTemp),
        );

  final links = <LinkRow>[];
  var _nextId = 1;
  final controller = StreamController<List<LinkRow>>.broadcast();

  void _emit() => controller.add(List.unmodifiable(links));

  @override
  Stream<List<LinkRow>> watchArtistLinks(int artistId) async* {
    yield List.unmodifiable(links);
    yield* controller.stream;
  }

  @override
  Future<int?> addArtistLink(
    int artistId,
    String url, {
    LinkKind kind = LinkKind.other,
    String? label,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    final id = _nextId++;
    links.add(LinkRow(id: id, url: trimmed, kind: kind, label: label));
    _emit();
    return id;
  }

  @override
  Future<void> updateArtistLink(
    int linkId, {
    required String url,
    required LinkKind kind,
    String? label,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    final index = links.indexWhere((l) => l.id == linkId);
    if (index == -1) return;
    links[index] = LinkRow(id: linkId, url: trimmed, kind: kind, label: label);
    _emit();
  }

  @override
  Future<void> removeArtistLink(int linkId) async {
    links.removeWhere((l) => l.id == linkId);
    _emit();
  }
}

/// Adding, editing and removing an artist's links from their own dialog.
///
/// The point of moving this out of the artist-editing form: there is no
/// "Kind" to pick by hand any more, and nothing here waits for a page-level
/// Save -- every action here writes as soon as it happens, like a tag does.
void main() {
  late MarmeladeDatabase db;
  late _RecordingEditRepository repository;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    repository = _RecordingEditRepository(db);
  });

  tearDown(() async {
    await repository.controller.close();
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          editRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => const ArtistLinksDialog(
                      artistId: 1,
                      artistName: 'LukHash',
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('empty says so, and still offers the presets', (tester) async {
    await pump(tester);

    expect(find.textContaining('No links yet'), findsOneWidget);
    expect(find.text('Add from a site'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a preset with a guessable pattern adds a real guess',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byTooltip('Bandcamp'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(TextField, 'https://lukhash.bandcamp.com'),
      findsOneWidget,
    );
    expect(repository.links, hasLength(1));
    expect(repository.links.single.url, 'https://lukhash.bandcamp.com');
    expect(repository.links.single.kind, LinkKind.bandcamp);
  });

  testWidgets('Booth.pm follows the same subdomain shape as Bandcamp',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byTooltip('Booth.pm'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(TextField, 'https://lukhash.booth.pm'),
      findsOneWidget,
    );
    expect(repository.links.single.kind, LinkKind.booth);
  });

  testWidgets('a preset with no guessable pattern still adds an editable row',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byTooltip('Spotify'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'https://'), findsOneWidget);
    expect(repository.links.single.kind, LinkKind.spotify);
  });

  testWidgets('the new row is focused and its text selected, ready to type',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Bandcamp'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'https://lukhash.bandcamp.com'),
    );
    expect(field.focusNode?.hasFocus, isTrue);
    expect(
      field.controller?.selection,
      const TextSelection(
        baseOffset: 0,
        extentOffset: 'https://lukhash.bandcamp.com'.length,
      ),
    );
  });

  testWidgets('editing the URL infers the kind live, and saves on blur',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Website'));
    await tester.pumpAndSettle();
    expect(repository.links.single.kind, LinkKind.website);

    await tester.enterText(
      find.widgetWithText(TextField, 'https://'),
      'https://soundcloud.com/lukhash',
    );
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(repository.links.single.url, 'https://soundcloud.com/lukhash');
    expect(repository.links.single.kind, LinkKind.soundcloud);
  });

  testWidgets('a label can be set alongside the URL', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Bandcamp'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, ''), 'My music');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(repository.links.single.label, 'My music');
  });

  testWidgets('removing a link deletes it immediately', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Bandcamp'));
    await tester.pumpAndSettle();
    expect(repository.links, hasLength(1));

    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();

    expect(repository.links, isEmpty);
    expect(find.textContaining('No links yet'), findsOneWidget);
  });

  testWidgets('clearing the field on blur does not blank the saved link',
      (tester) async {
    // A cleared field mid-edit is not a request to overwrite a real URL with
    // nothing -- only the remove button deletes a link.
    await pump(tester);
    await tester.tap(find.byTooltip('Bandcamp'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'https://lukhash.bandcamp.com'),
      '',
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(repository.links.single.url, 'https://lukhash.bandcamp.com');
  });

  testWidgets('every preset kind is offered, favicon or fallback icon alike',
      (tester) async {
    await pump(tester);

    for (final kind in LinkKind.values) {
      expect(
        find.byTooltip(linkKindLabel(kind)),
        findsOneWidget,
        reason: kind.name,
      );
    }
  });
}
