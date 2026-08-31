import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The filter box each list carries in its toolbar.
///
/// Narrows what is already on screen, which is a different job from search:
/// search finds a thing anywhere in the library and takes you to it, this hides
/// the rows you are not working on. That is why it lives in the toolbar and
/// keeps its text when you navigate away and come back.
class FilterField extends StatefulWidget {
  const FilterField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.hint,
    this.width = 260,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String hint;

  /// Null lets it fill whatever it is given, which is how the toolbars use it:
  /// a fixed width plus a title plus two controls overflows the narrowest
  /// window this app allows.
  final double? width;

  @override
  State<FilterField> createState() => _FilterFieldState();
}

class _FilterFieldState extends State<FilterField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(FilterField old) {
    super.didUpdateWidget(old);
    // Only when something else changed it -- clearing from the selection bar,
    // or coming back to a view. Writing on every rebuild would fight the caret.
    if (widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            _controller.clear();
            widget.onChanged('');
          },
        },
        child: TextField(
          controller: _controller,
          onChanged: widget.onChanged,
          autocorrect: false,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.filter_alt_outlined, size: 18),
            prefixIconConstraints: const BoxConstraints(minWidth: 38),
            suffixIcon: widget.value.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear the filter',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      _controller.clear();
                      widget.onChanged('');
                    },
                    icon: const Icon(Icons.close, size: 16),
                  ),
            hintText: widget.hint,
            border: const OutlineInputBorder(),
          ),
        ),
      );

    return widget.width == null
        ? field
        : SizedBox(width: widget.width, child: field);
  }
}

/// The line shown when a filter has hidden everything.
class FilteredEmpty extends StatelessWidget {
  const FilteredEmpty({
    super.key,
    required this.query,
    required this.noun,
    required this.onClear,
  });

  final String query;
  final String noun;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.filter_alt_off_outlined,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text('No $noun matches "$query"', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'The filter narrows this list. Search finds things anywhere.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onClear, child: const Text('Clear')),
        ],
      ),
    );
  }
}
