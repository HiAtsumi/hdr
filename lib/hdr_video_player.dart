import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

bool get _isIOS => !kIsWeb && Platform.isIOS;
bool get _isAndroid => !kIsWeb && Platform.isAndroid;

const String _hdrPlatformViewType = 'com.eonlineservice.hdr/hdr_video_player';

/// Plays a video file, preserving native HDR (EDR) luminance on iOS/Android
/// via a Platform View (`AVPlayerLayer` / `ExoPlayer`+`SurfaceView`) embedded
/// directly in the native view hierarchy — bypassing `video_player`'s
/// texture-based compositing path, which always tone-maps HDR down to SDR.
/// Falls back to the regular `video_player` package on other platforms.
///
/// Ported from the sister app `videoconnect`'s `HdrVideoPlayerView`.
class HdrVideoPlayerController extends ChangeNotifier {
  HdrVideoPlayerController(
    this._path, {
    this.looping = false,
    this.autoplay = false,
    double? initialAspectRatio,
  }) : isNativeHdr = _isIOS || _isAndroid,
       _aspectRatio = initialAspectRatio ?? 16 / 9;

  final String _path;
  final bool looping;
  final bool autoplay;

  /// Whether this controller plays through the native HDR Platform View.
  final bool isNativeHdr;

  double _aspectRatio;
  double get aspectRatio =>
      isNativeHdr ? _aspectRatio : (_fallback?.value.aspectRatio ?? _aspectRatio);

  MethodChannel? _channel;
  bool? _pendingPlaying;

  VideoPlayerController? _fallback;

  Future<void> initialize() async {
    if (isNativeHdr) return; // the native view initializes itself on creation
    final controller = VideoPlayerController.file(File(_path));
    _fallback = controller;
    await controller.initialize();
    if (looping) await controller.setLooping(true);
    if (autoplay) await controller.play();
    notifyListeners();
  }

  Widget buildPlayer() {
    if (!isNativeHdr) {
      final controller = _fallback;
      if (controller == null || !controller.value.isInitialized) {
        return const SizedBox.shrink();
      }
      return AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      );
    }
    final creationParams = <String, dynamic>{
      'path': _path,
      'looping': looping,
      'autoplay': autoplay,
    };
    if (Platform.isIOS) {
      return UiKitView(
        viewType: _hdrPlatformViewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }
    return AndroidView(
      viewType: _hdrPlatformViewType,
      creationParams: creationParams,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _onPlatformViewCreated,
    );
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('${_hdrPlatformViewType}_$id');
    _channel!.setMethodCallHandler(_handleCallFromNative);
    final pending = _pendingPlaying;
    if (pending != null) {
      _channel!.invokeMethod(pending ? 'play' : 'pause');
    }
  }

  // The native side (ExoPlayer's onVideoSizeChanged / AVPlayerItem's
  // presentationSize) reports the actual on-screen size, rotation applied.
  Future<void> _handleCallFromNative(MethodCall call) async {
    if (call.method != 'onVideoSize') return;
    final args = call.arguments;
    if (args is! Map) return;
    final width = (args['width'] as num?)?.toDouble();
    final height = (args['height'] as num?)?.toDouble();
    if (width == null || height == null || width <= 0 || height <= 0) return;
    final ratio = width / height;
    if (ratio == _aspectRatio) return;
    _aspectRatio = ratio;
    notifyListeners();
  }

  void play() {
    if (isNativeHdr) {
      _pendingPlaying = true;
      _channel?.invokeMethod('play');
    } else {
      _fallback?.play();
    }
  }

  void pause() {
    if (isNativeHdr) {
      _pendingPlaying = false;
      _channel?.invokeMethod('pause');
    } else {
      _fallback?.pause();
    }
  }

  @override
  Future<void> dispose() async {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    await _fallback?.dispose();
    super.dispose();
  }
}

/// Small "HDR" badge to overlay on top of an [HdrVideoPlayerController]'s
/// player when it's playing with native HDR luminance.
class HdrBadge extends StatelessWidget {
  const HdrBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'HDR',
        style: TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}
