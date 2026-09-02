import 'package:flutter/material.dart';

/// A section's icon and name, the way every browse view opens its own
/// toolbar in the merged title bar.
///
/// The icon repeats the one already shown for this destination in the
/// navigation rail -- a reminder of where the rail's selection landed, now
/// that the rail itself sits out of view to the left.
class SectionTitle extends StatelessWidget {
  const SectionTitle({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Text(label, style: theme.textTheme.titleLarge),
      ],
    );
  }
}
