// Prints one version's changelog entry as markdown, for a GitHub release body.
//
//   dart run tool/changelog_notes.dart 1.2.0
//
// The release announcement, the website and the app's own dialog all come from
// lib/core/changelog/changelog.dart this way, so they cannot disagree.
import 'dart:io';

import 'package:marmelade/core/changelog/changelog.dart';

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    stderr.writeln('usage: changelog_notes.dart <version>');
    exit(2);
  }

  final version = arguments.first.replaceFirst(RegExp('^v'), '');
  final entry =
      changelog.where((release) => release.version == version).firstOrNull;
  if (entry == null) {
    stderr.writeln('no changelog entry for $version');
    exit(1);
  }

  final out = StringBuffer();
  if (entry.headline != null) out.writeln('${entry.headline}\n');
  for (final kind in ChangeKind.values) {
    final changes = entry.ofKind(kind).toList();
    if (changes.isEmpty) continue;
    out.writeln('### ${kind.label}\n');
    for (final change in changes) {
      out.writeln('- ${change.text}');
    }
    out.writeln();
  }
  stdout.write(out);
}
