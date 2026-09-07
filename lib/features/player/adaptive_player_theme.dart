import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// Wraps [child] in the colours of whatever is playing.
///
/// Off unless asked for, and a matter of taste rather than a straightforwardly
/// better idea: a strongly coloured sleeve makes a strongly coloured player.
///
/// The tinted theme is the ambient theme with a different colour scheme, never
/// a theme built from scratch. A fresh `ThemeData` carries its own text styles
/// -- plain, `inherit: true` -- where the app's are merged and
/// `inherit: false`, and `TextStyle.lerp` refuses to interpolate across that:
/// building one here threw "Failed to interpolate TextStyles with different
/// inherit values" and replaced the player with an error widget on the first
/// album change. Sharing one `textTheme` leaves nothing to disagree about, and
/// the colours are all that needed to change.
class AdaptivePlayerTheme extends ConsumerWidget {
  const AdaptivePlayerTheme({super.key, required this.child});

  final Widget child;

  /// The same 320ms the artwork itself cross-fades over, so skipping through a
  /// queue does not strobe a different colour per track.
  static const fade = Duration(milliseconds: 320);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final artwork = ref.watch(playerProvider.select((s) => s.current?.imagePath));

    final tinted = ref.watch(adaptivePlayerColorsProvider) && artwork != null
        ? ref
            .watch(artworkSchemeProvider(
              (path: artwork, brightness: theme.brightness),
            ))
            .value
        : null;

    // A null scheme falls back to the app's own, so turning the setting off,
    // or reaching a track with no picture, fades back rather than snapping.
    return AnimatedTheme(
      duration: fade,
      data: tinted == null ? theme : theme.copyWith(colorScheme: tinted),
      child: child,
    );
  }
}
