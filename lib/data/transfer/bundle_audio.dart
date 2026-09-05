import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/logging/app_log.dart';
import 'transfer_bundle.dart';
import 'transfer_report.dart';

/// What a bundle's music files weigh, and how to put them into a library.
///
/// The metadata half of a transfer only ever *matches* what this machine
/// already has: a track whose file is not here is reported missing rather
/// than invented, because a track row with nothing behind it shows up in
/// every list and plays silence. That left the person to copy gigabytes by
/// hand between the export and the import, which is the one part of the job a
/// program should be doing.
///
/// So when a bundle carries its audio, this puts it where the library can see
/// it. The exporter writes each file under the path it had inside its own
/// library folder, so laying them down under a folder here reproduces that
/// tree exactly -- Artist/Album/Track stays Artist/Album/Track.
///
/// Nothing is ever overwritten. A file already sitting at the destination is
/// left alone: the same size means it is already here, and a different size
/// means this machine has its own copy, and neither is ours to replace.
class BundleAudio {
  const BundleAudio._();

  /// Where a bundle keeps its music, if it carries any.
  static Directory folderIn(Directory bundle) =>
      Directory(p.join(bundle.path, transferAudioDirName));

  /// What the bundle is carrying, without copying a byte.
  ///
  /// Answered before the import runs so the dialog can say what is about to
  /// happen and roughly how long it will take, rather than going quiet for
  /// twenty minutes.
  static Future<BundleAudioSize> inspect(Directory bundle) async {
    final dir = folderIn(bundle);
    if (!await dir.exists()) return const BundleAudioSize(files: 0, bytes: 0);

    var files = 0;
    var bytes = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      files += 1;
      try {
        bytes += await entity.length();
      } on FileSystemException {
        // A file that cannot be measured still counts as one to copy.
      }
    }
    return BundleAudioSize(files: files, bytes: bytes);
  }

  /// Copies the bundle's music into [destination], keeping its tree.
  static Future<BundleAudioInstalled> installInto(
    Directory bundle,
    Directory destination, {
    void Function(TransferProgress)? onProgress,
  }) async {
    final dir = folderIn(bundle);
    if (!await dir.exists()) {
      return const BundleAudioInstalled(copied: 0, alreadyHere: 0, bytes: 0);
    }
    await destination.create(recursive: true);

    final sources = <File>[
      await for (final entity in dir.list(recursive: true, followLinks: false))
        if (entity is File) entity,
    ];

    var copied = 0;
    var alreadyHere = 0;
    var bytes = 0;
    final problems = <String>[];

    for (var i = 0; i < sources.length; i++) {
      final source = sources[i];
      final relative = p.relative(source.path, from: dir.path);

      onProgress?.call(TransferProgress(
        phase: TransferPhase.copyingAudio,
        completed: i + 1,
        total: sources.length,
        detail: p.basename(relative),
      ));

      try {
        final target = File(p.join(destination.path, relative));
        if (await target.exists()) {
          alreadyHere += 1;
          continue;
        }
        await target.parent.create(recursive: true);
        await source.copy(target.path);
        copied += 1;
        bytes += await target.length();
      } catch (error) {
        // One unreadable file is not a reason to abandon the rest: the folder
        // gets scanned afterwards either way, and what did arrive still
        // works.
        problems.add('${p.basename(relative)}: $error');
        AppLog.instance.warn(
          'could not copy a music file out of a bundle',
          tag: 'transfer',
          fields: {'file': relative, 'error': '$error'},
        );
      }
    }

    AppLog.instance.info('music files brought in from a bundle', tag: 'transfer', fields: {
      'copied': copied,
      'alreadyHere': alreadyHere,
      'bytes': AppLog.formatBytes(bytes),
      'into': destination.path,
    });
    return BundleAudioInstalled(
      copied: copied,
      alreadyHere: alreadyHere,
      bytes: bytes,
      problems: problems,
    );
  }
}

/// How much music a bundle is carrying.
class BundleAudioSize {
  const BundleAudioSize({required this.files, required this.bytes});

  final int files;
  final int bytes;

  bool get isEmpty => files == 0;
}

/// What installing it did.
class BundleAudioInstalled {
  const BundleAudioInstalled({
    required this.copied,
    required this.alreadyHere,
    required this.bytes,
    this.problems = const [],
  });

  final int copied;

  /// Files the destination already had, left untouched.
  final int alreadyHere;

  final int bytes;
  final List<String> problems;
}
