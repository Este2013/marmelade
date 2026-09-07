import 'dart:math' as math;

/// A colour matrix that turns every hue in an image by [degrees].
///
/// The coefficients are the SVG filter specification's `hueRotate` matrix,
/// which is the standard way to do this: it rotates around the luminance axis
/// using the Rec. 601 weights, so a rotated image keeps roughly the
/// brightness it had. A naive per-pixel conversion to HSL and back would not,
/// and a blurred backdrop that changes brightness with the palette style
/// would change how readable the text over it is.
///
/// Returned as the 20 values `ColorFilter.matrix` wants: four rows of five,
/// the fifth column being a constant offset this never needs.
List<double> hueRotation(double degrees) {
  final radians = degrees * math.pi / 180;
  final cos = math.cos(radians);
  final sin = math.sin(radians);

  return <double>[
    0.213 + cos * 0.787 - sin * 0.213,
    0.715 - cos * 0.715 - sin * 0.715,
    0.072 - cos * 0.072 + sin * 0.928,
    0,
    0,
    0.213 - cos * 0.213 + sin * 0.143,
    0.715 + cos * 0.285 + sin * 0.140,
    0.072 - cos * 0.072 - sin * 0.283,
    0,
    0,
    0.213 - cos * 0.213 - sin * 0.787,
    0.715 - cos * 0.715 + sin * 0.715,
    0.072 + cos * 0.928 + sin * 0.072,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];
}
