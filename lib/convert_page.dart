import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:hdr_converter/hdr_converter.dart';
import 'package:hdr_video_encoder/hdr_video_encoder.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'ad_banner.dart';
import 'ad_interstitial.dart';
import 'hdr_image_view.dart';
import 'hdr_video_player.dart';
import 'native_view_zoom.dart';
import 'privacy_policy_page.dart';
import 'share_provider.dart';

// Applied to the white overlay text/icons drawn directly over the media
// preview (title, buttons, progress, …) so they stay legible against any
// image/video content without needing a background scrim behind them.
const List<Shadow> _overlayShadows = [
  Shadow(color: Colors.black87, blurRadius: 6, offset: Offset(0, 1)),
];

enum _Kind { image, video }

enum _Step { pick, ready, converting, done }

// Decoding+re-encoding every frame already saturates the conversion loop;
// only turning 1 in every N frames into a GPU-displayable ui.Image keeps the
// live preview from competing with (and slowing down) that work.
const int _previewFrameInterval = 5;
const Duration _previewFadeDuration = Duration(milliseconds: 250);

const Set<String> _videoExtensions = {
  '.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm', '.3gp', '.3g2',
};

/// Single-screen converter: one picker for either a photo or a video (the
/// file itself tells us which), so there's no separate "pick a kind" menu.
class ConvertPage extends StatefulWidget {
  const ConvertPage({super.key});

  @override
  State<ConvertPage> createState() => _ConvertPageState();
}

class _ConvertPageState extends State<ConvertPage> {
  final _shareButtonKey = GlobalKey();
  final _shareProvider = ShareProvider();

  _Kind? _kind;
  _Step _step = _Step.pick;
  String? _inputPath;
  String? _outputPath;
  String? _error;
  double _progress = 0;
  // 総フレーム数が判明するまで(videoOpen完了まで)は、進捗0%と「進捗不明」を
  // 区別する。区別しないとLinearProgressIndicatorのvalueがnull(不確定モード)
  // になり、開始直後の一瞬だけバーが動き回って0%ではないように見えてしまう。
  bool _progressUnknown = false;
  bool _cancelRequested = false;

  // Video-only state.
  VideoPlayerController? _sourcePreview;
  HdrVideoPlayerController? _resultPlayer;

  // Live "every N frames" preview during video conversion. AnimatedSwitcher
  // keeps the outgoing image on screen while it fades out, so up to 2
  // ui.Images can be alive at once — this list tracks them so we dispose
  // each GPU texture once it's definitely done fading (a 3rd one arrives).
  ui.Image? _previewImage;
  double? _previewAspectRatio;
  int _previewKey = 0;
  final List<ui.Image> _previewImageHistory = [];

  // A soft custom tap sound for button presses — the platform's built-in
  // SystemSoundType.click (a raw keyboard-click sample) reads as a harsh
  // "pop" over a phone speaker, so we ship our own gentler effect instead.
  //
  // On iOS this plays through AudioServices (see ClickSoundPlugin.swift) —
  // the same instant-latency mechanism SystemSoundType.click itself uses.
  // audioplayers' AVAudioPlayer-based playback has to activate the audio
  // session and prepare a buffer on every call, which reads as sluggish for
  // a tap sound that needs to feel instant; AudioServices skips all of that.
  // Other platforms fall back to a pool of pre-loaded players (a single
  // reused player was audibly delayed or silent on some taps, since reusing
  // one player's seek+resume serialises every tap through its own state
  // machine).
  static const _clickChannel = MethodChannel('com.eonlineservice.hdr/click_sound');
  AudioPool? _clickPool;

  final _interstitialAd = InterstitialAdController();

  @override
  void initState() {
    super.initState();
    _interstitialAd.preload();
    if (!Platform.isIOS) {
      AudioPool.createFromAsset(
        path: 'sounds/click.wav',
        minPlayers: 2,
        maxPlayers: 4,
      ).then((pool) {
        if (!mounted) {
          pool.dispose();
          return;
        }
        _clickPool = pool;
      });
    }
  }

