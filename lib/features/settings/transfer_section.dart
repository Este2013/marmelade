import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../data/transfer/library_sync.dart';
import '../../data/transfer/transfer_bundle.dart';
import '../../data/transfer/transfer_report.dart';
import '../../widgets/time_text.dart';

/// Settings for using marmelade on more than one computer.
///
/// The problem it solves, in the user's words: music gets downloaded and
/// tagged at work, the files are copied home, and none of the tagging comes
/// with them. So this offers three shapes of the same thing --
///
///   * **Export** a bundle to a folder, to carry on a stick or attach to an
///     email.
///   * **Import** one someone handed you, previewed before anything is
///     written.
///   * **Share through a folder**, which is the one to use every day: point
///     both computers at the same folder and press one button on each. Put
///     that folder inside Drive, Dropbox or OneDrive and the cloud client
///     does the moving, which is why there is no account to sign into here.
///
/// Audio files are opt-in throughout. Metadata is a couple of megabytes; the
/// music is not, and a shared folder is often on a metered connection.
class TransferSection extends ConsumerWidget {
  const TransferSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folder = ref.watch(syncFolderProvider);
    final progress = ref.watch(transferProgressProvider);
    final identity = ref.watch(machineIdentityProvider).value;
    final peers = ref.watch(syncPeersProvider).value ?? const <SyncPeer>[];
    final busy = progress != null;

    return _Section(
      title: 'Another computer',
      subtitle: 'Carry tags, credits, ratings and playlists between the '
          'computers you use, so the same work is never done twice.',
      children: [
        ListTile(
          leading: const Icon(Icons.computer_outlined),
          title: const Text('This computer'),
          subtitle: Text(
            identity == null
                ? 'Working it out...'
                : 'Shared as "${identity.machineName}"',
          ),
          trailing: IconButton(
            tooltip: 'Rename this computer',
            onPressed: identity == null || busy
                ? null
                : () => _rename(context, ref, identity.machineName),
            icon: const Icon(Icons.edit_outlined),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.folder_shared_outlined),
          title: const Text('Shared folder'),
          subtitle: Text(
            folder.isEmpty
                ? 'Not sharing. Pick a folder both computers can see -- one '
                    'inside Google Drive, Dropbox or OneDrive works, and their '
                    'own app does the syncing.'
                : folder,
          ),
          trailing: folder.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Stop sharing through this folder',
                  onPressed: busy
                      ? null
                      : () => ref.read(syncFolderProvider.notifier).set(''),
                  icon: const Icon(Icons.link_off),
                ),
        ),
        if (folder.isNotEmpty) ...[
          for (final peer in peers.where((p) => !p.isSelf))
            _PeerTile(peer: peer),
          if (peers.where((p) => !p.isSelf).isEmpty)
            const ListTile(
              leading: Icon(Icons.hourglass_empty),
              title: Text('No other computers yet'),
              subtitle: Text(
                'Set the same folder up on the other computer and share from '
                'there once. It will appear here.',
              ),
            ),
          const _LastSharedTile(),
        ],
        if (progress != null) _TransferProgressTile(progress: progress),
        const Divider(height: 1),
        SwitchListTile(
          secondary: const Icon(Icons.image_outlined),
          title: const Text('Include artwork'),
          subtitle: const Text(
            'Carries pictures chosen by hand. A few megabytes for a large '
            'library.',
          ),
          value: ref.watch(syncArtworkProvider),
          onChanged: busy
              ? null
              : (value) => ref.read(syncArtworkProvider.notifier).set(value),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.audio_file_outlined),
          title: const Text('Include the music files'),
          subtitle: const Text(
            'Off by default: this makes a bundle as big as the music itself. '
            'Turn it on to move new songs as well as their tags -- then turn '
            'it off again if the folder is on a metered connection.',
          ),
          value: ref.watch(syncAudioProvider),
          onChanged: busy
              ? null
              : (value) => ref.read(syncAudioProvider.notifier).set(value),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (folder.isEmpty)
                FilledButton.icon(
                  onPressed: busy ? null : () => _pickFolder(context, ref),
                  icon: const Icon(Icons.folder_shared_outlined),
                  label: const Text('Share through a folder'),
                )
              else
                FilledButton.icon(
                  onPressed: busy ? null : () => _shareNow(context, ref),
                  icon: const Icon(Icons.sync),
                  label: const Text('Share now'),
                ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => _exportOnce(context, ref),
                icon: const Icon(Icons.drive_file_move_outline),
                label: const Text('Export to a folder'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => _importOnce(context, ref),
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('Import from a folder'),
              ),
              if (folder.isNotEmpty)
                TextButton.icon(
                  onPressed: busy ? null : () => _pickFolder(context, ref),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Change folder'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Name this computer'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            helperText: 'Only used to tell the computers apart.',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;

    await ref.read(librarySyncProvider).rename(name);
    ref.invalidate(machineIdentityProvider);
  }

  Future<void> _pickFolder(BuildContext context, WidgetRef ref) async {
    final path = await getDirectoryPath(
      confirmButtonText: 'Share through this folder',
    );
    if (path == null) return;
    await ref.read(syncFolderProvider.notifier).set(path);
    ref.invalidate(syncPeersProvider);
  }

  Future<void> _shareNow(BuildContext context, WidgetRef ref) async {
    try {
      final outcome = await ref.read(transferProgressProvider.notifier).shareNow();
      if (!context.mounted || outcome == null) return;
      ref.invalidate(syncPeersProvider);
      await _showOutcome(context, outcome);
    } catch (error) {
      if (context.mounted) await _showFailure(context, error);
    }
  }

  Future<void> _exportOnce(BuildContext context, WidgetRef ref) async {
    final path = await getDirectoryPath(confirmButtonText: 'Export here');
    if (path == null) return;

    try {
      final report =
          await ref.read(transferProgressProvider.notifier).exportTo(path);
      if (!context.mounted || report == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Exported ${pluralize(report.tracks, 'track')} and '
            '${pluralize(report.playlists, 'playlist')} '
            '(${_bytes(report.bytes)}) to ${p.basename(report.path)}',
          ),
        ),
      );
    } catch (error) {
      if (context.mounted) await _showFailure(context, error);
    }
  }

