// Standalone toolchain diagnostics for marmelade.
//
//   flutter run -d windows -t tool/diagnostics.dart
//
// Verifies the native pieces the app depends on, independent of app code:
//   * sqlite3 (native assets) with FTS5 + WAL
//   * SoLoud engine: device enumeration, mp3/FLAC/WAV decode, seek,
//     FFT/waveform taps, parametric EQ and the DSP chain
//   * audio_metadata_reader raw-frame parsing
//
// Set MARMELADE_DIAG_EXIT=1 to make it print a report and exit with a
// non-zero code on failure (used by CI).
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Folder scanned for decode/tag coverage. Override with MARMELADE_DIAG_DIR.
String get _fixtureDir =>
    Platform.environment['MARMELADE_DIAG_DIR'] ??
    r'C:\Users\makrofon\Music\testZiks\_marmelade_fixtures';

final _log = <String>[];
void _ok(String what, [String detail = '']) =>
    _log.add('[ OK ] $what${detail.isEmpty ? '' : ' -> $detail'}');
void _fail(String what, Object e) => _log.add('[FAIL] $what -> $e');

Future<void> _checkSqlite() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'diagnostics.db'));
    if (file.existsSync()) file.deleteSync();
    final db = sqlite3.open(file.path);
    final journal = db.select('PRAGMA journal_mode=WAL').first.values.first;
    db.execute(
        "CREATE VIRTUAL TABLE fts USING fts5(name, tokenize='unicode61')");
    db.execute("INSERT INTO fts (name) VALUES ('PinocchioP ピノキオピー')");
    final hits = db.select("SELECT name FROM fts WHERE fts MATCH 'Pinocchio*'");
    final version = db.select('SELECT sqlite_version() AS v').first['v'];
    db.close();
    file.deleteSync();
    _ok('sqlite3', 'v$version journal=$journal fts5Hits=${hits.length}');
  } catch (e) {
    _fail('sqlite3', e);
  }
}

Future<void> _checkFormats(SoLoud soloud) async {
  final dir = Directory(_fixtureDir);
  if (!dir.existsSync()) {
    _fail('formats', 'fixture dir missing: $_fixtureDir');
    return;
  }
  const exts = {'.mp3', '.flac', '.wav'};
  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => exts.contains(p.extension(f.path).toLowerCase()))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  var decoded = 0, tagged = 0;
  for (final f in files) {
    try {
      final src = await soloud.loadFile(f.path);
      soloud.getLength(src);
      await soloud.disposeSource(src);
      decoded++;
    } catch (e) {
      _fail('decode ${p.basename(f.path)}', e);
    }
    try {
      readAllMetadata(f, getImage: false);
      tagged++;
    } catch (e) {
      _fail('tags ${p.basename(f.path)}', e);
    }
  }
  _ok('formats', '${files.length} files: $decoded decoded, $tagged parsed');
}

Future<void> _checkAudio() async {
  final soloud = SoLoud.instance;
  try {
    await soloud.init(bufferSize: 1024);
    _ok('soloud.init', 'bufferSize=1024');
  } catch (e) {
    _fail('soloud.init', e);
    return;
  }

  try {
    final devices = soloud.listPlaybackDevices();
    _ok('soloud devices', '${devices.length} found, default='
        '"${devices.firstWhere((d) => d.isDefault, orElse: () => devices.first).name}"');
  } catch (e) {
    _fail('soloud devices', e);
  }

  await _checkFormats(soloud);

  // Visualization tap. NOTE: the tap reads post-mix output, so it needs real
  // signal - seek past any silent intro or this reads all zeros.
  AudioData? data;
  try {
    soloud.setVisualizationEnabled(true);
    soloud.setFftSmoothing(0.0);
    final files = Directory(_fixtureDir)
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path).toLowerCase() == '.mp3')
        .toList();
    if (files.isEmpty) throw StateError('no mp3 fixture for viz test');
    final src = await soloud.loadFile(files.first.path);
    final h = soloud.play(src, volume: 0.08);
    soloud.seek(h, const Duration(seconds: 2));
    data = AudioData(GetSamplesKind.linear);
    var maxFft = 0.0, maxWave = 0.0;
    for (var i = 0; i < 25; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      data.updateSamples();
      final v = data.getAudioData();
      if (v.length < 512) continue;
      for (var b = 0; b < 256; b++) {
        if (v[b].abs() > maxFft) maxFft = v[b].abs();
      }
      for (var w = 256; w < 512; w++) {
        if (v[w].abs() > maxWave) maxWave = v[w].abs();
      }
    }
    await soloud.stop(h);
    await soloud.disposeSource(src);
    if (maxFft <= 0 && maxWave <= 0) {
      _fail('soloud visualization', 'taps returned silence');
    } else {
      _ok('soloud visualization',
          'maxFft=${maxFft.toStringAsFixed(4)} maxWave=${maxWave.toStringAsFixed(4)}');
    }
  } catch (e) {
    _fail('soloud visualization', e);
  } finally {
    data?.dispose();
  }

  try {
    final eq = soloud.filters.parametricEqFilter;
    eq.activate();
    eq.numBands.value = 10;
    final freqs = [for (var i = 0; i < 10; i++) eq.bandFrequency(i).round()];
    eq.deactivate();
    _ok('soloud parametric eq', '10 bands ${freqs.first}..${freqs.last} Hz');
  } catch (e) {
    _fail('soloud parametric eq', e);
  }

  try {
    for (final f in [
      soloud.filters.limiterFilter,
      soloud.filters.compressorFilter,
      soloud.filters.freeverbFilter,
      soloud.filters.pitchShiftFilter,
      soloud.filters.echoFilter,
    ]) {
      f.activate();
      f.deactivate();
    }
    _ok('soloud dsp chain', 'limiter/compressor/reverb/pitch/echo');
  } catch (e) {
    _fail('soloud dsp chain', e);
  }

  soloud.deinit();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _checkSqlite();
  await _checkAudio();

  final failed = _log.any((l) => l.startsWith('[FAIL]'));
  final report = _log.join('\n');
  stdout.writeln('\n===== MARMELADE DIAGNOSTICS =====\n$report\n'
      '===== ${failed ? "FAILURES PRESENT" : "ALL OK"} =====');
  File(p.join(Directory.systemTemp.path, 'marmelade_diagnostics.txt'))
      .writeAsStringSync(report);

  if (Platform.environment['MARMELADE_DIAG_EXIT'] == '1') {
    exit(failed ? 1 : 0);
  }

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(title: const Text('marmelade diagnostics')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: SelectableText(
            report,
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
          ),
        ),
      ),
    ),
  ));
}