  @override
  void dispose() {
    _sourcePreview?.dispose();
    _resultPlayer?.dispose();
    _clickPool?.dispose();
    _interstitialAd.dispose();
    for (final image in _previewImageHistory) {
      image.dispose();
    }
    super.dispose();
  }

  _Kind _detectKind(String path) {
    final ext = p.extension(path).toLowerCase();
    return _videoExtensions.contains(ext) ? _Kind.video : _Kind.image;
  }

  void _playClickSound() {
    if (Platform.isIOS) {
      unawaited(_clickChannel.invokeMethod('play'));
    } else {
      unawaited(_clickPool?.start());
    }
  }

  Future<void> _pick() async {
    _playClickSound();
    final picked = await ImagePicker().pickMedia();
    if (picked == null) return;
    if (_detectKind(picked.path) == _Kind.video) {
      await _pickVideo(picked.path);
    } else {
      await _pickImage(picked.path);
    }
  }

  Future<void> _pickImage(String path) async {
    final source = await HdrConverter.probeImageSource(path);
    if (source.isHdr) {
      setState(() => _error = source.reason ?? 'Already HDR — please select an SDR file.');
      return;
    }
    setState(() {
      _kind = _Kind.image;
      _inputPath = path;
      _outputPath = null;
      _error = null;
      _step = _Step.ready;
    });
  }

  Future<void> _pickVideo(String path) async {
    final source = await HdrConverter.probeVideoSource(path);
    if (source.isHdr) {
      setState(() => _error = source.reason ?? 'Already HDR — please select an SDR file.');
      return;
    }

    await _sourcePreview?.dispose();
    final controller = VideoPlayerController.file(File(path));
    await controller.initialize();
    // Auto-plays looped rather than sitting on a static first frame — this
    // also sidesteps an iOS video_player quirk where, on some sources,
    // initialize() alone leaves the preview solid black until playback
    // actually starts.
    await controller.setLooping(true);
    await controller.play();

    setState(() {
      _kind = _Kind.video;
      _inputPath = path;
      _outputPath = null;
      _error = null;
      _sourcePreview = controller;
      _step = _Step.ready;
    });
  }

  Future<void> _convert() async {
    _playClickSound();
    // 変換処理はここで待たず並行して進める。広告を閉じるまで変換が止まって
    // 見えないよう、裏で変換を継続させる。
    _interstitialAd.showIfReady();
    if (_kind == _Kind.image) {
      await _convertImage();
    } else if (_kind == _Kind.video) {
      await _convertVideo();
    }
  }

  Future<void> _convertImage() async {
    final inputPath = _inputPath;
    if (inputPath == null) return;

    final capability = await HdrConverter.probeImage();
    if (!capability.supported) {
      setState(() => _error = 'HDR export not supported. ${capability.reason ?? ''}');
      return;
    }

    setState(() {
      _step = _Step.converting;
      _error = null;
    });

    try {
      final dir = await getTemporaryDirectory();
      final ext = Platform.isAndroid ? '.jpg' : '.heic';
      final base = p.basenameWithoutExtension(inputPath);
      final outputPath = p.join(
        dir.path,
        '${base}_hdr_${DateTime.now().millisecondsSinceEpoch}$ext',
      );

      await HdrConverter.convertImage(inputPath: inputPath, outputPath: outputPath);

      setState(() {
        _outputPath = outputPath;
        _step = _Step.done;
      });
    } catch (e) {
      setState(() {
        _error = 'Conversion failed.';
        _step = _Step.ready;
      });
    }
  }

  int _estimateVideoBitrate(int width, int height, int fps) {
    // ~0.07 bits/pixel/frame — a reasonable default for HEVC Main10.
    final bitrate = (width * height * fps * 0.07).round();
    return bitrate.clamp(4000000, 50000000);
  }

