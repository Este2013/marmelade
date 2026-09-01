import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/tag_repository.dart';
import '../library/bulk_actions.dart';
import 'tag_visuals.dart';

/// One line of tags on a detail page, with a way to add another.
///
/// Not the editor: this is for a header, where the tags are worth seeing at a
/// glance and the room for them is a single line. Adding one is a chip at the
/// end that only appears while the pointer is on the line, so a page with tags
/// on it reads as tags rather than as a form.
class TagLine extends ConsumerStatefulWidget {
  const TagLine({
    super.key,
    required this.target,
    required this.id,
    this.onOpenTag,
  });

  final TagTarget target;
  final int id;

  /// Opens a tag's page, when there is somewhere to open it.
  final void Function(int tagId)? onOpenTag;

  @override
  ConsumerState<TagLine> createState() => _TagLineState();
}

class _TagLineState extends ConsumerState<TagLine> {
  var _hovering = false;
  var _busy = false;

  Future<void> _add() async {
    if (_busy) return;
    final name = await askForTag(context, ref, title: 'Add a tag');
    if (name == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref
          .read(tagRepositoryProvider)
          .attachByName(widget.target, widget.id, name);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tags = ref
            .watch(attachedTagsProvider((target: widget.target, id: widget.id)))
            .value ??
        const <AttachedTag>[];

    // With nothing on the line there is nothing to hover, so the chip has to
    // be there already -- quietly, since an untagged album should not look
    // like it is asking for something.
    final showAdd = _hovering || tags.isEmpty;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final tag in tags)
            _Chip(
              tag: tag,
              onOpen: widget.onOpenTag == null
                  ? null
                  : () => widget.onOpenTag!(tag.id),
            ),
          // Faded rather than removed. Adding and removing an interactive
          // widget on every hover churns the Windows accessibility tree, and a
          // chip that is always reachable is better for a screen reader than
          // one that needs a pointer to exist.
          AnimatedOpacity(
            opacity: showAdd ? 1 : 0,
            duration: const Duration(milliseconds: 140),
            alwaysIncludeSemantics: true,
            child: ActionChip(
              onPressed: _busy ? null : _add,
              avatar: Icon(Icons.add, size: 16, color: scheme.onSurfaceVariant),
              label: Text(
                tags.isEmpty ? 'Add a tag' : 'Add',
                style: theme.textTheme.bodySmall,
              ),
              visualDensity: VisualDensity.compact,
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.8),
              ),
              backgroundColor: Colors.transparent,
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.tag, this.onOpen});

  final AttachedTag tag;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final visuals = tagVisuals(
      context,
      categoryIcon: tag.categoryIcon,
      color: tag.color,
    );

    final chip = Chip(
      label: Text(tag.name, style: Theme.of(context).textTheme.bodySmall),
      avatar: Icon(visuals.icon, size: 14, color: visuals.color),
      backgroundColor: visuals.color.withValues(alpha: 0.14),
      side: BorderSide(color: visuals.color.withValues(alpha: 0.45)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    return Tooltip(
      message: [
        if (tag.categoryName != null) tag.categoryName!,
        if (onOpen != null) 'Click to see everything tagged this',
      ].join(' · '),
      child: onOpen == null
          ? chip
          : InkWell(
              onTap: onOpen,
              borderRadius: BorderRadius.circular(20),
              child: chip,
            ),
    );
  }
}
