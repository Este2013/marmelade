import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import '../../domain/models/home_views.dart';
import '../../widgets/artwork.dart';
import '../edit/picture_section.dart' show pickImageFile;
import 'home_artwork.dart';

/// Chooses what a collection's tile shows.
///
/// A collection has no picture of its own, so by default it quarters the
/// first four it contains. That is the right answer most of the time and the
/// wrong one whenever a collection has a face -- a soundtrack whose cover
/// says what it is, a run of singles by one artist.
///
/// Two steps, because there are two questions and they are not the same one:
/// *how many* pictures the tile is made of, and *which*. Choosing a file used
/// to answer the second and silently change the first, which is how a picture
/// chosen by hand ended up as one quarter of a mosaic.
Future<void> pickCollectionPicture(
  BuildContext context,
  WidgetRef ref,
  HomeItemView collection,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ArtworkDialog(collection: collection),
  );
}

class _ArtworkDialog extends ConsumerStatefulWidget {
  const _ArtworkDialog({required this.collection});

  final HomeItemView collection;

  @override
  ConsumerState<_ArtworkDialog> createState() => _ArtworkDialogState();
}

class _ArtworkDialogState extends ConsumerState<_ArtworkDialog> {
  late HomeArtworkMode _mode = widget.collection.artworkMode;

  /// Every picture inside the collection, searches already run.
  ///
  /// Null while that is still happening: a collection whose middle is a rule
  /// does not know what it contains until the rule has been asked, and an
  /// empty grid in the meantime would read as "nothing in here".
  List<HomeItemView>? _contents;

