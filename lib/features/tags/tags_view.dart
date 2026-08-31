import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/tag_repository.dart';
import '../../domain/models/library_views.dart';
import '../../widgets/empty_state.dart';
import 'category_dialog.dart';
import 'category_icons.dart';
import '../../widgets/time_text.dart';

/// Every tag in the library, grouped by category.
///
/// The counts are the *effective* ones: a track tagged through its album or
/// through a playlist counts here, because that is what searching for the tag
/// will find. A count that disagreed with the search would be worse than no
/// count at all.
class TagsView extends ConsumerWidget {
  const TagsView({super.key, required this.onOpenTag});

  final void Function(int tagId) onOpenTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(taggedProvider);
    final categories = ref.watch(tagCategoriesProvider).value ?? const [];
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Row(
            children: [
              Text('Tags', style: theme.textTheme.headlineSmall),
              const SizedBox(width: 12),
              Text(
                pluralize(tags.value?.length ?? 0, 'tag'),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () => _newCategory(context, ref),
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('New category'),
              ),
            ],
          ),
        ),
        Expanded(
          child: tags.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'Could not load the tags',
              message: '$error',
            ),
            data: (items) {
              if (items.isEmpty) {
                return const EmptyState(
                  icon: Icons.label_outline,
                  title: 'No tags yet',
                  message: 'Genres and languages appear here once a scan finds '
                      'them in your files. Anything else is yours to invent, '
                      'from the editor for a track, album, artist or playlist.',
                );
              }
              return _Grouped(
                tags: items,
                categories: categories,
                onOpenTag: onOpenTag,
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _newCategory(BuildContext context, WidgetRef ref) async {
    final result = await editCategory(context, title: 'New tag category');
    if (result == null) return;
    final repository = ref.read(tagRepositoryProvider);
    final id = await repository.createCategory(
      result.name,
      color: result.color,
    );
    if (result.icon != null) {
      await repository.updateCategory(id, icon: result.icon, setIcon: true);
    }
  }
}

/// The tags, under a heading per category.
class _Grouped extends ConsumerWidget {
  const _Grouped({
    required this.tags,
    required this.categories,
    required this.onOpenTag,
  });

  final List<TagCard> tags;
  final List<TagCategoryRow> categories;
  final void Function(int tagId) onOpenTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final byCategory = <int?, List<TagCard>>{};
    for (final tag in tags) {
      byCategory.putIfAbsent(tag.categoryId, () => []).add(tag);
    }

    // Categories in their own order, then whatever is uncategorised, so an
    // untidied tag is visible rather than lost between the groups.
    // Every category gets a heading, empty or not. An empty one is a drop
    // target, and a category you have just made is exactly when you want to
    // drag things into it -- a heading that appears only once something is
    // already there cannot be used to put the first thing there.
    final sections = <({int? id, String name, List<TagCard> tags})>[
      for (final category in categories)
        (
          id: category.id,
          name: category.name,
          tags: byCategory[category.id] ?? const <TagCard>[],
        ),
      // Always offered, even when empty: it is the only way to drag a tag out
      // of a category, and a drop target that appears only once something is
      // already there cannot be used to put the first thing there.
      (
        id: null,
        name: 'Uncategorised',
        tags: byCategory[null] ?? const <TagCard>[],
      ),
    ];

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      itemCount: sections.length,
      itemBuilder: (context, index) {
        final section = sections[index];
        final category = section.id == null
            ? null
            : categories.where((c) => c.id == section.id).firstOrNull;

        return Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : 28, bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The heading is the drop target: dragging a tag onto it is the
              // fastest way to say "this belongs there", and the row already
              // names the place.
              DragTarget<int>(
                onWillAcceptWithDetails: (details) =>
                    !section.tags.any((tag) => tag.id == details.data),
                onAcceptWithDetails: (details) => ref
                    .read(tagRepositoryProvider)
                    .setTagCategory(details.data, section.id),
                builder: (context, candidate, rejected) {
                  final hovering = candidate.isNotEmpty;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: hovering
                          ? theme.colorScheme.primary.withValues(alpha: 0.14)
                          : null,
                      border: Border.all(
                        color: hovering
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          tagCategoryIcon(category?.icon),
                          size: 18,
                          color: category?.color == null
                              ? theme.colorScheme.onSurfaceVariant
                              : Color(category!.color!),
                        ),
                        const SizedBox(width: 10),
                        Text(section.name, style: theme.textTheme.titleMedium),
                        const SizedBox(width: 10),
                  Text(
                    pluralize(section.tags.length, 'tag'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (category != null && category.isSystem) ...[
                    const SizedBox(width: 10),
                    Tooltip(
                      message: 'Written by the library scan. It can be renamed '
                          'and recoloured, but not deleted.',
                      child: Icon(
                        Icons.auto_awesome,
                        size: 15,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (category != null)
                    PopupMenuButton<String>(
                      tooltip: 'More',
                      icon: const Icon(Icons.more_horiz, size: 20),
                      onSelected: (action) async {
                        if (action == 'rename') {
                          final result = await editCategory(
                            context,
                            title: 'Edit category',
                            name: category.name,
                            icon: category.icon,
                            color: category.color,
                          );
                          if (result == null) return;
                          await ref
                              .read(tagRepositoryProvider)
                              .updateCategory(
                                category.id,
                                name: result.name,
                                icon: result.icon,
                                setIcon: true,
                                color: result.color,
                                setColor: true,
                              );
                        } else if (action == 'delete') {
                          final ok = await ref
                              .read(tagRepositoryProvider)
                              .deleteCategory(category.id);
                          if (!ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'The scan writes that category on every run, '
                                  'so it cannot be deleted.',
                                ),
                              ),
                            );
                          }
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('Name, icon and colour'),
                        ),
                        if (!category.isSystem)
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete, keeping its tags'),
                          ),
                      ],
                    ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              if (section.tags.isEmpty)
                Text(
                  'Drag a tag here to take it out of its category.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final tag in section.tags)
                      Draggable<int>(
                        data: tag.id,
                        dragAnchorStrategy: pointerDragAnchorStrategy,
                        feedback: _DragFeedback(tag: tag),
                        childWhenDragging: Opacity(
                          opacity: 0.35,
                          child: _TagTile(tag: tag, onOpen: () {}),
                        ),
                        child: _TagTile(
                          tag: tag,
                          onOpen: () => onOpenTag(tag.id),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TagTile extends ConsumerWidget {
  const _TagTile({required this.tag, required this.onOpen});

  final TagCard tag;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colour = tag.color == null ? scheme.primary : Color(tag.color!);

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.label, size: 16, color: colour),
              const SizedBox(width: 8),
              Text(tag.name, style: theme.textTheme.bodyMedium),
              const SizedBox(width: 8),
              Text(
                '${tag.trackCount}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert, size: 16),
                padding: EdgeInsets.zero,
                onSelected: (action) async {
                  final repository = ref.read(tagRepositoryProvider);
                  if (action == 'rename') {
                    await editTag(
                      context,
                      ref,
                      tagId: tag.id,
                      name: tag.name,
                      categoryId: tag.categoryId,
                    );
                  } else if (action == 'delete') {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('Delete ${tag.name}?'),
                        content: Text(
                          'It comes off everything carrying it -- '
                          '${pluralize(tag.trackCount, 'track')}. The music '
                          'itself is untouched.',
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
                    await repository.deleteTag(tag.id);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'rename',
                    child: Text('Rename or recategorise'),
                  ),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What follows the pointer while a tag is being dragged.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.tag});

  final TagCard tag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Transform.translate(
      // Offset from the pointer so the cursor is not sitting on top of the
      // thing being dragged, which is what makes a drop target hard to aim at.
      offset: const Offset(-14, -18),
      child: Material(
        color: scheme.primaryContainer,
        elevation: 6,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.label, size: 16, color: scheme.onPrimaryContainer),
              const SizedBox(width: 8),
              Text(
                tag.name,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onPrimaryContainer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