  /// Reads a bundle, shows what it would change, and only then applies it.
  Future<void> _importOnce(BuildContext context, WidgetRef ref) async {
    final path = await getDirectoryPath(confirmButtonText: 'Import from here');
    if (path == null) return;

    final file = File(p.join(path, transferBundleFileName));
    if (!await file.exists()) {
      if (!context.mounted) return;
      await _showFailure(
        context,
        'There is no $transferBundleFileName in that folder. Pick the '
        'folder a bundle was exported into -- or, in a shared folder, one of '
        'the folders under "machines".',
      );
      return;
    }

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _ImportDialog(path: path),
    );
    ref.invalidate(syncPeersProvider);
  }

  Future<void> _showOutcome(BuildContext context, SyncOutcome outcome) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Shared'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(outcome.summarize()),
                if (outcome.problems.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  for (final problem in outcome.problems)
                    Text(
                      problem,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
                if (outcome.missingTracks.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _MissingTracks(missing: outcome.missingTracks),
                ],
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );

  Future<void> _showFailure(BuildContext context, Object error) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('That did not work'),
          content: Text('$error'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
}

/// Another computer in the shared folder.
class _PeerTile extends ConsumerWidget {
  const _PeerTile({required this.peer});

  final SyncPeer peer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = peer.counts;
    final parts = [
      pluralize((counts['tracks'] as int?) ?? 0, 'track'),
      if (((counts['playlists'] as int?) ?? 0) > 0)
        pluralize(counts['playlists'] as int, 'playlist'),
      if (peer.hasAudio) 'with music files',
    ];

    return ListTile(
      leading: Icon(
        peer.isUpToDate ? Icons.cloud_done_outlined : Icons.cloud_download_outlined,
        color: peer.isUpToDate ? null : Theme.of(context).colorScheme.primary,
      ),
      title: Text(peer.origin.machineName),
      subtitle: Text(
        '${parts.join(' · ')} · shared ${_when(peer.exportedAt)}'
        '${peer.isUpToDate ? '' : ' · not read yet'}',
      ),
    );
  }
}

