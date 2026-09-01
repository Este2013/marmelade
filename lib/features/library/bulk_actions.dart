import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/tag_repository.dart';
import '../../domain/models/library_views.dart' show LibrarySort;
import '../../widgets/time_text.dart';
import '../tags/category_icons.dart';
import '../../widgets/track_list.dart' show showAddToPlaylist;

/// Things done to several albums, songs or artists at once.
///
/// Every one of these is a loop over ids rather than a bulk statement. The
/// counts here are what someone can select by hand -- a few dozen, occasionally
/// a few hundred -- and a loop that reuses the same tested single-item path
/// cannot disagree with it about what "add a tag" means. A bulk SQL version
/// would be a second implementation of every rule.
class BulkActions {
  const BulkActions(this.ref);

  final WidgetRef ref;

  /// Tags everything in [ids], creating the tag if it is new.
  Future<int> tag(TagTarget target, Iterable<int> ids, String name) async {
    final repository = ref.read(tagRepositoryProvider);
    var done = 0;
    for (final id in ids) {
      await repository.attachByName(target, id, name);
      done += 1;
    }
    return done;
  }

  /// Removes a tag from everything in [ids] that had it.
  Future<int> untag(TagTarget target, Iterable<int> ids, int tagId) async {
    final repository = ref.read(tagRepositoryProvider);
    var done = 0;
    for (final id in ids) {
      await repository.detach(target, id, tagId);
      done += 1;
    }
    return done;
  }

  /// The tracks of several albums, in album then disc then track order.
  Future<List<int>> tracksOfAlbums(Iterable<int> albumIds) async {
    final library = ref.read(libraryRepositoryProvider);
    final ids = <int>[];
    for (final albumId in albumIds) {
      final tracks = await library
          .watchTracks(albumId: albumId, sort: LibrarySort.trackNumber)
          .first;
      ids.addAll(tracks.map((t) => t.id));
    }
    return ids;
  }

  /// The tracks of several artists, in the order their pages show them.
  Future<List<int>> tracksOfArtists(Iterable<int> artistIds) async {
    final library = ref.read(libraryRepositoryProvider);
    final ids = <int>[];
    final seen = <int>{};
    for (final artistId in artistIds) {
      final tracks = await library
          .watchTracks(artistId: artistId, sort: LibrarySort.albumThenTrack)
          .first;
      // Deduplicated across artists: two selected artists on the same
      // collaboration should queue that track once, not twice.
      for (final track in tracks) {
        if (seen.add(track.id)) ids.add(track.id);
      }
    }
    return ids;
  }
}

/// Asks for a tag name, offering the ones that already exist.
///
/// Returns null when dismissed. Typing a name that does not exist creates it,
/// which is the same rule the editors follow.
Future<String?> askForTag(
  BuildContext context,
  WidgetRef ref, {
  required String title,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _TagPromptDialog(title: title),
  );
}

class _TagPromptDialog extends ConsumerStatefulWidget {
  const _TagPromptDialog({required this.title});

  final String title;

  @override
  ConsumerState<_TagPromptDialog> createState() => _TagPromptDialogState();
}

class _TagPromptDialogState extends ConsumerState<_TagPromptDialog> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    Navigator.of(context).pop(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final typed = _controller.text.trim().toLowerCase();
    final all = ref.watch(taggedProvider).value ?? const [];
    final matches = typed.isEmpty
        ? all.take(12).toList()
        : all
            .where((tag) => tag.name.toLowerCase().contains(typed))
            .take(12)
            .toList();
    final exists = all.any((tag) => tag.name.toLowerCase() == typed);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Tag',
                hintText: 'An existing name, or a new one',
                border: OutlineInputBorder(),
              ),
              onSubmitted: _submit,
            ),
            if (typed.isNotEmpty && !exists)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'No tag called "${_controller.text.trim()}" yet — it will '
                  'be created.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            if (matches.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                typed.isEmpty ? 'Tags you already have' : 'Matching tags',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in matches)
                    ActionChip(
                      avatar: Icon(
                        tagCategoryIcon(tag.categoryIcon),
                        size: 16,
                        color: tag.color == null ? null : Color(tag.color!),
                      ),
                      label: Text('${tag.name}  ${tag.trackCount}'),
                      onPressed: () => _submit(tag.name),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => _submit(_controller.text),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// Tags a selection, then says what happened.
///
/// The report matters: a bulk action with no feedback looks like nothing
/// happened, and "did that work" is not a question a list should leave open.
Future<void> tagSelection(
  BuildContext context,
  WidgetRef ref, {
  required TagTarget target,
  required Set<int> ids,
  required String noun,
}) async {
  if (ids.isEmpty) return;
  final name = await askForTag(
    context,
    ref,
    title: 'Tag ${pluralize(ids.length, noun)}',
  );
  if (name == null) return;

  final done = await BulkActions(ref).tag(target, ids, name);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Tagged ${pluralize(done, noun)} with "$name".'),
    ),
  );
}

/// Adds a selection's tracks to a playlist.
Future<void> addTracksToPlaylist(
  BuildContext context,
  WidgetRef ref,
  List<int> trackIds,
) async {
  if (trackIds.isEmpty) return;
  await showAddToPlaylist(context, ref, trackIds);
}
