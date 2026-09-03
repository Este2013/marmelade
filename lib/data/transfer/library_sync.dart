import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../core/logging/app_log.dart';
import '../repositories/settings_repository.dart';
import 'library_exporter.dart';
import 'library_importer.dart';
import 'transfer_bundle.dart';
import 'transfer_report.dart';

/// Sharing a library between computers through one folder.
///
/// There is no server and no account. The folder is whatever the user picks,
/// and the intended answer to "can it use Google Drive?" is: put the folder
/// inside Drive, Dropbox or OneDrive and their own client does the moving.
/// That is not a workaround -- it is strictly better than an integration
/// here would be. It works with whichever service someone already pays for,
/// it keeps their music out of an API this app would have to hold
/// credentials for, and it fails in ways they can see and fix in a file
/// manager.
///
/// The layout is the important part:
///
/// ```
/// <folder>/machines/<machineId>/library.json
/// <folder>/machines/<machineId>/artwork/...
/// <folder>/machines/<machineId>/audio/...      (opt-in)
/// ```
///
/// **A machine only ever writes its own subfolder, and only ever reads the
/// others.** That is what makes this safe on top of a cloud client that
/// syncs whenever it likes: two computers never write the same file, so
/// there is no conflict to resolve, no "library.json (2)", and no lock. Two
/// machines exporting at the same moment is a non-event.
///
/// Convergence comes from importing being additive and idempotent rather
/// than from any ordering guarantee: each machine folds in what the others
/// know, and the result is the union no matter who ran when. See
/// [LibraryImporter] for what that costs -- deletions do not propagate.
class LibrarySync {
  LibrarySync({
    required this.exporter,
    required this.importer,
    required this.settings,
  });

  final LibraryExporter exporter;
  final LibraryImporter importer;
  final SettingsRepository settings;

  static const _machinesDirName = 'machines';

  /// Resolves this installation's identity, creating it on first use.
  ///
  /// The id is random rather than derived from the hardware or the hostname:
  /// a hostname changes and a hardware fingerprint is not something a music
  /// player has any business building.
  Future<TransferOrigin> identity({String? appVersion}) async {
    var id = await settings.get(SettingKeys.machineId, '');
    if (id.isEmpty) {
      id = _newMachineId();
      await settings.set(SettingKeys.machineId, id);
    }

    var name = await settings.get(SettingKeys.machineName, '');
    if (name.isEmpty) {
      name = _hostname();
      await settings.set(SettingKeys.machineName, name);
    }

    return TransferOrigin(machineId: id, machineName: name, appVersion: appVersion);
  }

  /// Renames this computer, for the UI's benefit only.
  Future<void> rename(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await settings.set(SettingKeys.machineName, trimmed);
  }

  /// Where this machine writes, inside [folder].
  Directory ownDirectory(Directory folder, TransferOrigin origin) => Directory(
        p.join(folder.path, _machinesDirName, origin.machineId),
      );

  /// The other computers sharing this folder, newest export first.
  ///
  /// Reads only the header of each bundle -- enough for the UI to say what is
  /// there and when it was written -- so listing a folder does not mean
  /// parsing every library in it.
  Future<List<SyncPeer>> peers(
    Directory folder, {
    required TransferOrigin origin,
  }) async {
    final machines = Directory(p.join(folder.path, _machinesDirName));
    if (!await machines.exists()) return const [];

    final peers = <SyncPeer>[];
    await for (final entry in machines.list()) {
      if (entry is! Directory) continue;
      final file = File(p.join(entry.path, transferBundleFileName));
      if (!await file.exists()) continue;

      try {
        final bundle = TransferBundle.decode(await file.readAsString());
        final lastImported = await settings.get(
          SettingKeys.lastImportOf(bundle.origin.machineId),
          '',
        );
        peers.add(SyncPeer(
          origin: bundle.origin,
          directory: entry,
          exportedAt: bundle.exportedAt,
          counts: bundle.counts,
          isSelf: bundle.origin.machineId == origin.machineId,
          lastImportedAt:
              lastImported.isEmpty ? null : DateTime.tryParse(lastImported),
          hasAudio:
              await Directory(p.join(entry.path, transferAudioDirName)).exists(),
        ));
      } on TransferFormatException catch (error) {
        // A folder someone dropped something else into, or a half-written
        // file a cloud client has not finished syncing. Neither is worth
        // failing the whole listing over.
        AppLog.instance.warn(
          'skipped an unreadable bundle in the shared folder',
          tag: 'transfer',
          fields: {'path': file.path, 'error': error.message},
        );
      } catch (error) {
        AppLog.instance.warn(
          'could not read a bundle in the shared folder',
          tag: 'transfer',
          fields: {'path': file.path, 'error': '$error'},
        );
      }
    }

    peers.sort((a, b) => b.exportedAt.compareTo(a.exportedAt));
    return peers;
  }

