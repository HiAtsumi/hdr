import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';

/// Reference colour-science matching the native encoders (see the library doc).
import 'src/hdr_color_math.dart';
export 'src/hdr_color_math.dart';

/// Transfer function (EOTF/OETF) the encoded video is authored in.
enum HdrTransfer {
  /// Plain SDR gamma (BT.709). The frames are written into a 10-bit HEVC
  /// container but carry no extra dynamic range — used as a de-risking
  /// checkpoint (milestone M1) to prove the 10-bit muxing/share path.
  sdrRec709,

  /// Hybrid Log-Gamma (BT.2100 HLG). No static metadata required; degrades
  /// gracefully to SDR on non-HDR players. Default.
  hlg,

  /// Perceptual Quantizer (BT.2100 PQ / SMPTE ST 2084). Absolute-luminance;
  /// pairs with [maxContentLightLevel] / [maxFrameAverageLightLevel] metadata.
  pq,
}

/// Colour primaries the encoded video is authored in.
enum HdrPrimaries { rec709, displayP3, rec2020 }

/// Result of [HdrVideoEncoder.probe].
class HdrCapability {
  const HdrCapability({required this.supported, this.reason});

  /// Whether this device can encode HDR HEVC Main10.
  final bool supported;

  /// Human-readable reason when [supported] is false (e.g. "no Main10 encoder").
  final String? reason;

  @override
  String toString() => 'HdrCapability(supported: $supported, reason: $reason)';
}

/// Native HDR video encoder. Mirrors the shape of `FlutterQuickVideoEncoder`
/// (`setup` → repeated `appendFrame` → `finish`) but produces an HDR HEVC
/// Main10 mp4 from one 8-bit sRGB RGBA8888 frame per call.
///
/// The HDR "glow" is a pure per-pixel function of the SDR frame — no separate
/// mask. Native does, once per pixel:
/// `w = min(r,g,b)/255; k = 1 + smoothstep(knee, 1, w) * (maxBoost - 1);`
/// `lin = srgbToLinear(c/255) * k` for each channel — one factor `k` driven by
/// the pixel's *whiteness* (min channel) so a saturated colour with a maxed
/// channel (pure amber, pure red) does not glow, only near-white pixels do, and
/// the glow never shifts hue. Then an optional Rec.709→primaries matrix, the
/// [transfer] OETF, and RGBA-half (iOS/macOS) / P010 (Android) to the hardware
/// encoder with the matching colour-volume tags. Because the glow depends only
/// on how the pixel *looks*, two things that are identical in SDR are identical
/// in HDR.
class HdrVideoEncoder {
  HdrVideoEncoder._();

  static const MethodChannel _channel = MethodChannel('hdr_video_encoder/methods');

  static int _width = 0;
  static int _height = 0;

