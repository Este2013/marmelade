import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme/theme_settings.dart';
import '../../widgets/artwork.dart' show ArtworkFilterQuality;

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

          trailing: SegmentedButton<ContrastLevel>(
            showSelectedIcon: false,
            segments: [for (final level in ContrastLevel.values) ButtonSegment(value: level, label: Text(level.label))],
            selected: {preference.contrast},
            onSelectionChanged: (selection) => settings.setContrast(selection.first),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.gradient_outlined),
          title: const Text('Palette style'),
          subtitle: Text(switch (preference.variant) {
            PaletteVariant.tonalSpot => "Gentle palettes at a fixed saturation.",
            PaletteVariant.fidelity => "Keeps the accent's own saturation through the palette.",
            PaletteVariant.vibrant => 'Maximum saturation!',
            PaletteVariant.expressive => 'Medium saturation, with the main hue shifted off the accent for variety.',
            PaletteVariant.neutral => 'Barely coloured at all.',
            PaletteVariant.monochrome => 'Grey. No colour anywhere.',
            PaletteVariant.rainbow => "Playful: the accent's hue does not appear in the theme.",
            PaletteVariant.fruitSalad => 'What even is happening here?',
            PaletteVariant.swapped => "Inverting the hues to complement the accent color.",
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
              inputDecorationTheme: const InputDecorationTheme(isDense: true, border: OutlineInputBorder()),
              dropdownMenuEntries: [for (final variant in PaletteVariant.values) DropdownMenuEntry(value: variant, label: variant.label)],
              onSelected: (variant) {
                if (variant != null) settings.setVariant(variant);
              },
            ),
          ),
        ),
        // Only while the chosen style has somewhere to turn the picture.
        // Swapped rotates the seed outright; the playful styles and
        // expressive land elsewhere by a route of their own, which is
        // measurable but only when the palette came from the artwork in the
        // first place. Anywhere else this would be a control with nothing on
        // the other end of it.
        if (preference.variant.hueShift != 0 || (preference.variant.movesHueItself && preference.accent == AccentSource.adaptive))
          SwitchListTile(
            secondary: const Icon(Icons.blur_on_outlined),
            title: const Text('Turn artwork with the palette'),
            subtitle: Text(
              preference.variant.hueShift != 0
                  ? 'Shift the artwork\'s hue ${preference.variant.hueShift.round()} degrees to match the palette style.'
                  : 'This style lands on its own hue, so the blurred cover '
                        'turns to meet it -- by however far it moved, which '
                        'depends on the record.',
            ),
            value: ref.watch(backdropFollowsPaletteProvider),
            onChanged: (value) => ref.read(backdropFollowsPaletteProvider.notifier).set(value),
          ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Accent colour'),
          subtitle: Text(switch (preference.accent) {
            AccentSource.system => 'Match your desktop environment.',
            AccentSource.adaptive => 'Match the currently playing song.',
            AccentSource.custom => 'Pick your own color.',
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
        const Divider(height: 1),
        const _ArtworkRenderingTile(),
      ],
    );
  }
}

/// Testing knobs for a cover that looks softer than it should.
///
/// Not a fix in itself -- both of these trade something (CPU, memory) for a
/// chance at a sharper picture -- but a report of blurry artwork on one
/// monitor and not another cannot be chased from here, and these are the two
/// places a monitor-dependent resampling difference could actually live: how
/// hard the resample tries, and whether it runs at all before the codec's
/// own decode-time downscale gets there first.
class _ArtworkRenderingTile extends ConsumerWidget {
  const _ArtworkRenderingTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(artworkRenderSettingsProvider);
    final notifier = ref.read(artworkRenderSettingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.deblur_outlined),
          title: const Text('Artwork resampling'),
          subtitle: const Text('How much resharpening is applied to images when resized.\nImages will look sharper at the cost of more computing.'),
          trailing: SegmentedButton<ArtworkFilterQuality>(
            showSelectedIcon: false,
            segments: [for (final quality in ArtworkFilterQuality.values) ButtonSegment(value: quality, label: Text(quality.label))],
            selected: {settings.filterQuality},
            onSelectionChanged: (selection) => notifier.setFilterQuality(selection.first),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.hd_outlined),
          title: const Text('Decode artwork at full resolution'),
          subtitle: const Text('Images will look sharper at the cost of using more memory.'),
          value: settings.decodeAtFullResolution,
          onChanged: notifier.setFullResolution,
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
