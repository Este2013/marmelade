import 'package:flutter/material.dart';

import '../../domain/search/smart_query.dart';

/// A field for a smart playlist's query, with what it means underneath.
///
/// The description is the whole point. A query language, however small, is a
/// thing you can be wrong about silently -- `year:>2020` and `year:2020` are one
/// character apart and mean different playlists -- so the field says back what
/// it understood, as it is typed.
class SmartQueryField extends StatefulWidget {
  const SmartQueryField({
    super.key,
    required this.controller,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  State<SmartQueryField> createState() => _SmartQueryFieldState();
}

class _SmartQueryFieldState extends State<SmartQueryField> {
  @override
  void initState() {
    super.initState();
    // The description follows the text, and a controller does not rebuild its
    // owner on its own.
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = widget.controller.text;
    final query = SmartQuery.parse(text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          autofocus: widget.autofocus,
          autocorrect: false,
          style: const TextStyle(fontFamily: 'Consolas'),
          decoration: const InputDecoration(
            labelText: 'Query',
            hintText: 'artist:Nanahira tag:hardcore -tag:remix added:<30d',
            border: OutlineInputBorder(),
          ),
          onSubmitted: widget.onSubmitted,
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              text.trim().isEmpty ? Icons.help_outline : Icons.subdirectory_arrow_right,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text.trim().isEmpty
                    ? 'Words search everything, including every artist credited '
                        'on a track. Fields narrow it: artist, album, title, '
                        'tag, year, rating, plays, added, played. A dash in '
                        'front of any of them excludes.'
                    : query.describe(),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
