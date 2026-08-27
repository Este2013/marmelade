import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme/theme_settings.dart';

/// Light or dark, and what colour the app is.
///
/// Both settings are applied the moment they are touched rather than behind a
/// Save: the result is the window you are looking at, so previewing it *is*
/// applying it.
class AppearanceSection extends ConsumerWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference = ref.watch(themeSettingsProvider);
    final settings = ref.read(themeSettingsProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return _Section(
      title: 'Appearance',
      children: [
        ListTile(
          leading: const Icon(Icons.brightness_6_outlined),
          title: const Text('Theme'),
          subtitle: Text(
            preference.mode == ThemeMode.system
                ? 'Follows the Windows light and dark setting.'
                : 'Always ${themeModeLabel(preference.mode).toLowerCase()}, '
                    'whatever Windows is doing.',
          ),
          trailing: SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: [
              for (final mode in ThemeMode.values)
                ButtonSegment(
                  value: mode,
                  label: Text(themeModeLabel(mode)),
                  icon: Icon(
                    switch (mode) {
                      ThemeMode.system => Icons.contrast,
                      ThemeMode.light => Icons.light_mode_outlined,
                      ThemeMode.dark => Icons.dark_mode_outlined,
                    },
                    size: 16,
                  ),
                ),
            ],
            selected: {preference.mode},
            onSelectionChanged: (selection) =>
                settings.setMode(selection.first),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Accent colour'),
          subtitle: Text(
            switch (preference.accent) {
              AccentSource.system =>
                'Taken from the Windows accent colour, so the app matches the '
                    'desktop around it.',
              AccentSource.brand => "marmelade's own orange.",
              AccentSource.custom => 'A colour picked below.',
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _SourceChip(
                label: AccentSource.system.label,
                selected: preference.accent == AccentSource.system,
                onSelected: () => settings.setAccent(AccentSource.system),
              ),
              _SourceChip(
                label: AccentSource.brand.label,
                selected: preference.accent == AccentSource.brand,
                onSelected: () => settings.setAccent(AccentSource.brand),
              ),
              Container(
                width: 1,
                height: 26,
                color: scheme.outlineVariant,
              ),
              for (final choice in accentChoices)
                _Swatch(
                  name: choice.name,
                  color: choice.color,
                  selected: preference.accent == AccentSource.custom &&
                      preference.customAccent.toARGB32() ==
                          choice.color.toARGB32(),
                  onTap: () => settings.setCustomAccent(choice.color),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 0, 16, 16),
          child: Text(
            'Every colour here is one Material can build a readable palette '
            'from, in both light and dark. That is why it is a set rather '
            'than a colour wheel.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// One of the two non-colour sources.
class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onSelected(),
      );
}

/// One pickable colour.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: name,
      child: Semantics(
        button: true,
        selected: selected,
        label: name,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.onSurface : scheme.outlineVariant,
                width: selected ? 3 : 1,
              ),
            ),
            child: selected
                ? Icon(
                    Icons.check,
                    size: 16,
                    // Against the swatch, not against the page.
                    color: ThemeData.estimateBrightnessForColor(color) ==
                            Brightness.dark
                        ? Colors.white
                        : Colors.black,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// A titled group, matching the rest of the settings page.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(title, style: theme.textTheme.titleMedium),
        ),
        Card(
          color: theme.colorScheme.surfaceContainerLow,
          child: Column(children: children),
        ),
      ],
    );
  }
}