  // Caps the long edge at 1080p, preserving aspect ratio. Above that, the
  // native iOS pipeline's per-frame memory footprint (source buffer +
  // half-float HDR buffer + AVFoundation's own encoder buffering) can be
  // enough to get the app OS-killed for memory on constrained devices —
  // downscaling the actual encode target is the reliable way to keep a genuinely
  // large source (4K+) working everywhere, at the cost of output resolution.
  (int, int) _scaledVideoDimensions(int width, int height) {
    const maxDimension = 1920;
    final longEdge = width > height ? width : height;
    if (longEdge <= maxDimension) return (width, height);
    final scale = maxDimension / longEdge;
    var scaledWidth = (width * scale).round();
    var scaledHeight = (height * scale).round();
    // HEVC needs even dimensions.
    if (scaledWidth.isOdd) scaledWidth -= 1;
    if (scaledHeight.isOdd) scaledHeight -= 1;
    return (scaledWidth, scaledHeight);
  }

  void _cancelConversion() {
    _playClickSound();
    setState(() => _cancelRequested = true);
    if (Platform.isIOS && _kind == _Kind.video) {
      // The Dart-side loop (used on other platforms) polls _cancelRequested
      // itself, but iOS's video path runs entirely inside one native call
      // (see HdrVideoEncoder.convertVideo) with no per-frame Dart checkpoint
      // to see this flag — it has to be told directly.
      HdrVideoEncoder.cancelConvertVideo();
    }
  }

  Future<void> _convertVideo() async {
    final inputPath = _inputPath;
    if (inputPath == null) return;

    final capability = await HdrVideoEncoder.probe();
    if (!capability.supported) {
      setState(() => _error = 'HDR export not supported. ${capability.reason ?? ''}');
      return;
    }

    // The live per-frame conversion preview (silent) takes over the screen
    // once conversion starts, but this controller was never told to stop —
    // it kept playing (and audible) behind the scenes for the whole
    // conversion, not just the brief moment before the first preview frame
    // arrives.
    _sourcePreview?.pause();
    _clearPreviewImages();
    setState(() {
      _step = _Step.converting;
      _error = null;
      _progress = 0;
      _progressUnknown = false;
      _cancelRequested = false;
    });

    try {
      final info = await HdrConverter.videoOpen(inputPath);
      _previewAspectRatio = info.width / info.height;
      if (info.frameCount <= 0 && mounted) {
        setState(() => _progressUnknown = true);
      }

      final dir = await getTemporaryDirectory();
      final base = p.basenameWithoutExtension(inputPath);
      final outputPath = p.join(
        dir.path,
        '${base}_hdr_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );

      if (Platform.isIOS) {
        // videoOpen above was only for the metadata (width/height/fps/
        // frameCount) — the actual frame-by-frame read+transform+write runs
        // natively inside HdrVideoEncoder.convertVideo with no per-frame
        // Dart round trip. See that method's doc comment: the old
        // Dart-driven loop copied a full-resolution frame across the
        // Flutter method channel twice per frame, which was enough to get
        // 4K conversions OS-killed for memory on constrained devices.
        //
        // Even with that fixed, a large enough source (e.g. genuine 4K) can
        // still push a memory-constrained device over the edge — AVFoundation's
        // own HEVC Main10 encoder buffering at that resolution is outside our
        // control. Downscaling the encode target is the reliable fallback.
        final (encodeWidth, encodeHeight) = _scaledVideoDimensions(info.width, info.height);
        await HdrConverter.videoClose();
        await _convertVideoNatively(
          inputPath: inputPath,
          outputPath: outputPath,
          fps: info.fps,
          width: encodeWidth,
          height: encodeHeight,
          videoBitrate: _estimateVideoBitrate(encodeWidth, encodeHeight, info.fps),
        );
      } else {
        await _convertVideoFrameByFrame(
          info: info,
          inputPath: inputPath,
          outputPath: outputPath,
          videoBitrate: _estimateVideoBitrate(info.width, info.height, info.fps),
        );
      }

      if (_cancelRequested) {
        try {
          await File(outputPath).delete();
        } catch (_) {
          // Best-effort cleanup; a missing/undeletable temp file isn't fatal.
        }
        _clearPreviewImages();
        _sourcePreview?.play();
        if (!mounted) return;
        setState(() {
          _step = _Step.ready;
          _progress = 0;
        });
        return;
      }

      final resultPlayer = HdrVideoPlayerController(
        outputPath,
        looping: true,
        autoplay: true,
        // Encoded at the same (rotation-applied) size we decoded, so this is
        // an exact initial guess, not just an estimate.
        initialAspectRatio: info.width / info.height,
      );
      await resultPlayer.initialize();

      if (!mounted) return;
      setState(() {
        _outputPath = outputPath;
        _resultPlayer = resultPlayer;
        _step = _Step.done;
      });
    } catch (e) {
      await HdrConverter.videoClose();
      _clearPreviewImages();
      _sourcePreview?.play();
      if (!mounted) return;
      setState(() {
        _error = 'Conversion failed.';
        _step = _Step.ready;
      });
    }
  }

  /// iOS: single native call, no per-frame Dart round trip. Progress and the
  /// live preview are both polled rather than pushed — the preview frames
  /// are small (native side downscales before handing them over), so this
  /// doesn't reintroduce the full-resolution-buffer-per-frame cost that
  /// convertVideo exists to avoid.
  Future<void> _convertVideoNatively({
    required String inputPath,
    required String outputPath,
    required int width,
    required int height,
    required int fps,
    required int videoBitrate,
  }) async {
    final convertFuture = HdrVideoEncoder.convertVideo(
      inputPath: inputPath,
      outputPath: outputPath,
      width: width,
      height: height,
      fps: fps,
      videoBitrate: videoBitrate,
    );

    var lastPreviewGeneration = -1;
    final progressTimer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      final progress = await HdrVideoEncoder.getConvertProgress();
      if (mounted && progress.totalFrames > 0) {
        setState(() => _progress = (progress.frameIdx / progress.totalFrames).clamp(0.0, 1.0));
      }

      final preview = await HdrVideoEncoder.getLatestPreviewFrame();
      if (preview == null || preview.generation == lastPreviewGeneration) return;
      lastPreviewGeneration = preview.generation;
      final image = await _decodeFrame(preview.bytes, preview.width, preview.height);
      if (!mounted) {
        image.dispose();
        return;
      }
      _pushPreviewImage(image);
    });