  /// The collection as it is now, so the preview follows every choice made
  /// in here without the dialog having to be closed and reopened.
  HomeItemView get _live {
    HomeItemView? walk(List<HomeItemView> items, int depth) {
      if (depth > 8) return null;
      for (final item in items) {
        if (item.id == widget.collection.id) return item;
        final found = walk(item.children, depth + 1);
        if (found != null) return found;
      }
      return null;
    }

    for (final section in ref.watch(homeProvider).value ?? const []) {
      final found = walk(section.items, 0);
      if (found != null) return found;
    }
    return widget.collection;
  }

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final out = <HomeItemView>[];
    for (final child in widget.collection.children) {
      if (child.kind == HomeItemKind.query) {
        out.addAll(await ref.read(homeQueryItemsProvider)(child));
      } else {
        out.add(child);
      }
    }
    if (!mounted) return;
    setState(() => _contents = out);
  }

  /// One entry per distinct picture, so a collection of six albums by the
  /// same artist does not offer that face six times over.
  List<HomeItemView> get _choices {
    final seen = <String>{};
    return [
      for (final item in _contents ?? const <HomeItemView>[])
        if (item.imagePath != null && seen.add(item.imagePath!)) item,
    ];
  }

  Future<void> _setMode(HomeArtworkMode mode) async {
    setState(() => _mode = mode);
    await ref
        .read(homeRepositoryProvider)
        .setItemArtworkMode(widget.collection.id, mode);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // The mode lives in the title row, because it decides what the body of
      // the dialog is even asking.
      title: Row(
        children: [
          Expanded(
            child: Text(
              'Picture for "${widget.collection.title}"',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SegmentedButton<HomeArtworkMode>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              for (final mode in HomeArtworkMode.values)
                ButtonSegment(
                  value: mode,
                  icon: Icon(
                    mode == HomeArtworkMode.quadrant
                        ? Icons.grid_view
                        : Icons.image_outlined,
                    size: 16,
                  ),
                  label: Text(mode.label),
                ),
            ],
            selected: {_mode},
            onSelectionChanged: (set) => _setMode(set.first),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 470,
        child: _contents == null
            ? const Center(child: CircularProgressIndicator())
            : _mode == HomeArtworkMode.quadrant
                ? _QuadrantEditor(
                    collection: _live,
                    choices: _choices,
                    onPick: _pickForSlot,
                  )
                : _SingleEditor(
                    collection: _live,
                    choices: _choices,
                    onPick: _useAsWhole,
                  ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  /// Opens the chooser for one quarter, and pins whatever comes back.
  Future<void> _pickForSlot(int slot) async {
    final chosen = await showDialog<_Chosen>(
      context: context,
      builder: (context) => _ChooserDialog(
        title: 'Picture for the ${_ordinal(slot)} quarter',
        choices: _choices,
        current: slot < _live.quadrantPaths.length
            ? _live.quadrantPaths[slot]
            : null,
        allowAuto: true,
      ),
    );
    if (chosen == null) return;

    final repository = ref.read(homeRepositoryProvider);
    if (chosen.fromFile) {
      final file = await pickImageFile();
      if (file == null) return;
      // Stored against the collection first, then pinned by the path it
      // landed on: the store is content-addressed, so this is the same
      // picture either way round.
      final stored = await repository.storePicture(file);
      if (stored == null) return;
      await repository.setQuadrantImage(widget.collection.id, slot, stored);
      return;
    }
    await repository.setQuadrantImage(widget.collection.id, slot, chosen.path);
  }

  Future<void> _useAsWhole() async {
    final chosen = await showDialog<_Chosen>(
      context: context,
      builder: (context) => _ChooserDialog(
        title: 'Picture for "${widget.collection.title}"',
        choices: _choices,
        current: _live.imagePath,
        allowAuto: false,
      ),
    );
    if (chosen == null) return;

    final repository = ref.read(homeRepositoryProvider);
    if (chosen.fromFile) {
      final file = await pickImageFile();
      if (file == null) return;
      await repository.setItemPicture(widget.collection.id, file);
      return;
    }
    if (chosen.path != null) {
      await repository.setItemImageFromPath(widget.collection.id, chosen.path!);
    }
  }

  static String _ordinal(int slot) =>
      const ['first', 'second', 'third', 'fourth'][slot];
}

/// The quarters, laid out as they will be, each one a button.
class _QuadrantEditor extends StatelessWidget {
  const _QuadrantEditor({
    required this.collection,
    required this.choices,
    required this.onPick,
  });

  final HomeItemView collection;
  final List<HomeItemView> choices;
  final void Function(int slot) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final painted = collection.paintedCovers();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Click a quarter to choose what goes in it. Left alone, each one '
          'shows whatever is next in the collection.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (var slot = 0; slot < 4; slot++)
                    _Quarter(
                      cover: slot < painted.length ? painted[slot] : null,
                      pinned: slot < collection.quadrantPaths.length &&
                          collection.quadrantPaths[slot] != null,
                      onTap: choices.isEmpty ? null : () => onPick(slot),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Quarter extends StatelessWidget {
  const _Quarter({required this.cover, required this.pinned, this.onTap});

  final HomeCover? cover;
  final bool pinned;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = cover?.round ?? false ? 999.0 : 10.0;

    return Tooltip(
      message: pinned ? 'Chosen by hand' : 'Whatever comes next',
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (cover != null)
                Artwork(storedPath: cover!.path, borderRadius: radius)
              else
                Center(
                  child: Icon(Icons.add, color: scheme.onSurfaceVariant),
                ),
              if (pinned)
                Positioned(
                  right: 6,
                  top: 6,
                  child: _Badge(icon: Icons.push_pin, scheme: scheme),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The whole-tile picture, with the way to change it.
class _SingleEditor extends StatelessWidget {
  const _SingleEditor({
    required this.collection,
    required this.choices,
    required this.onPick,
  });

  final HomeItemView collection;
  final List<HomeItemView> choices;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'One picture, filling the tile. Without a choice it shows the '
          'first one in the collection.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: Material(
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                color: theme.colorScheme.surfaceContainerHighest,
                child: InkWell(
                  onTap: onPick,
                  child: HomeArtwork(item: collection, radius: 12),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: FilledButton.tonalIcon(
            onPressed: onPick,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Change it'),
          ),
        ),
      ],
    );
  }
}

/// What came back from the chooser.
typedef _Chosen = ({String? path, bool fromFile});

/// Picks one picture, from the collection or from disk.
///
/// The one currently in use wears a check, so opening this says what the
/// answer is now rather than only offering to change it.
class _ChooserDialog extends StatelessWidget {
  const _ChooserDialog({
    required this.title,
    required this.choices,
    required this.current,
    required this.allowAuto,
  });

  final String title;
  final List<HomeItemView> choices;
  final String? current;

  /// Whether "leave it to the collection" is an answer. It is for a quarter,
  /// which has something sensible to fall back to; it is not for the whole
  /// tile, where the fallback *is* the first picture anyway.
  final bool allowAuto;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 520,
        height: 420,
        child: choices.isEmpty
            ? Center(
                child: Text(
                  'Nothing in here has a picture yet.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              )
            : GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 110,
                  childAspectRatio: 1,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: choices.length,
                itemBuilder: (context, index) {
                  final item = choices[index];
                  final chosen = item.imagePath == current;
                  final radius = item.kind.isRound ? 999.0 : 10.0;

                  return Tooltip(
                    message: item.title,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(radius),
                      onTap: () => Navigator.of(context)
                          .pop((path: item.imagePath, fromFile: false)),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Artwork(
                              storedPath: item.imagePath,
                              // The library's own vocabulary here too: a
                              // person is round in the picker as well, or the
                              // choice would not look like what it produces.
                              borderRadius: radius,
                              fallbackSeed: item.title,
                            ),
                          ),
                          if (chosen)
                            Positioned(
                              right: 4,
                              top: 4,
                              child: _Badge(
                                icon: Icons.check,
                                scheme: theme.colorScheme,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (allowAuto)
          TextButton(
            // Distinct from Cancel, which pops nothing: this is an answer,
            // and the answer is "stop pinning this one".
            onPressed: () =>
                Navigator.of(context).pop((path: null, fromFile: false)),
            child: const Text('Leave it automatic'),
          ),
        FilledButton.icon(
          onPressed: () =>
              Navigator.of(context).pop((path: null, fromFile: true)),
          icon: const Icon(Icons.folder_open_outlined, size: 18),
          label: const Text('Choose a file'),
        ),
      ],
    );
  }
}

/// A small filled mark in a picture's corner.
class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.scheme});

  final IconData icon;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
      child: Icon(icon, size: 14, color: scheme.onPrimary),
    );
  }
}
