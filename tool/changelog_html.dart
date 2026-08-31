// Renders changelog.json as a page, so the published URL is worth opening in a
// browser and not only by the app.
//
//   dart run tool/changelog_html.dart site/changelog.json site/index.html
//
// Deliberately one file with no assets: it is served from GitHub Pages next to
// the JSON, and a changelog that needs a build step to be readable is a
// changelog that will eventually stop being published.
import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  if (arguments.length < 2) {
    stderr.writeln('usage: changelog_html.dart <in.json> <out.html>');
    exit(2);
  }

  final json = jsonDecode(File(arguments[0]).readAsStringSync());
  final versions = (json as Map)['versions'];
  if (versions is! List) {
    stderr.writeln('changelog.json has no versions list');
    exit(1);
  }

  final body = StringBuffer();
  for (final entry in versions) {
    if (entry is! Map) continue;
    final version = _escape('${entry['version']}');
    final date = entry['date'];
    final headline = entry['headline'];

    body.writeln('<section>');
    body.writeln('<h2>$version'
        '${date is String ? ' <time>${_escape(date)}</time>' : ' <em>unreleased</em>'}'
        '</h2>');
    if (headline is String) {
      body.writeln('<p class="headline">${_escape(headline)}</p>');
    }

    // Grouped by kind, in a fixed order, so a long list is skimmable.
    for (final kind in const ['added', 'changed', 'fixed', 'removed']) {
      final changes = [
        for (final change in entry['changes'] as List? ?? const [])
          if (change is Map && change['kind'] == kind) '${change['text']}',
      ];
      if (changes.isEmpty) continue;
      body.writeln('<h3>${kind[0].toUpperCase()}${kind.substring(1)}</h3>');
      body.writeln('<ul>');
      for (final text in changes) {
        body.writeln('<li>${_escape(text)}</li>');
      }
      body.writeln('</ul>');
    }
    body.writeln('</section>');
  }

  File(arguments[1]).writeAsStringSync(_page(body.toString()));
  stderr.writeln('wrote ${arguments[1]}');
}

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _page(String body) => '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>marmelade — changelog</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #fdfaf6; --fg: #211c17; --muted: #6d635a;
    --accent: #e8730c; --line: #e6ddd3; --card: #fffdfb;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #17130f; --fg: #f2ece6; --muted: #a99e93;
      --accent: #ffb26b; --line: #332b23; --card: #1f1a15;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 48px 24px 96px;
    background: var(--bg); color: var(--fg);
    font: 16px/1.6 "Segoe UI", system-ui, -apple-system, sans-serif;
  }
  main { max-width: 760px; margin: 0 auto; }
  h1 { font-size: 2rem; font-weight: 600; margin: 0 0 4px; }
  .sub { color: var(--muted); margin: 0 0 40px; }
  .sub a { color: var(--accent); }
  section {
    background: var(--card); border: 1px solid var(--line);
    border-radius: 14px; padding: 24px 28px; margin-bottom: 20px;
  }
  h2 { font-size: 1.35rem; margin: 0 0 6px; }
  h2 time, h2 em { font-size: .8rem; font-weight: 400; color: var(--muted); }
  .headline { margin: 0 0 16px; color: var(--muted); }
  h3 {
    font-size: .75rem; text-transform: uppercase; letter-spacing: .09em;
    color: var(--accent); margin: 20px 0 6px;
  }
  ul { margin: 0; padding-left: 22px; }
  li { margin-bottom: 6px; }
  footer { max-width: 760px; margin: 40px auto 0; color: var(--muted); font-size: .85rem; }
  footer a { color: var(--accent); }
</style>
</head>
<body>
<main>
<h1>marmelade</h1>
<p class="sub">
  A music player that believes "Name1 x Name2" is two artists.
  <a href="https://github.com/Este2013/marmelade">Source</a> ·
  <a href="https://github.com/Este2013/marmelade/releases">Downloads</a> ·
  <a href="changelog.json">changelog.json</a>
</p>
$body
</main>
<footer>
  Generated from <code>lib/core/changelog/changelog.dart</code>. The app reads
  the JSON next to this page.
</footer>
</body>
</html>
''';
