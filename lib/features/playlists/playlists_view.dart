import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart' show PlaylistKind;
import '../../domain/models/library_views.dart';
import '../../domain/search/smart_query.dart';
import 'smart_query_field.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/section_title.dart';
import '../../widgets/time_text.dart';

/// The playlists, as a tree.
///
/// A playlist can sit inside another, so this is a flat list with indentation
/// rather than a grid: the nesting is the structure, and a grid would throw it
/// away.
class PlaylistsView extends ConsumerWidget {
  const PlaylistsView({
    super.key,
    required this.onOpenPlaylist,
  });

  final void Function(int playlistId) onOpenPlaylist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);

    return Column(
      children: [
        Expanded(
          child: playlists.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'Could not load the playlists',
              message: '$error',
            ),
            data: (items) {
              if (items.isEmpty) {
                return EmptyState(
                  icon: Icons.playlist_play_outlined,
                  title: 'No playlists yet',
                  message: 'A playlist can hold tracks, and it can hold other '
                      'playlists -- so a folder and a playlist are the same '
                      'thing here.',
                  action: FilledButton.icon(
                    onPressed: () => createPlaylist(context, ref),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New playlist'),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                itemCount: items.length,
                itemBuilder: (context, index) => _PlaylistTile(
                  playlist: items[index],
                  onOpen: () => onOpenPlaylist(items[index].id),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Title, count and the two "new playlist" actions -- the playlists
/// section's own toolbar, merged into the window's title bar. See [AppShell]
/// and `WindowChrome.content`.
class PlaylistsToolbar extends ConsumerWidget {
  const PlaylistsToolbar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    final theme = Theme.of(context);

    return Row(
      children: [
        const SectionTitle(icon: Icons.playlist_play, label: 'Playlists'),
        const SizedBox(width: 12),
        Text(
          pluralize(playlists.value?.length ?? 0, 'playlist'),
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: () => createSmartPlaylist(context, ref),
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: const Text('New smart playlist'),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: () => createPlaylist(context, ref),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New playlist'),
        ),
      ],
    );
  }
}

/// Creates a playlist that follows a query.
///
/// The query is asked for up front, because a smart playlist with no query is
/// an empty page that does not say why. It can be changed on the playlist
/// itself afterwards.
Future<int?> createSmartPlaylist(
  BuildContext context,
  WidgetRef ref, {
  int? parentId,
}) async {
  final result = await showDialog<({String name, String query})>(
    context: context,
    builder: (context) => const _SmartPlaylistDialog(),
  );
  if (result == null) return null;

  final repository = ref.read(playlistRepositoryProvider);
  final id = await repository.create(
    result.name,
    parentId: parentId,
    kind: PlaylistKind.smart,
  );
  if (id == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That would nest the playlists too deep.'),
        ),
      );
    }
    return null;
  }
  await repository.saveQuery(id, query: result.query);
  return id;
}

/// Asks for a name and creates a playlist, optionally inside [parentId].
///
/// Returns the new playlist's id, so a caller that wants to open it can.
Future<int?> createPlaylist(
  BuildContext context,
  WidgetRef ref, {
  int? parentId,
  String? parentName,
}) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        parentName == null ? 'New playlist' : 'New playlist in $parentName',
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Name',
          border: OutlineInputBorder(),
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
          child: const Text('Create'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name == null || name.trim().isEmpty) return null;

  final id = await ref
      .read(playlistRepositoryProvider)
      .create(name, parentId: parentId);
  if (id == null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('That would nest the playlists too deep.'),
      ),
    );
  }
  return id;
}

class _PlaylistTile extends ConsumerWidget {
  const _PlaylistTile({required this.playlist, required this.onOpen});

  final PlaylistCard playlist;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final repository = ref.read(playlistRepositoryProvider);

