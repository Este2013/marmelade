import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'time_text.dart';

/// Which list a selection belongs to.
///
/// Separate selections per list, because selecting three albums and then
/// switching to Songs should not leave three songs mysteriously selected.
enum SelectionScope { albums, songs, artists }

/// What is selected in one list.
///
/// Ctrl-click toggles, Shift-click extends from the last thing touched, and a
/// plain click does whatever the list normally does -- open the album, play the
/// song -- and clears the selection. Keeping plain click on its existing
/// behaviour matters: this app has always opened things with one click, and
/// turning that into "select" would break every habit for the sake of a feature
/// that Ctrl already covers.
class Selection {
  const Selection({this.ids = const {}, this.anchor});

  final Set<int> ids;

  /// The last id touched, which is where a Shift-click measures from.
  final int? anchor;

  bool get isEmpty => ids.isEmpty;
  bool get isNotEmpty => ids.isNotEmpty;
  int get length => ids.length;
  bool contains(int id) => ids.contains(id);
}

class SelectionController extends Notifier<Selection> {
  @override
  Selection build() => const Selection();

  void clear() {
    if (state.isEmpty) return;
    state = const Selection();
  }

  /// Ctrl-click: adds or removes one.
  void toggle(int id) {
    final next = state.ids.toSet();
    if (!next.remove(id)) next.add(id);
    state = Selection(ids: next, anchor: id);
  }

  /// Selects exactly one thing.
  void only(int id) => state = Selection(ids: {id}, anchor: id);

  /// Shift-click: everything between the anchor and [id], in list order.
  ///
  /// [order] is the ids as the list currently shows them, because "between"
  /// means between on screen -- not between by id, which after any sort has
  /// nothing to do with what someone is looking at.
  void extendTo(int id, List<int> order) {
    final anchor = state.anchor;
    if (anchor == null) {
      only(id);
      return;
    }
    final from = order.indexOf(anchor);
    final to = order.indexOf(id);
    if (from < 0 || to < 0) {
      only(id);
      return;
    }
    final range = from <= to
        ? order.sublist(from, to + 1)
        : order.sublist(to, from + 1);
    // Added to what is already selected rather than replacing it, so
    // ctrl-picking a few and then shift-extending one of them behaves.
    state = Selection(ids: {...state.ids, ...range}, anchor: anchor);
  }

  void selectAll(List<int> order) {
    if (order.isEmpty) return;
    state = Selection(ids: order.toSet(), anchor: order.last);
  }
}

final selectionProvider =
    NotifierProvider.family<SelectionController, Selection, SelectionScope>(
  (_) => SelectionController(),
);

/// How a click was modified.
enum ClickIntent { open, toggle, extend }

/// Reads the modifier keys held right now.
///
/// Read at the moment of the tap rather than tracked continuously: a key that
/// is pressed and released between frames would otherwise be missed, and
/// tracking it means listening to every key event in the app.
ClickIntent clickIntent() {
  final pressed = HardwareKeyboard.instance.logicalKeysPressed;
  final shift = pressed.contains(LogicalKeyboardKey.shiftLeft) ||
      pressed.contains(LogicalKeyboardKey.shiftRight);
  final control = pressed.contains(LogicalKeyboardKey.controlLeft) ||
      pressed.contains(LogicalKeyboardKey.controlRight);

  // Shift wins when both are held, which is what every file manager does.
  if (shift) return ClickIntent.extend;
  if (control) return ClickIntent.toggle;
  return ClickIntent.open;
}

/// Applies a click to a selection, and says whether the list should act.
///
/// Returns true when the caller should do its normal thing -- open, play --
/// which is only the case for an unmodified click.
bool applyClick(
  WidgetRef ref,
  SelectionScope scope,
  int id,
  List<int> order,
) {
  final controller = ref.read(selectionProvider(scope).notifier);
  switch (clickIntent()) {
    case ClickIntent.toggle:
      controller.toggle(id);
      return false;
    case ClickIntent.extend:
      controller.extendTo(id, order);
      return false;
    case ClickIntent.open:
      controller.clear();
      return true;
  }
}