    try {
      await convertFuture;
    } on PlatformException catch (e) {
      if (e.code != 'cancelled') rethrow;
    } finally {
      progressTimer.cancel();
    }
  }

  // Used on platforms other than iOS (Android in practice) — hasn't shown
  // the memory pressure that made iOS move to the native single-call
  // convertVideo pipeline (see _convertVideoNatively), so the live preview
  // stays unconditionally on here.
  Future<void> _convertVideoFrameByFrame({
    required SdrVideoInfo info,
    required String inputPath,
    required String outputPath,
    required int videoBitrate,
  }) async {
    await HdrVideoEncoder.setup(
      width: info.width,
      height: info.height,
      fps: info.fps,
      videoBitrate: videoBitrate,
      filepath: outputPath,
      inputPath: inputPath,
    );

    var frameIdx = 0;
    while (!_cancelRequested) {
      final frame = await HdrConverter.videoReadFrame();
      if (frame == null) break;
      await HdrVideoEncoder.appendFrame(sdrRgba: frame);
      frameIdx++;
      if (info.frameCount > 0) {
        final progress = (frameIdx / info.frameCount).clamp(0.0, 1.0);
        if (mounted) setState(() => _progress = progress);
      }
      if (frameIdx % _previewFrameInterval == 0) {
        final image = await _decodeFrame(frame, info.width, info.height);
        if (!mounted) {
          image.dispose();
          break;
        }
        _pushPreviewImage(image);
      }
    }
    await HdrVideoEncoder.finish();
    await HdrConverter.videoClose();
  }

  Future<ui.Image> _decodeFrame(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  void _pushPreviewImage(ui.Image image) {
    _previewImageHistory.add(image);
    if (_previewImageHistory.length > 2) {
      _previewImageHistory.removeAt(0).dispose();
    }
    if (!mounted) return;
    setState(() {
      _previewImage = image;
      _previewKey++;
    });
  }

  void _clearPreviewImages() {
    for (final image in _previewImageHistory) {
      image.dispose();
    }
    _previewImageHistory.clear();
    _previewImage = null;
  }

  Future<void> _share() async {
    _playClickSound();
    final outputPath = _outputPath;
    if (outputPath == null) return;
    final renderBox = _shareButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    await _shareProvider.shareFile(
      titleText: _kind == _Kind.video ? 'HDR Video' : 'HDR Photo',
      filePath: outputPath,
      renderBox: renderBox,
    );
  }

  Future<void> _reset() async {
    _playClickSound();
    await _sourcePreview?.dispose();
    await _resultPlayer?.dispose();
    _clearPreviewImages();
    setState(() {
      _kind = null;
      _inputPath = null;
      _outputPath = null;
      _error = null;
      _sourcePreview = null;
      _resultPlayer = null;
      _step = _Step.pick;
    });
  }

  Widget _buildPreview() {
    if (_kind == _Kind.video) {
      final resultPlayer = _resultPlayer;
      if (_step == _Step.done && resultPlayer != null) {
        // The native HDR player reports its real (rotation-applied) size
        // asynchronously via onVideoSize, well after this widget is first
        // built — without listening for that, the preview stays boxed at
        // the initial 16:9 guess, which looks portrait/landscape-swapped
        // for a portrait source.
        return ListenableBuilder(
          listenable: resultPlayer,
          builder: (context, _) => Stack(
            fit: StackFit.expand,
            children: [
              // A native HDR video plays through a bare SurfaceView (see
              // HdrVideoPlayerView.kt), which — unlike ordinary Flutter
              // content — doesn't follow a paint-time Transform such as
              // InteractiveViewer's, only a real layout resize. The
              // fallback (non-native) player has no such restriction, but
              // NativeViewZoom's real-resize approach works for it too.
              NativeViewZoom(
                aspectRatio: resultPlayer.aspectRatio,
                child: resultPlayer.buildPlayer(),
              ),
              if (resultPlayer.isNativeHdr)
                const Positioned(top: 8, left: 0, right: 0, child: Center(child: HdrBadge())),
            ],
          ),
        );
      }
      if (_step == _Step.converting && _previewImage != null) {
        return AspectRatio(
          aspectRatio: _previewAspectRatio ?? 16 / 9,
          child: AnimatedSwitcher(
            duration: _previewFadeDuration,
            child: RawImage(
              key: ValueKey(_previewKey),
              image: _previewImage,
              fit: BoxFit.contain,
            ),
          ),
        );
      }
      final source = _sourcePreview;
      if (source != null && source.value.isInitialized) {
        return NativeViewZoom(
          aspectRatio: source.value.aspectRatio,
          onTap: () => setState(() {
            source.value.isPlaying ? source.pause() : source.play();
          }),
          child: VideoPlayer(source),
        );
      }
    } else if (_kind == _Kind.image) {
      final outputPath = _outputPath;
      if (_step == _Step.done && outputPath != null) {
        // The native HDR view (bypassing Flutter's Skia texture pipeline)
        // shows the actual HLG/PQ or Ultra HDR gainmap brightness, same as
        // the video result preview.
        return Stack(
          fit: StackFit.expand,
          children: [
            // InteractiveViewer (constrained: true, the default) sizes
            // itself to its child's natural size, not to the space
            // available — without forcing it to fill via SizedBox.expand,
            // it shrinks to the image's own contain-fit box and zooming is
            // clipped to that box instead of the whole screen.
            SizedBox.expand(
              // Keyed on orientation: InteractiveViewer's zoom/pan matrix is
              // relative to its box size, so on rotation it stays valid for
              // the old (now wrong) size — recreating it resets the zoom
              // and recenters cleanly instead of leaving it looking wrong.
              child: InteractiveViewer(
                key: ValueKey(MediaQuery.orientationOf(context)),
                minScale: 1,
                maxScale: 5,
                child: HdrImageView(path: outputPath),
              ),
            ),
            if (HdrImageView.isSupportedPlatform)
              const Positioned(top: 8, left: 0, right: 0, child: Center(child: HdrBadge())),
          ],
        );
      }
      final inputPath = _inputPath;
      if (inputPath != null) {
        return SizedBox.expand(
          child: InteractiveViewer(
            key: ValueKey(MediaQuery.orientationOf(context)),
            minScale: 1,
            maxScale: 5,
            child: Image.file(File(inputPath), fit: BoxFit.contain),
          ),
        );
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.auto_awesome, size: 56, color: Colors.white70),
        const SizedBox(height: 12),
        const Text('SDR → HDR', style: TextStyle(fontSize: 16, color: Colors.white70)),
        const SizedBox(height: 20),
        OutlinedButton(
          onPressed: _pick,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white70),
          ),
          child: _buttonContent(Icons.add_photo_alternate_outlined, 'Select'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ],
      ],
    );
  }

  // Icon above, label below — a narrow phone has enough width for the
  // label on its own line, but not next to the icon too, where it wraps
  // mid-word instead.
  Widget _buttonContent(IconData icon, String label, {List<Shadow>? shadows}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        Icon(icon, size: 20, shadows: shadows),
        const SizedBox(height: 2),
        Text(label, textAlign: TextAlign.center, style: TextStyle(shadows: shadows)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // タイトル・エラー・進捗・操作ボタンはすべて画像/動画プレビューの上に
    // 重ねて表示し、プレビュー自体は画面いっぱい(セーフエリア基準)に
    // 表示する。広告バナーだけは視認性確保のため重ねずに最下部へ固定する。
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: SafeArea(
              bottom: false,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(child: _buildPreview()),
                  if (_step == _Step.converting && _kind == _Kind.image)
                    const Center(
                      child: SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      ),
                    ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 4, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'HDR converter',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    shadows: _overlayShadows,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.privacy_tip_outlined,
                                  color: Colors.white,
                                  shadows: _overlayShadows,
                                ),
                                tooltip: 'Privacy Policy',
                                onPressed: () {
                                  _playClickSound();
                                  Navigator.of(context).push(
                                    MaterialPageRoute(builder: (_) => const PrivacyPolicyPage()),
                                  );
                                },
                              ),
                            ],
                          ),
                          if (_error != null && _step != _Step.pick) ...[
                            const SizedBox(height: 8),
                            Text(
                              _error!,
                              style: const TextStyle(color: Colors.redAccent, shadows: _overlayShadows),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 32, 20, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_step == _Step.converting && _kind == _Kind.video) ...[
                            LinearProgressIndicator(
                              value: _progressUnknown ? null : _progress,
                              color: Colors.red,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${(_progress * 100).toStringAsFixed(0)}%',
                              style: const TextStyle(color: Colors.white, shadows: _overlayShadows),
                            ),
                            const SizedBox(height: 8),
                          ],
                          if (_step == _Step.done)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.check_circle, color: Colors.green, shadows: _overlayShadows),
                                  SizedBox(width: 8),
                                  Text('Done', style: TextStyle(color: Colors.white, shadows: _overlayShadows)),
                                ],
                              ),
                            ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_inputPath != null && _step != _Step.converting)
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: _reset,
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white,
                                      side: const BorderSide(color: Colors.white70),
                                    ),
                                    child: _buttonContent(Icons.refresh, 'Change', shadows: _overlayShadows),
                                  ),
                                ),
                              if (_inputPath != null && _step != _Step.converting) const SizedBox(width: 12),
                              if (_step == _Step.converting && _kind == _Kind.video)
                                OutlinedButton(
                                  onPressed: _cancelRequested ? null : _cancelConversion,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: const BorderSide(color: Colors.white70),
                                  ),
                                  child: _buttonContent(
                                    Icons.close,
                                    _cancelRequested ? 'Cancelling...' : 'Cancel',
                                    shadows: _overlayShadows,
                                  ),
                                ),
                              if (_step == _Step.ready || _step == _Step.done)
                                Expanded(
                                  child: FilledButton(
                                    onPressed: _step == _Step.ready ? _convert : null,
                                    child: _buttonContent(Icons.auto_awesome, 'Convert'),
                                  ),
                                ),
                              if (_step == _Step.done) const SizedBox(width: 12),
                              if (_step == _Step.done)
                                Expanded(
                                  child: FilledButton(
                                    key: _shareButtonKey,
                                    onPressed: _share,
                                    child: _buttonContent(Icons.ios_share, 'Share'),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const AdBanner(),
        ],
      ),
    );
  }
}
