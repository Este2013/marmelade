import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/tag_repository.dart';
import '../library/bulk_actions.dart';
import 'tag_visuals.dart';

/// Asks for a tag and puts it on something.
///
/// Public because two places offer it now: the chip at the end of a
/// [TagLine], and -- on a page whose line is hidden while it has no tags --
/// an icon button up beside the name. Both should ask the same question and
/// write the same row.
Future<void> addTagTo(
  BuildContext context,
  WidgetRef ref,
  TagTarget target,
  int id,
) async {
  final picked = await askForTag(context, ref, title: 'Add a tag');
  if (picked == null) return;
  await ref.read(tagRepositoryProvider).attachByName(
        target,
        id,
        picked.name,
        categoryId: picked.categoryId,
      );
}

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
    this.leading = const [],
    this.offerAdd = true,
  });

  final TagTarget target;
  final int id;

  /// Opens a tag's page, when there is somewhere to open it.
  final void Function(int tagId)? onOpenTag;

  /// Shown before the tags, in the same wrap.
  ///
  /// An artist's links go here. They flow with the chips rather than sitting
  /// in a row of their own because they are the same kind of thing to a
  /// reader -- small badges saying what this is and where it lives -- and a
  /// separate row for two icons would cost a line of the header for nothing.
  final List<Widget> leading;

  /// Whether this line offers the "Add a tag" chip.
  ///
  /// False on a page that offers the same action beside its name because the
  /// line is hidden while it has nothing on it (see the artist and album
  /// headers). Two ways to add the same tag, six pixels apart, is worse than
  /// either alone.
  final bool offerAdd;

  @override
  ConsumerState<TagLine> createState() => _TagLineState();
}

class _TagLineState extends ConsumerState<TagLine> {
  var _hovering = false;
  var _busy = false;

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
    if (_busy) return;
    await _run(() => addTagTo(context, ref, widget.target, widget.id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tags = ref
            .watch(attachedTagsProvider((target: widget.target, id: widget.id)))
            .value ??
        const <AttachedTag>[];

    // Faded even with nothing on the line: an untagged album should not look
    // like it is asking for something, and the pointer already has to be on
    // the line to see any of the other chips' hover state either.
    final showAdd = _hovering;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...widget.leading,
          for (final tag in tags)
            _Chip(
              tag: tag,
              onOpen: widget.onOpenTag == null
                  ? null
                  : () => widget.onOpenTag!(tag.id),
              onRemove: tag.isInherited || _busy
                  ? null
                  : () => _run(
                        () => ref
                            .read(tagRepositoryProvider)
                            .detach(widget.target, widget.id, tag.id),
                      ),
            ),
          // Faded rather than removed. Adding and removing an interactive
          // widget on every hover churns the Windows accessibility tree, and a
          // chip that is always reachable is better for a screen reader than
          // one that needs a pointer to exist.
          if (widget.offerAdd)
            AnimatedOpacity(
              opacity: showAdd ? 1 : 0,
              duration: const Duration(milliseconds: 140),
              alwaysIncludeSemantics: true,
              child: ActionChip(
                onPressed: _busy ? null : _add,
                avatar:
                    Icon(Icons.add, size: 16, color: scheme.onSurfaceVariant),
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
  const _Chip({required this.tag, this.onOpen, this.onRemove});

  final AttachedTag tag;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;

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
      onDeleted: onRemove,
      // The default delete icon is a filled circle around the X, which reads
      // as its own shape next to the chip's own rounded outline rather than
      // as part of it, and sits a little high besides. A bare X matches the
      // chip instead of competing with it.
      deleteIcon: const Icon(Icons.close, size: 14),
      deleteIconColor: visuals.color,
    );

    return Tooltip(
      message: [
        if (tag.categoryName != null) tag.categoryName!,
        if (tag.isInherited)
          switch (tag.origin) {
            TagOrigin.album => 'From this track\'s album. Remove it there.',
            TagOrigin.playlist =>
              'From a playlist this track is in. Remove it there.',
            TagOrigin.own => '',
          }
        else if (onOpen != null)
          'Click to see everything tagged this',
      ].where((s) => s.isNotEmpty).join(' · '),
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