/// When this computer last shared, so "did it work" has an answer.
class _LastSharedTile extends ConsumerWidget {
  const _LastSharedTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stored = ref.watch(lastSharedAtProvider).value ?? '';
    if (stored.isEmpty) return const SizedBox.shrink();
    final when = DateTime.tryParse(stored);
    if (when == null) return const SizedBox.shrink();

    return ListTile(
      leading: const Icon(Icons.history),
      dense: true,
      title: Text('Last shared ${_when(when)}'),
    );
  }
}

/// A progress row while a transfer runs, matching the scan's.
class _TransferProgressTile extends StatelessWidget {
  const _TransferProgressTile({required this.progress});

  final TransferProgress progress;

  @override
  Widget build(BuildContext context) {
    final label = switch (progress.phase) {
      TransferPhase.readingLibrary => 'Reading this library',
      TransferPhase.writingBundle => 'Writing the bundle',
      TransferPhase.copyingArtwork => 'Copying artwork',
      TransferPhase.copyingAudio => 'Copying music files',
      TransferPhase.readingBundle => 'Reading the other computer',
      TransferPhase.matchingTracks => 'Finding these tracks here',
      TransferPhase.merging => 'Bringing it in',
      TransferPhase.rebuildingIndex => 'Rebuilding the search index',
      TransferPhase.done => 'Finishing up',
    };

    return ListTile(
      leading: const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
      title: Text(label),
      subtitle: progress.total == 0
          ? (progress.detail == null ? null : Text(progress.detail!))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                LinearProgressIndicator(value: progress.fraction),
                const SizedBox(height: 4),
                Text('${progress.completed} of ${progress.total}'),
              ],
            ),
    );
  }
}

