import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/logging/app_log.dart';
import '../../core/os/reveal_in_file_explorer.dart';
import '../../data/repositories/tag_repository.dart';
import '../../domain/models/library_views.dart' show LibrarySort, TrackRow;
import '../../widgets/selection.dart' show MenuAction;
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
  Future<int> tag(
    TagTarget target,
    Iterable<int> ids,
    String name, {
    int? categoryId,
  }) async {
    final repository = ref.read(tagRepositoryProvider);
    var done = 0;
    for (final id in ids) {
      await repository.attachByName(target, id, name, categoryId: categoryId);
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

/// Opens a dialog that tags (and untags) [ids] directly.
///
/// Nothing is returned: every add and remove is applied to the database the
/// moment it happens, so there is no "chosen tag" to hand back once the
/// dialog closes -- closing it just means "I am done here", the same as
/// closing [TagLine]'s own inline chips would.
Future<void> askForTag(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required TagTarget target,
  required Set<int> ids,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _TagPromptDialog(title: title, target: target, ids: ids),
  );
}

class _TagPromptDialog extends ConsumerStatefulWidget {
  const _TagPromptDialog({
    required this.title,
    required this.target,
    required this.ids,
  });

  final String title;
  final TagTarget target;
  final Set<int> ids;

  @override
  ConsumerState<_TagPromptDialog> createState() => _TagPromptDialogState();
}

class _TagPromptDialogState extends ConsumerState<_TagPromptDialog> {
  final _controller = TextEditingController();
  int? _categoryId;

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

  /// Attaches [name] to every id, creating the tag if it does not exist yet.
  ///
  /// Clears the field first rather than after: the write is a database round
  /// trip, and someone who just typed a name and hit Enter is already
  /// reaching for the next one.
  Future<void> _add(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _controller.clear();
    await BulkActions(ref).tag(widget.target, widget.ids, trimmed, categoryId: _categoryId);
  }

  Future<void> _remove(int tagId) =>
      BulkActions(ref).untag(widget.target, widget.ids, tagId);

  /// Stands in for "no category" as a [PopupMenuButton] value.
  ///
  /// `null` cannot do that job: [PopupMenuButton] pops `null` both when an
  /// item genuinely carries that value *and* when the menu is dismissed with
  /// nothing chosen, and reads either as a cancel -- `onSelected` is simply
  /// never called for a null result. Real category ids start at 1, so 0 can
  /// never collide with one.
  static const _noCategory = 0;

  /// The current pick, shown as the text field's own leading icon rather than
  /// a separate labelled dropdown -- there is only one thing to say here
  /// ("which category"), and a whole extra field said it at more length than
  /// it needed.
  Widget _categoryPicker(List<TagCategoryRow> categories) {
    final selected =
        categories.where((c) => c.id == _categoryId).firstOrNull;
    final color = selected?.color;

    return PopupMenuButton<int>(
      tooltip: 'Category',
      onSelected: (value) => setState(
        () => _categoryId = value == _noCategory ? null : value,
      ),
      itemBuilder: (context) => [
        const PopupMenuItem(value: _noCategory, child: Text('None')),
        for (final category in categories)
          PopupMenuItem(
            value: category.id,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  tagCategoryIcon(category.icon),
                  size: 18,
                  color: category.color == null ? null : Color(category.color!),
                ),
                const SizedBox(width: 10),
                Text(category.name),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Icon(
          selected == null ? Icons.label_outline : tagCategoryIcon(selected.icon),
          size: 20,
          color: color == null ? null : Color(color),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final typed = _controller.text.trim().toLowerCase();
    final all = ref.watch(taggedProvider).value ?? const [];
    final categories = ref.watch(tagCategoriesProvider).value ?? const [];

    // What every one of these ids already carries. Ordinarily one id, so this
    // is just that item's own tags; a wider selection unions whatever any of
    // them have, since removing one from the whole selection is exactly what
    // BulkActions.untag already does regardless of which ids actually had it.
    final existingById = <int, AttachedTag>{};
    for (final id in widget.ids) {
      final tags = ref
              .watch(attachedTagsProvider((target: widget.target, id: id)))
              .value ??
          const <AttachedTag>[];
      for (final tag in tags) {
        existingById[tag.id] = tag;
      }
    }
    final existing = existingById.values.toList();

    // Excludes what is already shown above: a tag on both lists at once would
    // read as two different things being offered for the same tag.
    final matches = (typed.isEmpty
            ? all
            : all.where((tag) => tag.name.toLowerCase().contains(typed)))
        .where((tag) => !existingById.containsKey(tag.id))
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
              decoration: InputDecoration(
                labelText: 'Tag',
                hintText: 'An existing name, or a new one',
                border: const OutlineInputBorder(),
                prefixIcon: _categoryPicker(categories),
                suffixIcon: typed.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Add',
                        icon: const Icon(Icons.add),
                        onPressed: () => _add(_controller.text),
                      ),
              ),
              onSubmitted: _add,
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
            if (existing.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Existing tags',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in existing)
                    Chip(
                      avatar: Icon(
                        tagCategoryIcon(tag.categoryIcon),
                        size: 16,
                        color: tag.color == null ? null : Color(tag.color!),
                      ),
                      label: Text(tag.name),
                      visualDensity: VisualDensity.compact,
                      // An inherited tag (a track wearing its album's, say)
                      // cannot be removed here -- it is removed from the
                      // thing that granted it -- so it gets no delete icon at
                      // all rather than one that would fail silently.
                      onDeleted: tag.isInherited ? null : () => _remove(tag.id),
                      deleteIcon: const Icon(Icons.close, size: 16),
                    ),
                ],
              ),
            ],
            if (matches.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Matching tags',
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
                      onPressed: () => _add(tag.name),
                    ),
                ],
              ),
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
    );
  }
}

