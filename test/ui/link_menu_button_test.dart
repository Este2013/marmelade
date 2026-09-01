import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/enums.dart';
import 'package:marmelade/data/repositories/edit_repository.dart';
import 'package:marmelade/features/edit/link_menu_button.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Records what it was asked to launch, rather than actually launching it.
class _RecordingLauncher extends UrlLauncherPlatform {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

/// The link icon that opens an artist's (or album's) external links.
void main() {
  late _RecordingLauncher launcher;

  setUp(() {
    launcher = _RecordingLauncher();
    UrlLauncherPlatform.instance = launcher;
  });

  const links = [
    LinkRow(id: 1, url: 'https://lukhash.bandcamp.com', kind: LinkKind.bandcamp),
    LinkRow(
      id: 2,
      url: 'https://x.com/LukHash',
      kind: LinkKind.twitter,
      label: 'Twitter/X',
    ),
  ];

  Future<void> pump(WidgetTester tester, List<LinkRow> links) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LinkMenuButton(links: links)),
      ),
    );
  }

  testWidgets('nothing is shown when there is nothing to link to',
      (tester) async {
    await pump(tester, const []);

    expect(find.byIcon(Icons.link), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the icon opens a menu naming every link', (tester) async {
    await pump(tester, links);
    expect(find.byIcon(Icons.link), findsOneWidget);

    await tester.tap(find.byIcon(Icons.link));
    await tester.pumpAndSettle();

    // The one with a label uses it; the one without falls back to the kind.
    expect(find.text('Twitter/X'), findsOneWidget);
    expect(find.text('Bandcamp'), findsOneWidget);
  });

  testWidgets('choosing a link launches its URL', (tester) async {
    await pump(tester, links);
    await tester.tap(find.byIcon(Icons.link));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bandcamp'));
    await tester.pumpAndSettle();

    expect(launcher.launched, ['https://lukhash.bandcamp.com']);
  });
}
