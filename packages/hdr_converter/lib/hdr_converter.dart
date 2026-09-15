import 'dart:async';

import 'package:flutter/services.dart';

/// Result of [HdrConverter.probeImage].
class HdrImageCapability {
  const HdrImageCapability({required this.supported, this.reason});

  final bool supported;
  final String? reason;

  @override
  String toString() =>
      'HdrImageCapability(supported: $supported, reason: $reason)';
}

/// Result of [HdrConverter.probeImageSource] / [HdrConverter.probeVideoSource].
class HdrSourceInfo {
  const HdrSourceInfo({required this.isHdr, this.reason});

  /// Whether the source file already carries HDR content (HLG/PQ transfer
  /// tag for video/HEIC, or an Ultra HDR gainmap / Apple HDR gainmap for a
  /// still image) — converting it again would be meaningless or harmful.
  final bool isHdr;
  final String? reason;

  @override
  String toString() => 'HdrSourceInfo(isHdr: $isHdr, reason: $reason)';
}

/// Info about an opened SDR video, returned by [HdrConverter.videoOpen].
class SdrVideoInfo {
  const SdrVideoInfo({
    required this.width,
    required this.height,
    required this.fps,
    required this.frameCount,
  });

  /// Display-orientation width/height (rotation already applied).
  final int width;
  final int height;
  final int fps;

  /// Estimate only — use it for progress UI, not as an exact frame count.
  final int frameCount;

  @override
  String toString() =>
      'SdrVideoInfo(width: $width, height: $height, fps: $fps, frameCount: $frameCount)';
}

/// Decodes an SDR video into per-frame sRGB RGBA8888 buffers, and converts a
/// single SDR still image into a native HDR image (HEIC/HLG or HEIC/PQ on
/// iOS & macOS, Ultra HDR JPEG on Android).
///
/// Video frames feed straight into `hdr_video_encoder`'s `appendFrame` —
/// this plugin only supplies the SDR source frames; the HDR colour science
/// (glow boost, primaries matrix, HLG/PQ OETF) lives entirely in
/// `hdr_video_encoder`, unchanged.
class HdrConverter {
  HdrConverter._();

  static const MethodChannel _channel = MethodChannel('hdr_converter/methods');

  // ---------------------------------------------------------------------
  // Video: SDR frame source
  // ---------------------------------------------------------------------

  /// Checks whether the video at [path] is already HDR (HLG/PQ transfer
  /// tag), so the caller can reject it before spending time re-encoding it.
  static Future<HdrSourceInfo> probeVideoSource(String path) async {
    final res = await _channel.invokeMapMethod<String, Object?>(
      'probeVideoSource',
      <String, Object?>{'path': path},
    );
    return HdrSourceInfo(
      isHdr: (res?['isHdr'] as bool?) ?? false,
      reason: res?['reason'] as String?,
    );
  }

  /// Opens [path] for frame-by-frame reading. Only one video may be open at
  /// a time; call [videoClose] before opening another.
  static Future<SdrVideoInfo> videoOpen(String path) async {
    final res = await _channel.invokeMapMethod<String, Object?>(
      'videoOpen',
      <String, Object?>{'path': path},
    );
    return SdrVideoInfo(
      width: res!['width'] as int,
      height: res['height'] as int,
      fps: res['fps'] as int,
      frameCount: res['frameCount'] as int,
    );
  }

  /// Returns the next frame as tightly-packed sRGB RGBA8888
  /// (`width * height * 4` bytes), or `null` once the video is exhausted.
  static Future<Uint8List?> videoReadFrame() async {
    final res = await _channel.invokeMethod<Uint8List>('videoReadFrame');
    return res;
  }

  /// Releases the decoder opened by [videoOpen]. Safe to call even if
  /// nothing is open.
  static Future<void> videoClose() async {
    await _channel.invokeMethod<void>('videoClose');
  }

  // ---------------------------------------------------------------------
  // Image: SDR -> HDR still
  // ---------------------------------------------------------------------

  /// Checks whether the image at [path] is already HDR (an Ultra HDR /
  /// Apple HDR gainmap, or an HLG/PQ-tagged HEIC), so the caller can reject
  /// it before spending time re-encoding it.
  static Future<HdrSourceInfo> probeImageSource(String path) async {
    final res = await _channel.invokeMapMethod<String, Object?>(
      'probeImageSource',
      <String, Object?>{'path': path},
    );
    return HdrSourceInfo(
      isHdr: (res?['isHdr'] as bool?) ?? false,
      reason: res?['reason'] as String?,
    );
  }

  /// Whether this device/OS can encode a native HDR still image.
  static Future<HdrImageCapability> probeImage() async {
    final res = await _channel.invokeMapMethod<String, Object?>('probeImage');
    return HdrImageCapability(
      supported: (res?['supported'] as bool?) ?? false,
      reason: res?['reason'] as String?,
    );
  }

  /// Converts the SDR image at [inputPath] into an HDR image at
  /// [outputPath], same pixel dimensions. [transfer] is `'hlg'` or `'pq'`;
  /// [primaries] is `'rec2020'` or `'displayP3'` (Android's Ultra HDR output
  /// keeps the base image's original gamut and only applies primaries on
  /// iOS/macOS). Mirrors `hdr_video_encoder`'s per-pixel parameters.
  static Future<void> convertImage({
    required String inputPath,
    required String outputPath,
    String transfer = 'hlg',
    String primaries = 'rec2020',
    double maxBoost = 2.0,
    double glowKnee = 0.7,
    double saturation = 1.0,
    double sdrWhiteNits = 203.0,
  }) async {
    await _channel.invokeMethod<void>('convertImage', <String, Object?>{
      'inputPath': inputPath,
      'outputPath': outputPath,
      'transfer': transfer,
      'primaries': primaries,
      'maxBoost': maxBoost,
      'glowKnee': glowKnee,
      'saturation': saturation,
      'sdrWhiteNits': sdrWhiteNits,
    });
  }
}