/// Opens the tag dialog for a selection. See [askForTag]: every add and
/// remove made there lands on the database immediately.
Future<void> tagSelection(
  BuildContext context,
  WidgetRef ref, {
  required TagTarget target,
  required Set<int> ids,
  required String noun,
}) async {
  if (ids.isEmpty) return;
  await askForTag(
    context,
    ref,
    title: 'Tag ${pluralize(ids.length, noun)}',
    target: target,
    ids: ids,
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

/// The right-click menu for one track, wherever a [TrackList] or a bare
/// [TrackTile] shows one -- Songs, an album, an artist, a tag, a playlist.
///
/// Deliberately overlaps the row's own hover buttons: the buttons are faster
/// once you know they are there, a menu is what someone tries first, and a
/// menu is the only way to reach any of this without a mouse hovering the
/// row at all -- a narrow window, a touch screen, or simply not knowing the
/// buttons exist yet.
///
/// [ids] carries a wider selection than [track] alone when the caller has
/// one (see songs_view.dart); everywhere else there is no multi-select and
/// it is left as the track's own id.
List<MenuAction> trackContextMenu(
  BuildContext context,
  WidgetRef ref,
  TrackRow track, {
  List<int>? ids,
  void Function(int albumId)? onOpenAlbum,
  void Function(int artistId)? onOpenArtist,
  void Function(int trackId)? onEditTrack,
}) {
  final selected = ids ?? [track.id];
  final many = selected.length > 1;
  final player = ref.read(playerProvider.notifier);

  return [
    MenuAction(
      label: many ? 'Play these ${selected.length}' : 'Play',
      icon: Icons.play_arrow,
      onSelected: () => player.playAll(selected),
    ),
    MenuAction(
      label: 'Play next',
      icon: Icons.playlist_play,
      onSelected: () => player.playNext(selected),
    ),
    MenuAction(
      label: 'Add to the queue',
      icon: Icons.playlist_add,
      onSelected: () => player.addToQueue(selected),
    ),
    const MenuAction.separator(),
    MenuAction(
      label: 'Add to a playlist',
      icon: Icons.library_add_outlined,
      onSelected: () => addTracksToPlaylist(context, ref, selected),
    ),
    MenuAction(
      label: many ? 'Tag these ${selected.length} songs' : 'Add a tag',
      icon: Icons.label_outline,
      onSelected: () => tagSelection(
        context,
        ref,
        target: TagTarget.track,
        ids: selected.toSet(),
        noun: 'song',
      ),
    ),
    // Everything past here acts on this one row, not a selection: going
    // "to the album" or "to Explorer" for several tracks at once has no
    // single destination.
    if (!many) ...[
      const MenuAction.separator(),
      if (track.albumId != null && onOpenAlbum != null)
        MenuAction(
          label: 'Go to the album',
          icon: Icons.album_outlined,
          onSelected: () => onOpenAlbum(track.albumId!),
        ),
      if (track.credits.isNotEmpty && onOpenArtist != null)
        MenuAction(
          label: 'Go to ${track.credits.first.name}',
          icon: Icons.person_outline,
          onSelected: () => onOpenArtist(track.credits.first.artistId),
        ),
      if (onEditTrack != null)
        MenuAction(
          label: 'Edit track',
          icon: Icons.edit_outlined,
          onSelected: () => onEditTrack(track.id),
        ),
      MenuAction(
        label: 'Open in Explorer',
        icon: Icons.folder_open_outlined,
        onSelected: () => _revealTrackFile(ref, track),
      ),
    ],
  ];
}

/// Resolves the track's own file and reveals it, or logs why there is none.
///
/// Silent otherwise: the menu item stays enabled even for a track with no
/// playable file (missing drive, say), because "why can't I open this" is
/// exactly the question the log should answer, not a reason to grey the
/// option out pre-emptively for every track before anyone has clicked it.
Future<void> _revealTrackFile(WidgetRef ref, TrackRow track) async {
  final playable = await ref.read(libraryRepositoryProvider).playable(track.id);
  if (playable == null) {
    AppLog.instance.warn(
      'nothing to reveal in Explorer -- no playable file',
      tag: 'library',
      fields: {'trackId': track.id, 'title': track.title},
    );
    return;
  }
  await revealInFileExplorer(playable.filePath);
}
