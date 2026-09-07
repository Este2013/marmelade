import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/widgets/hue_filter.dart';

/// Turning the hue of an image.
///
/// The coefficients are the SVG specification's, and the reason to test them
/// is that a transposed digit produces something that still looks like a
/// colour -- just the wrong one, in a blurred backdrop nobody would think to
/// check against a reference.
void main() {
  /// Applies the matrix the way the compositor does.
  Color apply(List<double> m, Color c) {
    double channel(int row) => (m[row * 5] * c.r +
            m[row * 5 + 1] * c.g +
            m[row * 5 + 2] * c.b +
            m[row * 5 + 4])
        .clamp(0.0, 1.0);

    return Color.from(
      alpha: c.a,
      red: channel(0),
      green: channel(1),
      blue: channel(2),
    );
  }

  test('turning by nothing leaves every colour alone', () {
    // Which is what makes the default palette style free: the filter is not
    // applied at all, but the identity has to be an identity regardless.
    final identity = hueRotation(0);

    for (final colour in const [
      Color(0xFFE8730C),
      Color(0xFF3F51B5),
      Color(0xFF808080),
    ]) {
      final out = apply(identity, colour);
      expect(out.r, closeTo(colour.r, 0.01), reason: '$colour red');
      expect(out.g, closeTo(colour.g, 0.01), reason: '$colour green');
      expect(out.b, closeTo(colour.b, 0.01), reason: '$colour blue');
    }
  });

  test('a full turn comes back to where it started', () {
    final full = hueRotation(360);
    const colour = Color(0xFFE8730C);

    final out = apply(full, colour);
    expect(out.r, closeTo(colour.r, 0.02));
    expect(out.g, closeTo(colour.g, 0.02));
    expect(out.b, closeTo(colour.b, 0.02));
  });

  test('half a turn takes orange to the blue side', () {
    // The case the Swapped palette style uses. Marmalade orange is
    // red-dominant; its opposite has to be blue-dominant.
    final out = apply(hueRotation(180), const Color(0xFFE8730C));

    expect(out.b, greaterThan(out.r), reason: 'blue now leads');
    expect(HSLColor.fromColor(out).hue, greaterThan(180));
    expect(HSLColor.fromColor(out).hue, lessThan(260));
  });

  test('and keeps roughly the brightness it had', () {
    // The reason for a luminance-preserving matrix rather than a trip
    // through HSL: the scrim over this backdrop is tuned for a certain
    // brightness, and text readability rides on it.
    for (final colour in const [
      Color(0xFFE8730C),
      Color(0xFF3F51B5),
      Color(0xFF1B5E20),
    ]) {
      for (final degrees in const [60.0, 120.0, 180.0, 300.0]) {
        final out = apply(hueRotation(degrees), colour);
        expect(
          out.computeLuminance(),
          closeTo(colour.computeLuminance(), 0.12),
          reason: '$colour turned $degrees',
        );
      }
    }
  });

  test('grey has no hue to turn', () {
    final out = apply(hueRotation(180), const Color(0xFF808080));

    expect(out.r, closeTo(out.g, 0.02));
    expect(out.g, closeTo(out.b, 0.02));
  });
}
