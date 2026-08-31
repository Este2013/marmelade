// Turns lib/core/changelog/changelog.dart into the JSON that CI publishes.
//
//   dart run tool/changelog_json.dart              # to stdout
//   dart run tool/changelog_json.dart out.json     # to a file
//   dart run tool/changelog_json.dart --check 1.2.0
//
// Written in Dart and importing the changelog directly, rather than parsing the
// file with a regex in the workflow: the compiler is already the thing that
// knows how to read Dart, and a release pipeline that silently drops an entry
// because a quote moved is not worth having.
import 'dart:convert';
import 'dart:io';

import 'package:marmelade/core/changelog/changelog.dart';

void main(List<String> arguments) {
  final args = arguments.toList();

  // --check <version>: the release workflow's gate. A tag whose changelog
  // entry is missing or undated means someone tagged before writing down what
  // the version does, which is exactly when it is cheapest to notice.
  final checkIndex = args.indexOf('--check');
  if (checkIndex >= 0) {
    final wanted = checkIndex + 1 < args.length ? args[checkIndex + 1] : '';
    _check(wanted.replaceFirst(RegExp('^v'), ''));
    return;
  }

  final payload = {
    'schema': 1,
    'versions': [for (final release in changelog) release.toJson()],
  };
  final json = '${const JsonEncoder.withIndent('  ').convert(payload)}\n';

  if (args.isEmpty) {
    stdout.write(json);
    return;
  }
  File(args.first).writeAsStringSync(json);
  stderr.writeln('wrote ${args.first}');
}

/// Today, as the changelog writes dates.
String _today() {
  final now = DateTime.now();
  final month = now.month.toString().padLeft(2, '0');
  final day = now.day.toString().padLeft(2, '0');
  return '${now.year}-$month-$day';
}

void _check(String version) {
  if (version.isEmpty) {
    stderr.writeln('usage: --check <version>');
    exit(2);
  }

  final entry =
      changelog.where((release) => release.version == version).firstOrNull;
  if (entry == null) {
    stderr.writeln(
      'No changelog entry for $version. Add one to '
      'lib/core/changelog/changelog.dart before tagging.',
    );
    exit(1);
  }
  if (!entry.isReleased) {
    // The exact edit, because the person reading this is looking at a failed
    // release and wants the fix, not a description of the rule.
    stderr.writeln('''
The changelog entry for $version has no date, so it still counts as unreleased.

In lib/core/changelog/changelog.dart, add a date to the
ReleaseNotes(version: '$version', ...) entry:

    date: '${_today()}',

Then commit, and move the tag onto that commit:

    git commit -am "chore: date the $version changelog entry"
    git tag -f v$version
    git push origin main && git push -f origin v$version
''');
    exit(1);
  }
  if (entry.changes.isEmpty) {
    stderr.writeln('The changelog entry for $version lists no changes.');
    exit(1);
  }
  stdout.writeln('changelog ok: $version, ${entry.changes.length} changes');
}
