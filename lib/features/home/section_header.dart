import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import '../../data/repositories/home_repository.dart';
import '../../domain/models/home_views.dart';
import '../../widgets/selection.dart';
import '../tags/category_icons.dart';

/// A section's title bar, and everywhere its settings live.
///
/// This replaced an arranging mode. Everything that mode used to reveal is
/// now attached to the thing it acts on: the icon collapses, hovering offers
/// a plus, right-clicking offers the rest, and a long press picks the whole
/// section up. Nothing has to be switched on first, and nothing is on screen
/// until it is wanted -- which is what the mode was trying to achieve by
/// hiding everything behind a toggle.
class SectionHeader extends ConsumerStatefulWidget {
  const SectionHeader({super.key, required this.section, required this.onViewAll, required this.onAddItems});

  final HomeSectionView section;
  final VoidCallback onViewAll;
  final VoidCallback onAddItems;

  @override
  ConsumerState<SectionHeader> createState() => _SectionHeaderState();
}

class _SectionHeaderState extends ConsumerState<SectionHeader> {
  var _hovering = false;

  HomeRepository get _repository => ref.read(homeRepositoryProvider);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final section = widget.section;

    return Material(
      // Transparent, not a surface of its own: the ink has to land on
      // something, but the header is not a card and should not read as one.
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        // The whole bar is one target. The Spacer below stretches the row the
        // full width, so the empty space to the right of a short title
        // behaves exactly as the title does -- hitting the few characters of a
        // word is a worse target than the row it sits in.
        onTap: () =>
            _repository.setSectionCollapsed(section.id, !section.collapsed),
        onSecondaryTapUp: (details) =>
            showItemMenu(context, details.globalPosition, _menu(context)),
        // InkWell's own hover rather than a MouseRegion around it: one source
        // of truth for "the pointer is on this bar", which is what the plus
        // fades in on.
        onHover: (over) => setState(() => _hovering = over),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            spacing: 8,
            children: [
              // Still a real button, even though the whole bar now does the
              // same thing: an InkWell is not focusable on its own here, so
              // dropping it would leave collapsing reachable by mouse only.
              // It simply absorbs the tap within its own few pixels.
              _CollapseButton(
                collapsed: section.collapsed,
                icon: section.icon,
                onTap: () => _repository.setSectionCollapsed(
                  section.id,
                  !section.collapsed,
                ),
              ),

              Flexible(
                child: Text(
                  section.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
              ),

              // Only ever an icon. A chip wide enough to read "Add items to
              // Pinned" is a chip that moves the title every time the pointer
              // crosses the row, and the plus says the same thing in a corner
              // of the space.
              if (section.source.isCurated)
                AnimatedOpacity(
                  opacity: _hovering ? 1 : 0,
                  duration: const Duration(milliseconds: 140),
                  // Kept in the tree at every opacity: toggling a button in
                  // and out rewrites its semantics node rather than updating
                  // it, which is what floods the Windows accessibility bridge.
                  alwaysIncludeSemantics: true,
                  child: IconButton(
                    tooltip: 'Add items to "${section.title}"',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onAddItems,
                    iconSize: 20,
                    icon: const Icon(Icons.add),
                  ),
                ),

              if (section.hasMore && !section.collapsed)
                TextButton(
                  onPressed: widget.onViewAll,
                  child: Text('View all ${section.items.length}'),
                ),

              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  List<MenuAction> _menu(BuildContext context) {
    final section = widget.section;
    return [
      MenuAction(
        label: section.layout == HomeLayout.grid ? 'Show as a list' : 'Show as a grid',
        icon: section.layout == HomeLayout.grid ? Icons.view_list : Icons.grid_view,
        onSelected: () => _repository.setSectionLayout(section.id, section.layout == HomeLayout.grid ? HomeLayout.list : HomeLayout.grid),
      ),
      MenuAction(
        label: section.collapsed ? 'Expand' : 'Collapse',
        icon: section.collapsed ? Icons.unfold_more : Icons.unfold_less,
        onSelected: () => _repository.setSectionCollapsed(section.id, !section.collapsed),
      ),
      const MenuAction.separator(),
      MenuAction(label: 'Rename', icon: Icons.edit_outlined, onSelected: () => _rename(context)),
      MenuAction(label: section.icon == null ? 'Give it an icon' : 'Change its icon', icon: Icons.emoji_symbols_outlined, onSelected: () => _pickIcon(context)),
      if (section.source.isCurated) MenuAction(label: 'Add items', icon: Icons.add, onSelected: widget.onAddItems),
      const MenuAction.separator(),
      MenuAction(label: 'Remove section', icon: Icons.delete_outline, isDestructive: true, onSelected: () => _confirmRemove(context)),
    ];
  }

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: widget.section.title);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename section'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Rename')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await _repository.renameSection(widget.section.id, name.trim());
  }

  Future<void> _pickIcon(BuildContext context) async {
    final chosen = await showDialog<int?>(
      context: context,
      builder: (context) => _IconPicker(current: widget.section.icon),
    );
    // A dismissed dialog and "no icon" are different answers, and only the
    // second should write. The sentinel is the code point of the clear
    // option, which no real icon uses.
    if (chosen == null) return;
    await _repository.setSectionIcon(widget.section.id, chosen == _IconPicker.none ? null : chosen);
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final section = widget.section;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${section.title}"?'),
        content: Text(
          section.source.isCurated
              ? 'The items in it are only removed from the home page. '
                    'Nothing is deleted from your library.'
              : 'It can be added again from "New section".',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.removeSection(section.id);
  }
}

/// The section's icon, which is also how it rolls up.
///
/// One control doing both jobs rather than an icon beside a chevron: a
/// section that has been given a mark should show that mark, and the place
/// the chevron was is exactly where somebody reaches to fold the thing away.
/// Hovering swaps in the chevron so the second job stays discoverable.
class _CollapseButton extends StatefulWidget {
  const _CollapseButton({required this.collapsed, required this.icon, required this.onTap});

  final bool collapsed;
  final int? icon;
  final VoidCallback onTap;

  @override
  State<_CollapseButton> createState() => _CollapseButtonState();
}

class _CollapseButtonState extends State<_CollapseButton> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasIcon = widget.icon != null;
    final showChevron = !hasIcon || _hovering;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: IconButton(
        tooltip: widget.collapsed ? 'Expand' : 'Collapse',
        visualDensity: VisualDensity.compact,
        onPressed: widget.onTap,
        icon: Icon(showChevron ? (widget.collapsed ? Icons.chevron_right : Icons.expand_more) : tagCategoryIcon(widget.icon), color: hasIcon && !_hovering ? scheme.primary : null),
      ),
    );
  }
}

/// Picks one of the fixed icons a section can wear.
///
/// The same list tag categories use, and for the same reason: a code point
/// handed to `IconData` at runtime defeats icon-font tree-shaking, so the
/// stored number is only ever looked up in a list the compiler can see.
class _IconPicker extends StatelessWidget {
  const _IconPicker({required this.current});

  final int? current;

  /// Returned for "no icon". Zero is not a code point any glyph here uses.
  static const none = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Section icon'),
      content: SizedBox(
        width: 400,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final entry in tagCategoryIcons)
              IconButton(
                tooltip: entry.name,
                isSelected: current == entry.icon.codePoint,
                onPressed: () => Navigator.of(context).pop(entry.icon.codePoint),
                icon: Icon(entry.icon, color: current == entry.icon.codePoint ? scheme.primary : null),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        if (current != null) TextButton(onPressed: () => Navigator.of(context).pop(none), child: const Text('No icon')),
      ],
    );
  }
}