/// Prepares a right-click: selects the item unless it is already selected.
///
/// Right-clicking something outside the selection acts on that thing alone,
/// which is what every list does; right-clicking inside the selection keeps it,
/// so a menu opened on one of five selected rows acts on all five.
void prepareContextMenu(WidgetRef ref, SelectionScope scope, int id) {
  final selection = ref.read(selectionProvider(scope));
  if (selection.contains(id)) return;
  ref.read(selectionProvider(scope).notifier).only(id);
}

/// One entry in a context menu.
class MenuAction {
  const MenuAction({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.isDestructive = false,
  });

  /// A divider.
  const MenuAction.separator()
      : label = '',
        icon = null,
        onSelected = null,
        isDestructive = false;

  final String label;
  final IconData? icon;
  final VoidCallback? onSelected;
  final bool isDestructive;

  bool get isSeparator => onSelected == null && icon == null;
}

/// Shows a context menu at the pointer.
Future<void> showItemMenu(
  BuildContext context,
  Offset position,
  List<MenuAction> actions,
) async {
  final overlay =
      Overlay.of(context).context.findRenderObject()! as RenderBox;
  final scheme = Theme.of(context).colorScheme;

  final chosen = await showMenu<VoidCallback>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(position.dx, position.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final action in actions)
        if (action.isSeparator)
          const PopupMenuDivider()
        else
          PopupMenuItem<VoidCallback>(
            value: action.onSelected,
            child: Row(
              // Sized to its content, with the label allowed to ellipsize: a
              // menu row is as wide as its longest label, and a Row that takes
              // the whole menu overflows the moment a label is long.
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  action.icon,
                  size: 18,
                  color: action.isDestructive ? scheme.error : null,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    action.label,
                    overflow: TextOverflow.ellipsis,
                    style: action.isDestructive
                        ? TextStyle(color: scheme.error)
                        : null,
                  ),
                ),
              ],
            ),
          ),
    ],
  );
  chosen?.call();
}

/// Wraps a row or tile so it responds to modified clicks and right-clicks.
class SelectableItem extends ConsumerWidget {
  const SelectableItem({
    super.key,
    required this.scope,
    required this.id,
    required this.order,
    required this.child,
    required this.onOpen,
    required this.menu,
    this.borderRadius = 8,
  });

  final SelectionScope scope;
  final int id;

  /// The ids in the order the list shows them, for Shift-click.
  final List<int> order;

  final Widget child;

  /// What an unmodified click does.
  final VoidCallback onOpen;

  /// Built when the menu opens, so it can read the selection as it is then.
  final List<MenuAction> Function() menu;

  final double borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(
      selectionProvider(scope).select((s) => s.contains(id)),
    );
    final scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () {
        if (applyClick(ref, scope, id, order)) onOpen();
      },
      onSecondaryTapUp: (details) {
        prepareContextMenu(ref, scope, id);
        showItemMenu(context, details.globalPosition, menu());
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
          ),
        ),
        child: child,
      ),
    );
  }
}

/// The bar that appears while something is selected.
class SelectionBar extends ConsumerWidget {
  const SelectionBar({
    super.key,
    required this.scope,
    required this.noun,
    required this.actions,
    this.onSelectAll,
  });

  final SelectionScope scope;

  /// What the selected things are called, singular.
  final String noun;

  final List<MenuAction> actions;
  final VoidCallback? onSelectAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider(scope));
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Absent, not merely invisible, when nothing is selected: an empty bar
    // holding disabled buttons is a row of interactive nodes about nothing.
    if (selection.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Text(
            '${pluralize(selection.length, noun)} selected',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: 16),
          if (onSelectAll != null)
            TextButton(
              onPressed: onSelectAll,
              child: const Text('Select all'),
            ),
          const Spacer(),
          for (final action in actions)
            if (!action.isSeparator)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: TextButton.icon(
                  onPressed: action.onSelected,
                  icon: Icon(action.icon, size: 18),
                  label: Text(action.label),
                ),
              ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Clear the selection',
            onPressed: ref.read(selectionProvider(scope).notifier).clear,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