/// Previews an import, then applies it.
///
/// The preview is the real import inside a rolled-back transaction, so what
/// this dialog promises and what the button does cannot drift apart. Changing
/// an option re-runs it, because an option that changed the outcome without
/// changing the description would be worse than no preview at all.
class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog({required this.path});

  final String path;

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  var _options = const TransferImportOptions();
  TransferReport? _preview;
  Object? _error;
  var _loading = true;
  var _applying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runPreview());
  }

  Future<void> _runPreview() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await ref.read(transferProgressProvider.notifier).importFrom(
            widget.path,
            options: _options,
            preview: true,
          );
      if (!mounted) return;
      setState(() {
        _preview = report;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _change(TransferImportOptions options) {
    setState(() => _options = options);
    _runPreview();
  }

  Future<void> _apply() async {
    setState(() => _applying = true);
    try {
      final report = await ref.read(transferProgressProvider.notifier).importFrom(
            widget.path,
            options: _options,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      if (report == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(report.summarize())),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;

    return AlertDialog(
      title: const Text('Bring this in?'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (preview != null)
                Text(
                  'From ${preview.origin}, exported ${_when(preview.exportedAt)}.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              const SizedBox(height: 12),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 12),
                      Text('Working out what would change...'),
                    ],
                  ),
                )
              else if (_error != null)
                Text(
                  '$_error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else if (preview != null)
                _PreviewSummary(report: preview),
              const SizedBox(height: 8),
              const Divider(),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Let the other computer win'),
                subtitle: const Text(
                  'Off, anything already set here is kept and only blanks are '
                  'filled. On, the incoming values replace them.',
                ),
                value: _options.conflicts == TransferConflictPolicy.preferTheirs,
                onChanged: _loading || _applying
                    ? null
                    : (value) => _change(TransferImportOptions(
                          conflicts: value
                              ? TransferConflictPolicy.preferTheirs
                              : TransferConflictPolicy.keepMine,
                          matching: _options.matching,
                          importPlaylists: _options.importPlaylists,
                          importArtwork: _options.importArtwork,
                          importPlayCounts: _options.importPlayCounts,
                        )),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Also match by title and album'),
                subtitle: const Text(
                  'For a different copy of the same song -- a re-download, or '
                  'an MP3 here and a FLAC there. Less certain than matching '
                  'the audio itself.',
                ),
                value: _options.matching == TransferMatchMode.alsoByTags,
                onChanged: _loading || _applying
                    ? null
                    : (value) => _change(TransferImportOptions(
                          conflicts: _options.conflicts,
                          matching: value
                              ? TransferMatchMode.alsoByTags
                              : TransferMatchMode.sameFiles,
                          importPlaylists: _options.importPlaylists,
                          importArtwork: _options.importArtwork,
                          importPlayCounts: _options.importPlayCounts,
                        )),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Include playlists'),
                value: _options.importPlaylists,
                onChanged: _loading || _applying
                    ? null
                    : (value) => _change(TransferImportOptions(
                          conflicts: _options.conflicts,
                          matching: _options.matching,
                          importPlaylists: value,
                          importArtwork: _options.importArtwork,
                          importPlayCounts: _options.importPlayCounts,
                        )),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _applying ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _loading || _applying || preview == null || _error != null
              ? null
              : _apply,
          child: Text(_applying ? 'Bringing it in...' : 'Bring it over'),
        ),
      ],
    );
  }
}

/// What an import would change, itemised.
class _PreviewSummary extends StatelessWidget {
  const _PreviewSummary({required this.report});

  final TransferReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = <(String, int)>[
      ('tracks updated', report.tracksUpdated),
      ('tags applied', report.tagLinksAdded),
      ('credits added', report.creditsAdded),
      ('alternative names added', report.aliasesAdded),
      ('artists added', report.artistsCreated),
      ('artists updated', report.artistsUpdated),
      ('albums added', report.albumsCreated),
      ('albums updated', report.albumsUpdated),
      ('tags created', report.tagsCreated),
      ('playlists added', report.playlistsCreated),
      ('playlist entries added', report.playlistItemsAdded),
      ('pictures brought in', report.imagesAdded),
      ('lyrics added', report.lyricsAdded),
      ('credit-splitting rules learned', report.splitRulesAdded),
    ].where((line) => line.$2 > 0).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lines.isEmpty)
          Text(
            'Nothing to bring over -- this computer already has everything in '
            'that bundle.',
            style: theme.textTheme.bodyMedium,
          )
        else
          for (final (label, count) in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text('$count $label'),
            ),
        if (report.conflictsKept > 0) ...[
          const SizedBox(height: 10),
          Text(
            '${report.conflictsKept} values differ and this computer\'s are '
            'kept. Turn on "let the other computer win" to take theirs '
            'instead.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        if (report.missingTracks.isNotEmpty) ...[
          const SizedBox(height: 12),
          _MissingTracks(missing: report.missingTracks),
        ],
      ],
    );
  }
}

/// Tracks a bundle knows about that this computer does not have.
///
/// Not an error, and worth saying plainly: it is the normal state right after
/// tagging new music elsewhere, and the fix is to copy the files across.
class _MissingTracks extends StatelessWidget {
  const _MissingTracks({required this.missing});

  final List<TransferMissingTrack> missing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = missing.take(6).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${pluralize(missing.length, 'track')} not on this computer yet',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          'Their tags are waiting. Copy the music across -- turning on '
          '"include the music files" over there does it for you -- then import '
          'again.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        for (final track in shown)
          Text(
            '· ${track.describe()}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        if (missing.length > shown.length)
          Text(
            '· and ${missing.length - shown.length} more',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }
}

/// A titled group, matching the rest of the settings page.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.subtitle});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 12),
        Card(
          color: theme.colorScheme.surfaceContainer,
          child: Column(children: children),
        ),
      ],
    );
  }
}

/// A rough "when", which is all anyone wants from a sync timestamp.
String _when(DateTime time) {
  final delta = DateTime.now().toUtc().difference(time.toUtc());
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inMinutes < 60) return '${pluralize(delta.inMinutes, 'minute')} ago';
  if (delta.inHours < 24) return '${pluralize(delta.inHours, 'hour')} ago';
  if (delta.inDays < 7) return '${pluralize(delta.inDays, 'day')} ago';
  final local = time.toLocal();
  return 'on ${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

String _bytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
