/// Reference implementation of the colour-science the native encoders apply
/// per pixel (`darwin/Classes/HdrVideoEncoderPlugin.m`,
/// `android/.../HdrVideoEncoderPlugin.kt`). The native code has its own copy of
/// these formulas/constants for performance; **keep them in sync** and rely on
/// `test/hdr_color_math_test.dart` to catch transcription errors.
library;

import 'dart:math' as math;

/// BT.2408 reference diffuse white in nits. Unboosted SDR white maps here on
/// the PQ path.
const double kSdrWhiteNits = 203.0;

/// Scene-linear value that unboosted SDR white maps to on the HLG curve.
///
/// Scene-linear value that unboosted SDR white maps to on the HLG curve.
///
/// Scene-linear value that unboosted SDR white maps to on the HLG curve. Above
/// the BT.2408 reference-white value (0.26496 = signal 0.75) at 0.5: non-glowing
/// white lands HLG signal ~0.87 (~435 nits on a direct HLG display), which reads
/// brighter in an ffmpeg-style HLG->SDR preview. The phone's adaptive tone-map
/// absorbs the anchor anyway — the on-phone look comes from the inverse-OOTF
/// factor, not this value.
const double kHlgSdrWhiteScene = 0.5;

/// sRGB EOTF: gamma-encoded [0,1] → linear [0,1].
double srgbToLinear(double c) {
  if (c <= 0.04045) return c / 12.92;
  return math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

/// Rec.709 linear → Rec.2020 linear (BT.2087). Returns `[r, g, b]`.
List<double> lin709ToLin2020(double r, double g, double b) => [
  0.62740 * r + 0.32930 * g + 0.04330 * b,
  0.06910 * r + 0.91950 * g + 0.01140 * b,
  0.01640 * r + 0.08800 * g + 0.89560 * b,
];

/// Rec.709 linear → Display-P3 linear (D65). Returns `[r, g, b]`.
List<double> lin709ToLinP3(double r, double g, double b) => [
  0.822462 * r + 0.177538 * g,
  0.033194 * r + 0.966806 * g,
  0.017083 * r + 0.072397 * g + 0.910520 * b,
];

/// PQ OETF (SMPTE ST 2084 / BT.2100). [l] is display-linear normalised so
/// `1.0 == 10000 nits`. Returns the non-linear signal in [0,1].
double pqOetf(double l) {
  final L = l < 0.0 ? 0.0 : l;
  const m1 = 0.1593017578125;
  const m2 = 78.84375;
  const c1 = 0.8359375;
  const c2 = 18.8515625;
  const c3 = 18.6875;
  final lp = math.pow(L, m1).toDouble();
  return math.pow((c1 + c2 * lp) / (1.0 + c3 * lp), m2).toDouble();
}

/// HLG OETF (BT.2100). [e] is scene-linear in [0,1] (`1.0 == HLG peak`).
double hlgOetf(double e) {
  final E = e.clamp(0.0, 1.0);
  const a = 0.17883277;
  const b = 0.28466892;
  const c = 0.55991073;
  if (E <= 1.0 / 12.0) return math.sqrt(3.0 * E);
  return a * math.log(12.0 * E - b) + c;
}

/// `smoothstep(edge0, edge1, x)` — 0 below edge0, 1 above edge1, Hermite in
/// between. Used for the glow knee.
double smoothstep(double edge0, double edge1, double x) {
  if (edge1 <= edge0) return x < edge0 ? 0.0 : 1.0;
  final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

/// HDR "glow" factor for a pixel, driven by its *whiteness* [whiteness] — the
/// min of its sRGB channels (0..1), i.e. how much achromatic/white content the
/// colour has. 1.0 below [knee], ramping to [maxBoost] at white. Using the min
/// channel (not the max, not luma) means a saturated colour with one maxed
/// channel — pure amber `(255,202,40)`, pure red — does NOT glow, only genuinely
/// near-white pixels do. One factor for the whole pixel (applied to all
/// channels) so the glow only changes brightness, never hue. A pure function of
/// how the pixel *looks* in SDR — same SDR value always maps to the same HDR
/// value.
double glowFactor(double whiteness, double knee, double maxBoost) {
  return 1.0 + smoothstep(knee, 1.0, whiteness) * (maxBoost - 1.0);
}

/// The full per-pixel transform the native side does: sRGB8 → the target
/// transfer function's non-linear RGB, with the [glowFactor] applied uniformly
/// in linear light. [knee] is the sRGB value where the glow starts (1.0 ==
/// [maxBoost] == no glow). [transfer] is `'hlg'`, `'pq'` or `'sdrRec709'`;
/// [primaries] is `'rec2020'`, `'displayP3'` or `'rec709'`.
List<double> encodePixel({
  required double r8,
  required double g8,
  required double b8,
  double knee = 0.7,
  double maxBoost = 1.0,
  double saturation = 1.0,
  String transfer = 'hlg',
  String primaries = 'rec2020',
  double maxContentLightLevelNits = 0.0,
  // PQ anchor: the absolute nits an unboosted (k==1) SDR white maps to.
  // Defaults to the BT.2408 reference value; raising it brightens the WHOLE
  // frame uniformly (glowing and non-glowing pixels alike) — unlike
  // [maxBoost], which only affects pixels above [knee].
  double sdrWhiteNits = kSdrWhiteNits,
}) {
  if (transfer == 'sdrRec709') {
    return [r8 / 255.0, g8 / 255.0, b8 / 255.0];
  }
  final sr = r8 / 255.0, sg = g8 / 255.0, sb = b8 / 255.0;
  final k = glowFactor(math.min(sr, math.min(sg, sb)), knee, maxBoost);
  var r = srgbToLinear(sr) * k;
  var g = srgbToLinear(sg) * k;
  var b = srgbToLinear(sb) * k;

  // Optional saturation nudge, in linear light around the pixel's luma. A phone
  // renders HDR video less vividly than its SDR "vivid" mode; a small boost
  // (~1.1) pulls the on-screen colour back toward the SDR look. Luma-preserving,
  // so it changes only saturation, not brightness.
  if (saturation != 1.0) {
    final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    r = y + saturation * (r - y);
    g = y + saturation * (g - y);
    b = y + saturation * (b - y);
  }

  if (primaries == 'rec2020') {
    final t = lin709ToLin2020(r, g, b);
    r = t[0];
    g = t[1];
    b = t[2];
  } else if (primaries == 'displayP3') {
    final t = lin709ToLinP3(r, g, b);
    r = t[0];
    g = t[1];
    b = t[2];
  }

  if (transfer == 'pq') {
    final lim = maxContentLightLevelNits > 0 ? maxContentLightLevelNits : 10000.0;
    return [
      pqOetf(math.min(r * sdrWhiteNits, lim) / 10000.0),
      pqOetf(math.min(g * sdrWhiteNits, lim) / 10000.0),
      pqOetf(math.min(b * sdrWhiteNits, lim) / 10000.0),
    ];
  }
  // Inverse OOTF: a phone renders HLG through an effective system gamma that
  // crushes mid-tones/shadows below their SDR appearance. Undo it with one
  // luma-driven factor (white -> 1.0) so hue is untouched. Exponent -(g-1)/g;
  // g = 1.5 (-1/3) — tuned up from the 1.2 reference for the test phone.
  final yl = 0.2627 * r + 0.6780 * g + 0.0593 * b; // BT.2020 luma
  final comp = math.min(math.pow(math.max(yl, 1e-4), -1.0 / 3.0).toDouble(), 2.5);
  return [
    hlgOetf(r * comp * kHlgSdrWhiteScene),
    hlgOetf(g * comp * kHlgSdrWhiteScene),
    hlgOetf(b * comp * kHlgSdrWhiteScene),
  ];
}