  /// Publishes this library, then folds in every other machine's.
  ///
  /// Export first, deliberately: if the import half fails -- a half-synced
  /// file, a disconnected drive -- this machine's own contribution is already
  /// safely published rather than waiting for the next attempt.
  Future<SyncOutcome> syncNow({
    required Directory folder,
    required TransferOrigin origin,
    TransferExportOptions export = const TransferExportOptions(),
    TransferImportOptions import = const TransferImportOptions(),
    bool force = false,
    void Function(TransferProgress)? onProgress,
  }) async {
    final started = DateTime.now();

    final own = ownDirectory(folder, origin);
    final published = await exporter.exportTo(
      own,
      origin: origin,
      options: export,
      onProgress: onProgress,
    );

    final reports = <TransferReport>[];
    final skipped = <SyncPeer>[];

    for (final peer in await peers(folder, origin: origin)) {
      if (peer.isSelf) continue;

      // Nothing new since the last run. Importing again would be harmless --
      // that is the point of it being idempotent -- but reading and merging a
      // whole library to change nothing is not free, and a sync folder can be
      // checked often.
      if (!force && peer.lastImportedAt != null &&
          !peer.exportedAt.isAfter(peer.lastImportedAt!)) {
        skipped.add(peer);
        continue;
      }

      onProgress?.call(TransferProgress(
        phase: TransferPhase.readingBundle,
        detail: peer.origin.machineName,
      ));

      try {
        final file = File(p.join(peer.directory.path, transferBundleFileName));
        final bundle = TransferBundle.decode(await file.readAsString());
        final report = await importer.import(
          bundle,
          bundleDirectory: peer.directory,
          options: import,
          onProgress: onProgress,
        );
        reports.add(report);
        await settings.set(
          SettingKeys.lastImportOf(peer.origin.machineId),
          peer.exportedAt.toUtc().toIso8601String(),
        );
      } catch (error, stack) {
        AppLog.instance.error(
          'could not fold in another machine',
          tag: 'transfer',
          error: error,
          stack: stack,
          fields: {'machine': peer.origin.machineName},
        );
        final failed = TransferReport(
          origin: peer.origin.machineName,
          exportedAt: peer.exportedAt,
        );
        failed.problems.add(
          'Could not read the bundle from ${peer.origin.machineName}: $error',
        );
        reports.add(failed);
      }
    }

    await settings.set(
      SettingKeys.lastSyncAt,
      DateTime.now().toUtc().toIso8601String(),
    );

    AppLog.instance.info('sync finished', tag: 'transfer', fields: {
      'folder': folder.path,
      'published': published.tracks,
      'machinesRead': reports.length,
      'machinesSkipped': skipped.length,
      'ms': DateTime.now().difference(started).inMilliseconds,
    });

    return SyncOutcome(
      published: published,
      imported: reports,
      upToDate: skipped,
    );
  }

  /// A stable, meaningless id. Sixteen hex characters is plenty to keep two
  /// computers apart, and it never has to be typed by a person.
  static String _newMachineId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 8; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// The hostname, or something honest if the platform will not say.
  static String _hostname() {
    try {
      final name = Platform.localHostname.trim();
      if (name.isNotEmpty) return name;
    } catch (_) {
      // Some sandboxes refuse. A name is a label, not a requirement.
    }
    return 'This computer';
  }
}

/// Another computer's bundle sitting in the shared folder.
class SyncPeer {
  const SyncPeer({
    required this.origin,
    required this.directory,
    required this.exportedAt,
    required this.counts,
    required this.isSelf,
    required this.hasAudio,
    this.lastImportedAt,
  });

  final TransferOrigin origin;
  final Directory directory;
  final DateTime exportedAt;

  /// What the bundle says it holds, for a line of description without
  /// parsing the whole thing.
  final Map<String, Object?> counts;

  /// True for this machine's own folder, which is written but never read.
  final bool isSelf;

  /// Whether the audio files came too.
  final bool hasAudio;

  /// When this machine last folded that bundle in.
  final DateTime? lastImportedAt;

  /// Nothing new to read.
  bool get isUpToDate =>
      lastImportedAt != null && !exportedAt.isAfter(lastImportedAt!);
}

/// What one round of sharing did.
class SyncOutcome {
  const SyncOutcome({
    required this.published,
    required this.imported,
    required this.upToDate,
  });

  /// This machine's own export.
  final TransferExportReport published;

  /// One report per machine that was read.
  final List<TransferReport> imported;

  /// Machines that had nothing new since last time.
  final List<SyncPeer> upToDate;

  int get changeCount =>
      imported.fold(0, (sum, report) => sum + report.changeCount);

  List<TransferMissingTrack> get missingTracks => [
        for (final report in imported) ...report.missingTracks,
      ];

  List<String> get problems => [
        for (final report in imported) ...report.problems,
      ];

  /// A sentence for the settings page.
  String summarize() {
    if (imported.isEmpty) {
      return upToDate.isEmpty
          ? 'Shared this library. No other computers here yet.'
          : 'Shared this library. Every other computer was already up to date.';
    }
    final changed = changeCount;
    final names = imported.map((r) => r.origin).join(', ');
    if (changed == 0) {
      return 'Shared this library. Nothing new from $names.';
    }
    final missing = missingTracks.length;
    final tail = missing == 0
        ? ''
        : ' $missing tracks are not on this computer yet -- copy the files '
            'across and share again.';
    return 'Shared this library and brought $changed changes from $names.$tail';
  }
}
