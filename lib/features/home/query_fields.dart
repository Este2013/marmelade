import 'package:flutter/material.dart';

import '../../data/db/enums.dart';
import '../playlists/smart_query_field.dart';

/// The three halves of a search: what to find, what makes a match, and what
/// order to put the answers in.
///
/// One widget rather than two copies, because the add dialog and the rule
/// editor inside a collection are asking the same question and any drift
/// between them would be a difference nobody meant.
class QueryFields extends StatelessWidget {
  const QueryFields({
    super.key,
    required this.controller,
    required this.titleController,
    required this.type,
    required this.sort,
    required this.onTypeChanged,
    required this.onSortChanged,
    required this.inverted,
    required this.onInvertedChanged,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;

  /// The search's own name. Optional: left empty, the tile and the block
  /// header print the rule instead, which is the only honest thing to call
  /// a search nobody has named.
  final TextEditingController titleController;
  final HomeQueryType type;
  final HomeQuerySort sort;
  final ValueChanged<HomeQueryType> onTypeChanged;
  final ValueChanged<HomeQuerySort> onSortChanged;

  /// Whether [sort] runs backwards.
  final bool inverted;
  final ValueChanged<bool> onInvertedChanged;
  final bool autofocus;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allowed = HomeQuerySort.forType(type);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Type first, because it is the first half of the sentence the fields
        // make together: "Albums where tag:hardcore". Reading it the other way
        // round leaves you writing a filter without knowing what it filters.
        DropdownMenu<HomeQueryType>(
          initialSelection: type,
          label: const Text('Find'),
          expandedInsets: EdgeInsets.zero,
          requestFocusOnTap: false,
          onSelected: (chosen) {
            if (chosen == null) return;
            onTypeChanged(chosen);
            // The orders that mean something depend on the type, so a sort
            // the new type cannot obey falls back rather than being silently
            // kept and silently ignored.
            if (!HomeQuerySort.forType(chosen).contains(sort)) {
              onSortChanged(HomeQuerySort.matched);
            }
          },
          dropdownMenuEntries: [
            for (final one in HomeQueryType.values)
              DropdownMenuEntry(value: one, label: one.label),
          ],
        ),
        const SizedBox(height: 12),
        SmartQueryField(
          controller: controller,
          autofocus: autofocus,
          onSubmitted: (_) => onSubmitted?.call(),
        ),
        const SizedBox(height: 12),
        // The direction sits beside the order rather than inside it: every
        // order has an opposite, and spelling both into the menu would
        // double its length to say what one button says.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DropdownMenu<HomeQuerySort>(
                // Keyed to the type: the entries change with it, and without
                // a key the menu keeps showing the label of an option it no
                // longer has.
                key: ValueKey(type),
                initialSelection:
                    allowed.contains(sort) ? sort : HomeQuerySort.matched,
                label: const Text('Sorted by'),
                expandedInsets: EdgeInsets.zero,
                requestFocusOnTap: false,
                onSelected: (chosen) =>
                    onSortChanged(chosen ?? HomeQuerySort.matched),
                dropdownMenuEntries: [
                  for (final one in allowed)
                    DropdownMenuEntry(value: one, label: one.label),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _InvertButton(
              sort: sort,
              inverted: inverted,
              onChanged: onInvertedChanged,
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: titleController,
          decoration: const InputDecoration(
            labelText: 'Query title',
            hintText: 'Optional. Without one it shows the rule itself.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _explain(type) +
              (inverted && sort.canInvert
                  ? ' Reversed: ${sort.invertedLabel.toLowerCase()}.'
                  : ''),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// What the chosen type actually returns.
  ///
  /// Worth spelling out because the rule and the answer are different kinds of
  /// thing: every rule describes a song, and the type decides what that song
  /// stands for.
  static String _explain(HomeQueryType type) => switch (type) {
        HomeQueryType.track => 'The songs that match.',
        HomeQueryType.any =>
          'Everything the rule implies: the albums, then the artists, then '
              'the songs.',
        _ => 'The ${type.label.toLowerCase()} holding a song that matches. '
            'The rule itself always describes a song -- this is what comes '
            'back.',
      };
}

/// Turns the chosen order around.
///
/// Sized and boxed to line up with the field beside it: a `DropdownMenu` is
/// 56 high with its label above the line, and a bare `IconButton` next to one
/// floats in the middle of that instead of sitting on the same baseline.
class _InvertButton extends StatelessWidget {
  const _InvertButton({
    required this.sort,
    required this.inverted,
    required this.onChanged,
  });

  final HomeQuerySort sort;
  final bool inverted;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // Shuffled is the one order with no opposite, so the button says so
    // rather than offering to do nothing. Disabled by not being given a
    // callback would be the obvious way, but a toggle that flips between
    // enabled and disabled as the menu beside it changes is exactly the
    // thing Windows' accessibility bridge mishandles -- see the same note
    // on the rail buttons. It stays live and reports the reason instead.
    final can = sort.canInvert;
    final tooltip = can
        ? (inverted
            ? 'Reversed: ${sort.invertedLabel.toLowerCase()}'
            : 'Reverse the order')
        : 'A shuffle has no reverse';

    return SizedBox(
      height: 56,
      width: 56,
      child: Tooltip(
        message: tooltip,
        child: IconButton.filledTonal(
          isSelected: can && inverted,
          onPressed: () => onChanged(can && !inverted),
          icon: const Icon(Icons.swap_vert),
          style: can
              ? null
              : IconButton.styleFrom(
                  foregroundColor:
                      Theme.of(context).disabledColor,
                ),
        ),
      ),
    );
  }
}
