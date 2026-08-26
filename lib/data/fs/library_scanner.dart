import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../metadata/tag_reader.dart';

/// One audio file found on disk during a scan.
class ScannedFile {
  ScannedFile({
    required this.file,
    required this.relativePath,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final File file;

  /// Path relative to the scanned root, always with forward slashes.
  ///
  /// Stored relative so that re-rooting a library - a drive letter change, a
  /// whole collection moved - is one update to the folder row rather than a
  /// rewrite of every file.
  final String relativePath;

  final int sizeBytes;
  final DateTime modifiedAt;

  String get fileName => p.basename(file.path);

  /// Lower-case extension without the dot.
  String get extension =>
      p.extension(file.path).toLowerCase().replaceFirst('.', '');

  @override
  String toString() => 'ScannedFile($relativePath, $sizeBytes bytes)';
}

/// What a scan found, including the things it chose not to index.
class ScanResult {
  ScanResult({
    required this.root,
    required this.files,
    required this.skippedExtensions,
    required this.unreadable,
    required this.playableButUnsupported,
    required this.elapsed,
  });

  final String root;
  final List<ScannedFile> files;

  /// Counts of extensions that were ignored, so the UI can say what it skipped
  /// rather than silently dropping it.
  final Map<String, int> skippedExtensions;

  /// Paths that could not be stat-ed or read, with the reason.
  final Map<String, String> unreadable;

  /// Audio files in formats the reader understands but the app does not index
  /// yet, so "you have 300 m4a files here" is answerable.
  final Map<String, int> playableButUnsupported;

  final Duration elapsed;

  @override
  String toString() => 'ScanResult(${files.length} files in $root, '
      '${elapsed.inMilliseconds}ms)';
}

/// Walks a folder looking for indexable audio files.
///
/// Deliberately does no database work and no tag parsing, so it can be tested
/// against a plain directory tree.
class LibraryScanner {
  LibraryScanner({
    this.excludeGlobs = const [],
    this.followLinks = false,
    Set<String>? extensions,
  }) : extensions = extensions ?? supportedAudioExtensions;

  /// Glob patterns, relative to the scan root, whose matches are skipped.
  final List<String> excludeGlobs;

  /// Whether to traverse symlinks and junctions.
  ///
  /// Off by default: a junction pointing at a parent directory turns a scan
  /// into an infinite walk.
  final bool followLinks;

  final Set<String> extensions;

  /// Directory names never worth walking into.
  ///
  /// `_files` catches the sidecar folders browsers create when saving a web
  /// page, which show up in real music folders more often than one would like.
  static const skippedDirectoryNames = <String>{
    r'$recycle.bin',
    'system volume information',
    '.git',
    '.svn',
    '__macosx',
    '.trash',
    '.trash-1000',
  };

  static const skippedDirectorySuffixes = <String>{'_files'};

  /// Scans [rootPath], recursing unless [recursive] is false.
  ScanResult scan(String rootPath, {bool recursive = true}) {
    final started = DateTime.now();
    final root = p.normalize(rootPath);
    final globs = [
      for (final pattern in excludeGlobs)
        Glob(pattern, caseSensitive: false, recursive: true),
    ];

    final files = <ScannedFile>[];
    final skipped = <String, int>{};
    final unsupported = <String, int>{};
    final unreadable = <String, String>{};

    void bump(Map<String, int> into, String key) =>
        into[key] = (into[key] ?? 0) + 1;

    // Explicit stack rather than Directory.list(recursive: true), so whole
    // subtrees can be pruned before they are walked.
    final pending = <Directory>[Directory(root)];
    while (pending.isNotEmpty) {
      final dir = pending.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: followLinks);
      } on FileSystemException catch (e) {
        unreadable[dir.path] = e.osError?.message ?? e.message;
        continue;
      }

      for (final entity in entries) {
        final relative = _relative(root, entity.path);

        if (entity is Directory) {
          if (!recursive) continue;
          if (_isSkippedDirectory(p.basename(entity.path))) continue;
          if (_matchesAny(globs, relative)) continue;
          pending.add(entity);
          continue;
        }
        if (entity is! File) continue;

        final extension =
            p.extension(entity.path).toLowerCase().replaceFirst('.', '');

        if (!extensions.contains(extension)) {
          if (parseableButUnindexedExtensions.contains(extension)) {
            bump(unsupported, extension);
          } else {
            bump(skipped, extension.isEmpty ? '(none)' : extension);
          }
          continue;
        }
        if (_matchesAny(globs, relative)) {
          bump(skipped, 'excluded');
          continue;
        }

        try {
          final stat = entity.statSync();
          // A zero-length file is a failed download, not music.
          if (stat.size == 0) {
            unreadable[entity.path] = 'file is empty';
            continue;
          }
          files.add(ScannedFile(
            file: entity,
            relativePath: relative,
            sizeBytes: stat.size,
            modifiedAt: stat.modified.toUtc(),
          ));
        } on FileSystemException catch (e) {
          unreadable[entity.path] = e.osError?.message ?? e.message;
        }
      }
    }

    files.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    return ScanResult(
      root: root,
      files: files,
      skippedExtensions: skipped,
      unreadable: unreadable,
      playableButUnsupported: unsupported,
      elapsed: DateTime.now().difference(started),
    );
  }

  static bool _isSkippedDirectory(String name) {
    final lowered = name.toLowerCase();
    if (skippedDirectoryNames.contains(lowered)) return true;
    for (final suffix in skippedDirectorySuffixes) {
      if (lowered.endsWith(suffix)) return true;
    }
    return false;
  }

  static bool _matchesAny(List<Glob> globs, String relativePath) {
    for (final glob in globs) {
      if (glob.matches(relativePath)) return true;
    }
    return false;
  }

  /// Relative path with forward slashes, so stored paths are stable regardless
  /// of which platform wrote them.
  static String _relative(String root, String path) =>
      p.relative(path, from: root).replaceAll(r'\', '/');
}
