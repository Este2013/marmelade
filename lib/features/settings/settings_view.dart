import 'package:drift/drift.dart' show Value;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/indexer/library_indexer.dart';
import '../../widgets/time_text.dart';

/// Where the project lives, shown in settings and used by the updater.
const repositoryUrl = 'https://github.com/Este2013/marmelade';

/// Settings, starting with the thing a new install needs most: a folder.
class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      children: [
        Text('Settings', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 20),
        const _LibrarySection(),
        const SizedBox(height: 28),
        const _StatisticsSection(),
        const SizedBox(height: 28),
        const _AboutSection(),
      ],
    );
  }
}

/// A titled group of settings.
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

/// Watched folders, and the scan controls.
class _LibrarySection extends ConsumerWidget {
  const _LibrarySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(libraryFoldersProvider);
    final progress = ref.watch(indexProgressProvider);
    final jobs = ref.read(indexProgressProvider.notifier);

    return _Section(
      title: 'Music folders',
      subtitle: 'marmelade indexes these folders and watches them for changes.',
      children: [
        ...?folders.value?.map(
          (folder) => _FolderTile(folder: folder),
        ),
        if (folders.value?.isEmpty ?? true)
          const ListTile(
            leading: Icon(Icons.folder_off_outlined),
            title: Text('No folders yet'),
            subtitle: Text('Add one to start building your library.'),
          ),
        if (progress != null) _ScanProgressTile(progress: progress),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: progress != null
                    ? null
                    : () => _addFolder(context, ref),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Add folder'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: progress != null || (folders.value?.isEmpty ?? true)
                    ? null
                    : () => _refresh(context, jobs),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh library'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _addFolder(BuildContext context, WidgetRef ref) async {
    final path = await getDirectoryPath(
      confirmButtonText: 'Add to library',
    );
    if (path == null) return;

    final outcome = await ref.read(indexProgressProvider.notifier)
        .addFolder(path);
    if (!context.mounted || outcome == null) return;

    _showOutcome(context, [outcome]);
  }

  Future<void> _refresh(
    BuildContext context,
    IndexJobController jobs,
  ) async {
    final outcomes = await jobs.refreshAll();
    if (!context.mounted) return;
    _showOutcome(context, outcomes);
  }

  /// Reports what a scan did, including what it wants reviewed.
  static void _showOutcome(BuildContext context, List<IndexOutcome> outcomes) {
    if (outcomes.isEmpty) return;
    var added = 0, moved = 0, missing = 0, pending = 0, tracks = 0;
    for (final outcome in outcomes) {
      added += outcome.filesAdded;
      moved += outcome.filesMoved;
      missing += outcome.filesMissing;
      pending += outcome.pendingCredits;
      tracks += outcome.tracksCreated;
    }

    final parts = <String>[
      if (tracks > 0) '$tracks new ${tracks == 1 ? 'track' : 'tracks'}',
      // Moves are worth reporting: it is the app telling the user it noticed
      // their reorganisation rather than silently duplicating everything.
      if (moved > 0) '$moved moved',
      if (missing > 0) '$missing missing',
      if (pending > 0) '$pending to review',
    ];

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        parts.isEmpty
            ? 'Library is up to date'
            : 'Scanned $added ${added == 1 ? 'file' : 'files'} · '
                '${parts.join(' · ')}',
      ),
    ));
  }
}

class _FolderTile extends ConsumerWidget {
  const _FolderTile({required this.folder});

  final LibraryFolder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final db = ref.watch(databaseProvider);

    return ListTile(
      leading: Icon(
        folder.enabled ? Icons.folder_outlined : Icons.folder_off_outlined,
        color: folder.enabled ? null : theme.disabledColor,
      ),
      title: Text(
        folder.displayName ?? folder.path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          pluralize(folder.trackedFileCount, 'file'),
          if (folder.lastScanDurationMs != null)
            'scanned in ${folder.lastScanDurationMs} ms',
          if (!folder.enabled) 'disabled',
        ].join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: folder.enabled,
            onChanged: (value) => (db.update(db.libraryFolders)
                  ..where((t) => t.id.equals(folder.id)))
                .write(LibraryFoldersCompanion(enabled: Value(value))),
          ),
          IconButton(
            tooltip: 'Remove from library',
            onPressed: () => _confirmRemove(context, ref, db),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  /// Removing a folder discards its tracks, so it asks first.
  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    MarmeladeDatabase db,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this folder?'),
        content: Text(
          'The files on disk are left alone, but marmelade will forget the '
          '${pluralize(folder.trackedFileCount, 'track')} it indexed from '
          '${folder.path}, along with their play counts and ratings.\n\n'
          'Disabling the folder instead keeps all of that.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await (db.delete(db.libraryFolders)..where((t) => t.id.equals(folder.id)))
        .go();
  }
}

/// A progress row shown while a scan runs.
class _ScanProgressTile extends StatelessWidget {
  const _ScanProgressTile({required this.progress});

  final IndexProgress progress;

  @override
  Widget build(BuildContext context) {
    final label = switch (progress.phase) {
      IndexPhase.scanning => 'Looking for files',
      IndexPhase.reconciling => 'Working out what changed',
      IndexPhase.readingTags => 'Reading tags',
      IndexPhase.resolvingCredits => 'Matching artists',
      IndexPhase.writing => 'Saving',
      IndexPhase.artwork => 'Importing artwork',
      IndexPhase.indexingSearch => 'Building the search index',
      IndexPhase.done => 'Finishing up',
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

/// Library counts, and anything waiting for the user's attention.
class _StatisticsSection extends ConsumerWidget {
  const _StatisticsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(libraryCountsProvider);
    final data = counts.value;

    return _Section(
      title: 'Library',
      children: [
        if (data == null)
          const ListTile(title: Text('Counting...'))
        else ...[
          ListTile(
            leading: const Icon(Icons.library_music_outlined),
            title: Text(
              '${pluralize(data.tracks, 'track')} · '
              '${pluralize(data.albums, 'album')} · '
              '${pluralize(data.artists, 'artist')}',
            ),
            subtitle: Text(
              '${pluralize(data.files, 'file')} · '
              '${formatDurationLong(data.totalDuration)} of music',
            ),
          ),
          if (data.missingFiles > 0)
            ListTile(
              leading: Icon(
                Icons.link_off,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(pluralize(data.missingFiles, 'missing file')),
              subtitle: const Text(
                'Kept, along with their ratings and play counts, in case the '
                'drive comes back.',
              ),
            ),
          if (data.pendingCredits > 0)
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: Text(
                '${pluralize(data.pendingCredits, 'credit')} to review',
              ),
              subtitle: const Text(
                'Artist names marmelade would rather ask about than guess at.',
              ),
            ),
        ],
      ],
    );
  }
}

/// Version, repository link and the debug entry points.
class _AboutSection extends ConsumerWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _Section(
      title: 'About',
      children: [
        const ListTile(
          leading: Icon(Icons.emoji_food_beverage_outlined),
          title: Text('marmelade'),
          subtitle: Text('we be jamming to the tunes'),
        ),
        ListTile(
          leading: const Icon(Icons.code),
          title: const Text('Source code'),
          subtitle: const Text(repositoryUrl),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => launchUrl(Uri.parse(repositoryUrl)),
        ),
      ],
    );
  }
}
