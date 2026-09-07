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
                  icon: Icon(switch (mode) {
                    ThemeMode.system => Icons.contrast,
                    ThemeMode.light => Icons.light_mode_outlined,
                    ThemeMode.dark => Icons.dark_mode_outlined,
                  }, size: 16),
                ),
            ],
            selected: {preference.mode},
            onSelectionChanged: (selection) => settings.setMode(selection.first),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.contrast_outlined),
          title: const Text('Contrast'),
          subtitle: Text(switch (preference.contrast) {
            ContrastLevel.muted =>
              'Softer than the default, for a dim room.',
            ContrastLevel.normal => "Material's normal contrast.",
            ContrastLevel.high => 'A wider gap between text and what is '
                'behind it.',
            ContrastLevel.highest => 'As far apart as the palette goes: '
                'near-black on near-white, or the reverse.',
          }),
          trailing: SegmentedButton<ContrastLevel>(
            showSelectedIcon: false,
            segments: [
              for (final level in ContrastLevel.values)
                ButtonSegment(value: level, label: Text(level.label)),
            ],
            selected: {preference.contrast},
            onSelectionChanged: (selection) =>
                settings.setContrast(selection.first),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.gradient_outlined),
          title: const Text('Palette style'),
          subtitle: Text(switch (preference.variant) {
            PaletteVariant.tonalSpot =>
              "Material's default: gentle palettes at a fixed saturation, "
                  'whatever the accent.',
            PaletteVariant.fidelity =>
              "Keeps the accent's own saturation, so a muted colour gives a "
                  'muted theme. Third colour is its complement.',
            PaletteVariant.vibrant => 'Saturation at maximum. Loud.',
            PaletteVariant.expressive =>
              'Medium saturation, with the main hue shifted off the accent '
                  'for variety.',
            PaletteVariant.neutral => 'Barely coloured at all.',
            PaletteVariant.monochrome => 'Grey. No colour anywhere.',
            PaletteVariant.rainbow =>
              "Playful: the accent's hue does not appear in the theme.",
            PaletteVariant.fruitSalad => 'The other playful one.',
            PaletteVariant.swapped =>
              "Built from the accent's opposite: the colour half a turn "
                  'round the wheel leads the whole interface.',
          }),
          // Material 3's dropdown, not the older DropdownButton: this one is
          // a menu anchored to a field, sized rather than sized-to-content,
          // which is what keeps a nine-item list from setting the width of
          // the whole settings row.
          trailing: SizedBox(
            width: 200,
            child: DropdownMenu<PaletteVariant>(
              // Re-applied when it changes, which is what keeps this in step
              // with the stored setting rather than only its first value.
              initialSelection: preference.variant,
              requestFocusOnTap: false,
              enableSearch: false,
              inputDecorationTheme: const InputDecorationTheme(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              dropdownMenuEntries: [
                for (final variant in PaletteVariant.values)
                  DropdownMenuEntry(value: variant, label: variant.label),
              ],
              onSelected: (variant) {
                if (variant != null) settings.setVariant(variant);
              },
            ),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.blur_on_outlined),
          title: const Text('Turn artwork with the palette'),
          subtitle: const Text(
            'The blurred cover behind the now-playing view, and behind album '
            'and artist pages, turns its colours the same way the palette '
            'style turns the accent. Only does anything for a style that '
            'turns the hue -- Swapped, at the moment.',
          ),
          value: ref.watch(backdropFollowsPaletteProvider),
          onChanged: (value) =>
              ref.read(backdropFollowsPaletteProvider.notifier).set(value),
        ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Accent colour'),
          subtitle: Text(switch (preference.accent) {
            AccentSource.system =>
              'Taken from the Windows accent colour, so the app matches the '
                  'desktop around it.',
            AccentSource.adaptive =>
              'Taken from the artwork of whatever is playing -- the whole '
                  'interface, player included. Falls back to the Windows '
                  'accent when nothing is loaded.',
            AccentSource.custom => 'A colour picked below.',
          }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _SourceChip(label: AccentSource.system.label, selected: preference.accent == AccentSource.system, onSelected: () => settings.setAccent(AccentSource.system)),
              _SourceChip(label: AccentSource.adaptive.label, selected: preference.accent == AccentSource.adaptive, onSelected: () => settings.setAccent(AccentSource.adaptive)),
              Container(width: 1, height: 26, color: scheme.outlineVariant),
              for (final choice in accentChoices)
                _Swatch(
                  name: choice.name,
                  color: choice.color,
                  selected: preference.accent == AccentSource.custom && preference.customAccent.toARGB32() == choice.color.toARGB32(),
                  onTap: () => settings.setCustomAccent(choice.color),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One of the two non-colour sources.
class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.label, required this.selected, required this.onSelected});

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => ChoiceChip(label: Text(label), selected: selected, onSelected: (_) => onSelected());
}

/// One pickable colour.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.name, required this.color, required this.selected, required this.onTap});

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
              border: Border.all(color: selected ? scheme.onSurface : scheme.outlineVariant, width: selected ? 3 : 1),
            ),
            child: selected
                ? Icon(
                    Icons.check,
                    size: 16,
                    // Against the swatch, not against the page.
                    color: ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black,
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
