import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/tag_repository.dart';
import '../tags/tag_visuals.dart';
import 'edit_widgets.dart';

/// The tags on one thing, with a field to add another.
///
/// Used for artists, albums, tracks and playlists. For a track it also shows
/// what it inherits from its album and from any playlist it is in: those chips
/// are marked and cannot be removed here, because they belong to the thing that
/// granted them. Hiding them would be worse -- the track really does carry
/// them, and searching will find it by them.
class TagSection extends ConsumerStatefulWidget {
  const TagSection({
    super.key,
    required this.target,
    required this.id,
    this.subtitle,
    this.onOpenTag,
  });

  final TagTarget target;
  final int id;
  final String? subtitle;

  /// Opens a tag's page, when there is somewhere to open it.
  final void Function(int tagId)? onOpenTag;

  @override
  ConsumerState<TagSection> createState() => _TagSectionState();
}

class _TagSectionState extends ConsumerState<TagSection> {
  final _controller = TextEditingController();
  int? _categoryId;
  var _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    await _run(() async {
      await ref.read(tagRepositoryProvider).attachByName(
            widget.target,
            widget.id,
            text,
            categoryId: _categoryId,
          );
      _controller.clear();
    });
  }

  /// The default subtitle, which differs per kind because the cascade does.
  String get _subtitle {
    if (widget.subtitle != null) return widget.subtitle!;
    return switch (widget.target) {
      TagTarget.track => 'Labels for this track. Tags on its album or on a '
          'playlist it is in also apply, and are shown greyed out.',
      TagTarget.album => 'Labels for this release. They apply to every track '
          'on it as well.',
      TagTarget.playlist => 'Labels for this playlist. They apply to every '
          'track it contains, including through nested playlists.',
      TagTarget.artist => 'Labels for this artist. These describe the artist '
          'and deliberately do not spread to their tracks.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final attached = ref.watch(
      attachedTagsProvider((target: widget.target, id: widget.id)),
    );
    final categories = ref.watch(tagCategoriesProvider).value ?? const [];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tags = attached.value ?? const <AttachedTag>[];

    return EditSection(
      title: 'Tags',
      subtitle: _subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tags.isEmpty)
            Text(
              'No tags yet.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in tags)
                  _TagChip(
                    tag: tag,
                    onOpen: widget.onOpenTag == null
                        ? null
                        : () => widget.onOpenTag!(tag.id),
                    onRemove: tag.isInherited || _busy
                        ? null
                        : () => _run(
                              () => ref.read(tagRepositoryProvider).detach(
                                    widget.target,
                                    widget.id,
                                    tag.id,
                                  ),
                            ),
                  ),
              ],
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: EditField(
                  controller: _controller,
                  label: 'Add a tag',
                  hint: 'An existing name attaches that tag; a new one makes it',
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<int?>(
                  isExpanded: true,
                  initialValue: _categoryId,
                  decoration: const InputDecoration(
                    labelText: 'Category',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('None')),
                    for (final category in categories)
                      DropdownMenuItem(
                        value: category.id,
                        child: Text(category.name),
                      ),
                  ],
                  onChanged: (value) => setState(() => _categoryId = value),
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                tooltip: 'Add',
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One tag, showing whether it is this thing's own or inherited.
class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag, this.onOpen, this.onRemove});

  final AttachedTag tag;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visuals = tagVisuals(
      context,
      categoryIcon: tag.categoryIcon,
      color: tag.color,
    );

    // Inherited chips are dimmed, not just differently iconed: the section
    // says they are greyed out, and at a glance the icon alone does not read
    // as "you cannot change this here".
    final muted = scheme.onSurfaceVariant.withValues(alpha: 0.75);
    final chip = tag.isInherited
        ? Chip(
            label: Text(tag.name, style: TextStyle(color: muted)),
            // Where it came from, not what it is: an inherited chip's job is to
            // say "this belongs to the album", and the album is the answer.
            avatar: Icon(
              tag.origin == TagOrigin.album
                  ? Icons.album_outlined
                  : Icons.playlist_play,
              size: 16,
              color: muted,
            ),
            backgroundColor: scheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          )
        : Chip(
            label: Text(tag.name),
            avatar: Icon(visuals.icon, size: 16, color: visuals.color),
            backgroundColor: visuals.color.withValues(alpha: 0.14),
            side: BorderSide(color: visuals.color.withValues(alpha: 0.45)),
            onDeleted: onRemove,
          );

    return Tooltip(
      message: switch (tag.origin) {
        TagOrigin.album => 'From this track\'s album. Remove it there.',
        TagOrigin.playlist =>
          'From a playlist this track is in. Remove it there.',
        TagOrigin.own => [
            if (tag.categoryName != null) tag.categoryName!,
            if (onOpen != null) 'Click to see everything tagged this',
          ].join(' · '),
      },
      child: onOpen == null || tag.isInherited
          ? chip
          : InkWell(
              onTap: onOpen,
              borderRadius: BorderRadius.circular(20),
              child: chip,
            ),
    );
  }
}