  /// Whether the plugin has a native implementation on this platform at all
  /// (iOS/macOS/Android). This does NOT check HDR encoder capability — call
  /// [probe] for that.
  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.android:
        return true;
      default:
        return false;
    }
  }

  /// Asks the OS whether an HDR (HEVC Main10) encoder is actually available.
  /// Safe to call on any platform; returns `supported: false` off-platform.
  static Future<HdrCapability> probe() async {
    if (!isSupportedPlatform) {
      return const HdrCapability(
        supported: false,
        reason: 'HDR export is only available on iOS, macOS and Android',
      );
    }
    try {
      final res = await _channel.invokeMapMethod<String, Object?>('probe');
      return HdrCapability(
        supported: (res?['supported'] as bool?) ?? false,
        reason: res?['reason'] as String?,
      );
    } on PlatformException catch (e) {
      return HdrCapability(supported: false, reason: e.message ?? e.code);
    } on MissingPluginException {
      return const HdrCapability(
        supported: false,
        reason: 'hdr_video_encoder plugin is not registered on this platform',
      );
    }
  }

  /// Configures the encoder. [width]/[height] must be even. Deletes any file
  /// already at [filepath].
  ///
  /// [inputPath], when given, is the source file the audio track is copied
  /// (passthrough, no re-encode) from into the output alongside the
  /// HDR-converted video. Pass null to produce a silent (video-only) output.
  static Future<void> setup({
    required int width,
    required int height,
    required int fps,
    required int videoBitrate,
    required String filepath,
    String? inputPath,
    HdrTransfer transfer = HdrTransfer.hlg,
    HdrPrimaries primaries = HdrPrimaries.rec2020,
    // The glow: a channel value at or above [glowKnee] (sRGB 0..1) ramps up to
    // [maxBoost]× brightness at white. [maxBoost] == 1.0 disables the glow.
    double maxBoost = 1.0,
    double glowKnee = 0.7,
    // Luma-preserving saturation multiplier applied in linear light (1.0 == off).
    // A small boost (~1.1) counters phones rendering HDR video less vividly than
    // their SDR mode.
    double saturation = 1.0,
    double? maxContentLightLevel,
    double? maxFrameAverageLightLevel,
    // PQ anchor: the absolute nits an unboosted (glow factor == 1) SDR white
    // maps to. Defaults to the BT.2408 reference value (203). Raising it
    // brightens the WHOLE frame uniformly, unlike [maxBoost]/[glowKnee],
    // which only affect pixels above the knee. Ignored for HLG.
    double sdrWhiteNits = kSdrWhiteNits,
  }) async {
    assert(width % 2 == 0 && height % 2 == 0, 'HEVC needs even dimensions');
    assert(maxBoost >= 1.0, 'maxBoost must be >= 1.0');
    assert(saturation > 0.0, 'saturation must be > 0');
    assert(sdrWhiteNits > 0.0, 'sdrWhiteNits must be > 0');
    _width = width;
    _height = height;
    await _channel.invokeMethod<void>('setup', <String, Object?>{
      'width': width,
      'height': height,
      'fps': fps,
      'videoBitrate': videoBitrate,
      'filepath': filepath,
      'inputPath': inputPath,
      'transfer': transfer.name,
      'primaries': primaries.name,
      'maxBoost': maxBoost,
      'glowKnee': glowKnee,
      'saturation': saturation,
      'maxContentLightLevel': maxContentLightLevel,
      'maxFrameAverageLightLevel': maxFrameAverageLightLevel,
      'sdrWhiteNits': sdrWhiteNits,
    });
  }

  /// Appends one frame. [sdrRgba] length must be `width * height * 4`.
  static Future<void> appendFrame({required Uint8List sdrRgba}) async {
    assert(
      sdrRgba.length == _width * _height * 4,
      'sdrRgba length ${sdrRgba.length} != ${_width * _height * 4}',
    );
    await _channel.invokeMethod<void>('appendFrame', <String, Object?>{
      'sdrRgba': sdrRgba,
    });
  }

  /// Finalizes and closes the file.
  static Future<void> finish() async {
    try {
      await _channel.invokeMethod<void>('finish');
    } finally {
      _width = 0;
      _height = 0;
    }
  }

  /// Reads, HDR-transforms and writes the whole video in one native call,
  /// with no per-frame round trip through Dart — see the doc comment on
  /// convertVideo: in HdrVideoEncoderPlugin.m for why (avoids an OS-level
  /// memory kill converting 4K video on memory-constrained devices).
  ///
  /// iOS-only (see isConvertVideoSupported). [width]/[height]/[fps] are the
  /// already-known values from [HdrConverter.videoOpen] on the same file.
  /// Progress can be polled via [getConvertProgress] while this is running,
  /// and [cancelConvertVideo] requests early stop.
  static Future<void> convertVideo({
    required String inputPath,
    required String outputPath,
    required int width,
    required int height,
    required int fps,
    required int videoBitrate,
    HdrTransfer transfer = HdrTransfer.hlg,
    HdrPrimaries primaries = HdrPrimaries.rec2020,
    double maxBoost = 1.0,
    double glowKnee = 0.7,
    double saturation = 1.0,
    double? maxContentLightLevel,
    double? maxFrameAverageLightLevel,
    double sdrWhiteNits = kSdrWhiteNits,
  }) async {
    await _channel.invokeMethod<void>('convertVideo', <String, Object?>{
      'inputPath': inputPath,
      'outputPath': outputPath,
      'width': width,
      'height': height,
      'fps': fps,
      'videoBitrate': videoBitrate,
      'transfer': transfer.name,
      'primaries': primaries.name,
      'maxBoost': maxBoost,
      'glowKnee': glowKnee,
      'saturation': saturation,
      'maxContentLightLevel': maxContentLightLevel,
      'maxFrameAverageLightLevel': maxFrameAverageLightLevel,
      'sdrWhiteNits': sdrWhiteNits,
    });
  }

  /// Progress of an in-flight [convertVideo] call.
  static Future<({int frameIdx, int totalFrames})> getConvertProgress() async {
    final result = await _channel.invokeMapMethod<String, Object?>('getConvertProgress');
    return (
      frameIdx: (result?['frameIdx'] as int?) ?? 0,
      totalFrames: (result?['totalFrames'] as int?) ?? 0,
    );
  }

  /// Requests that an in-flight [convertVideo] call stop early. It still
  /// completes (with a "cancelled" error) rather than returning immediately.
  static Future<void> cancelConvertVideo() async {
    await _channel.invokeMethod<void>('cancelConvertVideo');
  }

  /// A small (long edge capped, see the native side) live-preview thumbnail
  /// captured every few frames during an in-flight [convertVideo] call, or
  /// `null` if none has been captured yet. [generation] increments each
  /// time a new one is captured, so callers polling this can tell whether
  /// it's worth redrawing.
  static Future<({int generation, int width, int height, Uint8List bytes})?> getLatestPreviewFrame() async {
    final result = await _channel.invokeMapMethod<String, Object?>('getLatestPreviewFrame');
    if (result == null) return null;
    return (
      generation: result['generation'] as int,
      width: result['width'] as int,
      height: result['height'] as int,
      bytes: result['bytes'] as Uint8List,
    );
  }
}
