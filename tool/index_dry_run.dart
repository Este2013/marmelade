// Dry-run indexer. Reads a folder of music, resolves every artist credit, and
// reports what the real indexer would do - without touching a database.
//
//   dart run tool/index_dry_run.dart "C:\path\to\music" [--verbose]
//
// This is the fastest way to see how the credit resolver behaves on a real
// collection, and to spot tagging patterns the separator list does not cover
// yet.
import 'dart:io';

import 'package:marmelade/data/db/enums.dart';
import 'package:marmelade/data/metadata/tag_reader.dart';
import 'package:marmelade/data/metadata/track_metadata.dart';
import 'package:marmelade/domain/credits/credit_resolver.dart';
import 'package:marmelade/domain/credits/credit_tokenizer.dart';
import 'package:marmelade/domain/text/normalize.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) {
  final verbose = args.contains('--verbose');
  final roots = args.where((a) => !a.startsWith('--')).toList();
  if (roots.isEmpty) {
    stderr.writeln('usage: dart run tool/index_dry_run.dart <folder> '
        '[--verbose]');
    exitCode = 64;
    return;
  }

  final reader = const TagReader();
  final tokenizer = CreditTokenizer.withDefaults();

  // ---- Walk ----
  final audioFiles = <File>[];
  final skippedByExtension = <String, int>{};
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) {
      stderr.writeln('no such folder: $root');
      exitCode = 66;
      return;
    }
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
      if (supportedAudioExtensions.contains(ext)) {
        audioFiles.add(entity);
      } else {
        skippedByExtension[ext.isEmpty ? '(none)' : ext] =
            (skippedByExtension[ext.isEmpty ? '(none)' : ext] ?? 0) + 1;
      }
    }
  }
  audioFiles.sort((a, b) => a.path.compareTo(b.path));

  // ---- Read tags ----
  final parsed = <File, TrackFileMetadata>{};
  final failures = <File, String>{};
  final untagged = <File>[];
  for (final file in audioFiles) {
    try {
      final md = reader.read(file);
      parsed[file] = md;
      if (md.isEffectivelyUntagged) untagged.add(file);
    } catch (e) {
      failures[file] = e.toString().split('\n').first;
    }
  }

  // ---- Phase one: gather corpus evidence ----
  // Every main-artist credit string is observed before anything is resolved,
  // which is what lets the resolver reason about the collection as a whole.
  final evidence = MapCreditEvidence();
  final rawMainCredits = <String, int>{};
  for (final md in parsed.values) {
    for (final credit in md.mainCredits) {
      if (credit.isPreSplit) continue; // already authoritative
      evidence.observe(credit.value, tokenizer);
      rawMainCredits[credit.value] = (rawMainCredits[credit.value] ?? 0) + 1;
    }
  }

  // ---- Phase two: resolve ----
  final resolver = CreditResolver(tokenizer: tokenizer, evidence: evidence);
  final byOutcome = <ResolutionOutcome, List<CreditResolution>>{};
  final discoveredArtists = <String, int>{};

  for (final entry in rawMainCredits.entries) {
    final resolution = resolver.resolve(entry.key);
    (byOutcome[resolution.outcome] ??= []).add(resolution);
    if (resolution.isActionable) {
      for (final credit in resolution.credits) {
        discoveredArtists[credit.creditedAs] =
            (discoveredArtists[credit.creditedAs] ?? 0) + entry.value;
      }
    }
  }

  // Pre-split credits become artists directly, with no guessing involved.
  var preSplitCredits = 0;
  for (final md in parsed.values) {
    for (final credit in md.mainCredits.where((c) => c.isPreSplit)) {
      preSplitCredits++;
      discoveredArtists[credit.value] =
          (discoveredArtists[credit.value] ?? 0) + 1;
    }
  }

  // ---- Report ----
  final out = StringBuffer();
  void h(String title) => out.writeln('\n=== $title '
      '${'=' * (68 - title.length).clamp(0, 68)}');

  h('FILES');
  out.writeln('audio files found : ${audioFiles.length}');
  final byExt = <String, int>{};
  for (final f in audioFiles) {
    final e = p.extension(f.path).toLowerCase().replaceFirst('.', '');
    byExt[e] = (byExt[e] ?? 0) + 1;
  }
  out.writeln('by extension      : ${_fmtCounts(byExt)}');
  out.writeln('parsed ok         : ${parsed.length}');
  out.writeln('parse failures    : ${failures.length}');
  out.writeln('effectively untagged : ${untagged.length}');
  final ignorable = Map.of(skippedByExtension)
    ..removeWhere((k, v) => v < 2 && k != 'flac' && k != 'wav');
  out.writeln('non-audio skipped : ${_fmtCounts(ignorable, limit: 10)}');

  if (failures.isNotEmpty) {
    h('PARSE FAILURES');
    for (final entry in failures.entries.take(15)) {
      out.writeln('  ${p.basename(entry.key.path)}: ${entry.value}');
    }
  }

  h('CREDIT RESOLUTION');
  out.writeln('distinct main-artist strings : ${rawMainCredits.length}');
  out.writeln('pre-split credits (trusted)  : $preSplitCredits');
  for (final outcome in ResolutionOutcome.values) {
    final list = byOutcome[outcome];
    if (list == null || list.isEmpty) continue;
    out.writeln('${outcome.name.padRight(13)}: ${list.length}');
  }
  out.writeln('distinct artists after resolution : '
      '${discoveredArtists.length}');

  // The two interesting buckets: what got split, and what the app wants to
  // ask about.
  for (final outcome in const [
    ResolutionOutcome.split,
    ResolutionOutcome.aliasPair,
    ResolutionOutcome.needsReview,
    ResolutionOutcome.keptWhole,
    ResolutionOutcome.compilation,
  ]) {
    final list = byOutcome[outcome];
    if (list == null || list.isEmpty) continue;
    h(outcome.name.toUpperCase());
    final show = verbose ? list.length : 25;
    for (final r in list.take(show)) {
      if (outcome == ResolutionOutcome.aliasPair) {
        final c = r.credits.single;
        out.writeln('  "${r.raw}"');
        out.writeln('      -> ${c.creditedAs}  (alias: ${c.aliases.join(", ")})');
        out.writeln('      ${r.confidence.toStringAsFixed(2)}  ${r.reason}');
      } else if (outcome == ResolutionOutcome.split) {
        out.writeln('  "${r.raw}"');
        out.writeln('      -> ${r.credits.map((c) => "${c.creditedAs}"
            "${c.role == SegmentRole.main ? "" : " (${c.role.name})"}").join(' + ')}');
        out.writeln('      ${r.confidence.toStringAsFixed(2)}  ${r.reason}');
      } else {
        out.writeln('  "${r.raw}"');
        if (r.alternative.isNotEmpty) {
          out.writeln('      would split as: '
              '${r.alternative.map((c) => c.creditedAs).join(' + ')}');
        }
        out.writeln('      ${r.confidence.toStringAsFixed(2)}  ${r.reason}');
      }
    }
    if (list.length > show) {
      out.writeln('  ... and ${list.length - show} more '
          '(pass --verbose to see all)');
    }
  }

  h('TOP ARTISTS');
  final top = discoveredArtists.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final entry in top.take(20)) {
    out.writeln('  ${entry.value.toString().padLeft(4)}  ${entry.key}');
  }

  h('CJK NAMES NEEDING A ROMANISED ALIAS');
  final cjk = discoveredArtists.keys.where(containsCjk).toList()..sort();
  out.writeln('  ${cjk.length} of ${discoveredArtists.length} artists');
  for (final name in cjk.take(15)) {
    out.writeln('  $name   (key: ${normalizeKey(name)})');
  }

  h('TAG COVERAGE');
  int count(bool Function(TrackFileMetadata) test) =>
      parsed.values.where(test).length;
  final total = parsed.length;
  void row(String label, int n) => out.writeln(
      '  ${label.padRight(22)} ${n.toString().padLeft(5)} / $total');
  row('has title', count((m) => m.title != null));
  row('has album', count((m) => m.albumTitle != null));
  row('has album artist', count((m) => m.albumArtistRaw != null));
  row('has genre', count((m) => m.genres.isNotEmpty));
  row('has language', count((m) => m.languages.isNotEmpty));
  row('has track number', count((m) => m.trackNo != null));
  row('has year', count((m) => m.year != null));
  row('has embedded lyrics', count((m) => m.lyrics != null));
  row('has rating', count((m) => m.rating != null));
  row('has replay gain', count((m) => m.replayGainDb != null));
  row('has composer credit',
      count((m) => m.credits.any((c) => c.role == CreditRole.composer)));

  final tagFormats = <String, int>{};
  for (final md in parsed.values) {
    final f = md.tagFormat ?? '(unknown)';
    tagFormats[f] = (tagFormats[f] ?? 0) + 1;
  }
  out.writeln('  tag containers: ${_fmtCounts(tagFormats)}');

  stdout.write(out.toString());
  stdout.writeln();
}

String _fmtCounts(Map<String, int> counts, {int limit = 20}) {
  final entries = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final shown = entries.take(limit).map((e) => '${e.key}=${e.value}');
  final suffix = entries.length > limit ? ', ...' : '';
  return '${shown.join(', ')}$suffix';
}