    return Padding(
      // Indented by depth, which is the whole visual signal that this playlist
      // sits inside another.
      padding: EdgeInsets.only(left: playlist.depth * 28.0, bottom: 4),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Artwork(
                  storedPath: playlist.imagePath,
                  size: 44,
                  borderRadius: 6,
                  fallbackSeed: playlist.name,
                  fallbackIcon: playlist.childCount > 0
                      ? Icons.folder_outlined
                      : Icons.playlist_play,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(playlist.name, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        _summary(playlist),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (playlist.isSmart)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Tooltip(
                      message: 'Follows a search: ${playlist.query ?? ''}',
                      child: Icon(Icons.auto_awesome,
                          size: 18, color: scheme.primary),
                    ),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) async {
                    switch (action) {
                      case 'child':
                        await createPlaylist(
                          context,
                          ref,
                          parentId: playlist.id,
                          parentName: playlist.name,
                        );
                      case 'rename':
                        await _rename(context, ref);
                      case 'top':
                        await repository.reparent(playlist.id, null);
                      case 'toSmart':
                        await repository.convertToSmart(playlist.id);
                      case 'freeze':
                        await _confirmFreeze(context, ref);
                      case 'delete':
                        await _confirmDelete(context, ref);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'child',
                      child: Text('New playlist inside this one'),
                    ),
                    const PopupMenuItem(
                      value: 'rename',
                      child: Text('Rename'),
                    ),
                    if (playlist.parentId != null)
                      const PopupMenuItem(
                        value: 'top',
                        child: Text('Move to the top level'),
                      ),
                    const PopupMenuDivider(),
                    if (playlist.kind == 'manual')
                      const PopupMenuItem(
                        value: 'toSmart',
                        child: Text('Convert to smart playlist'),
                      ),
                    if (playlist.isSmart)
                      const PopupMenuItem(
                        value: 'freeze',
                        child: Text('Convert to manual playlist'),
                      ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _summary(PlaylistCard playlist) {
    // A smart playlist has no rows, so a track count would read as zero for
    // something that might hold two hundred songs. What it says instead is
    // what it means, which is the query.
    if (playlist.isSmart) {
      final query = playlist.query;
      if (query != null && query.trim().isNotEmpty) {
        return SmartQuery.parse(query).describe();
      }
      return 'Follows a search, once it has one';
    }
    final parts = <String>[
      if (playlist.trackCount > 0 || playlist.childCount == 0)
        pluralize(playlist.trackCount, 'track'),
      if (playlist.childCount > 0)
        pluralize(playlist.childCount, 'playlist'),
      if (playlist.totalDurationMs > 0)
        formatDurationLong(playlist.totalDuration),
    ];
    return parts.join(' · ');
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
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
    if (name == null) return;
    await ref.read(playlistRepositoryProvider).rename(playlist.id, name);
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final nested = playlist.childCount > 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${playlist.name}?'),
        content: Text(
          nested
              // Worth spelling out: the cascade is not obvious from the tree.
              ? 'The playlists inside it are deleted too. The tracks '
                  'themselves are untouched.'
              : 'The tracks themselves are untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(playlistRepositoryProvider).delete(playlist.id);
  }

  Future<void> _confirmFreeze(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Convert ${playlist.name} to a manual playlist?'),
        content: const Text(
          'Its query is replaced by the plain list of tracks it currently '
          'matches. It stops following the library, and the query cannot be '
          'recovered afterwards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Convert'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(playlistRepositoryProvider).freeze(playlist.id);
  }
}

/// Asks for the two things a smart playlist needs: a name and a query.
class _SmartPlaylistDialog extends StatefulWidget {
  const _SmartPlaylistDialog();

  @override
  State<_SmartPlaylistDialog> createState() => _SmartPlaylistDialogState();
}

class _SmartPlaylistDialogState extends State<_SmartPlaylistDialog> {
  final _name = TextEditingController();
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _name.addListener(_onChanged);
    _query.addListener(_onChanged);
  }

  @override
  void dispose() {
    _name.dispose();
    _query.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  bool get _ready =>
      _name.text.trim().isNotEmpty && _query.text.trim().isNotEmpty;

  void _submit() {
    if (!_ready) return;
    Navigator.of(context).pop((
      name: _name.text.trim(),
      query: _query.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New smart playlist'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            SmartQueryField(
              controller: _query,
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _ready ? _submit : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
