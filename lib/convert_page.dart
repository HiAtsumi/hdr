import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hdr_converter/hdr_converter.dart';
import 'package:hdr_video_encoder/hdr_video_encoder.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'ad_banner.dart';
import 'hdr_image_view.dart';
import 'hdr_video_player.dart';
import 'share_provider.dart';

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

  @override
  void dispose() {
    _sourcePreview?.dispose();
    _resultPlayer?.dispose();
    for (final image in _previewImageHistory) {
      image.dispose();
    }
    super.dispose();
  }

  _Kind _detectKind(String path) {
    final ext = p.extension(path).toLowerCase();
    return _videoExtensions.contains(ext) ? _Kind.video : _Kind.image;
  }

  Future<void> _pick() async {
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

  Future<void> _convertVideo() async {
    final inputPath = _inputPath;
    if (inputPath == null) return;

    final capability = await HdrVideoEncoder.probe();
    if (!capability.supported) {
      setState(() => _error = 'HDR export not supported. ${capability.reason ?? ''}');
      return;
    }

    _clearPreviewImages();
    setState(() {
      _step = _Step.converting;
      _error = null;
      _progress = 0;
    });

    try {
      final info = await HdrConverter.videoOpen(inputPath);
      _previewAspectRatio = info.width / info.height;

      final dir = await getTemporaryDirectory();
      final base = p.basenameWithoutExtension(inputPath);
      final outputPath = p.join(
        dir.path,
        '${base}_hdr_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );

      await HdrVideoEncoder.setup(
        width: info.width,
        height: info.height,
        fps: info.fps,
        videoBitrate: _estimateVideoBitrate(info.width, info.height, info.fps),
        filepath: outputPath,
      );

      var frameIdx = 0;
      while (true) {
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
      if (!mounted) return;
      setState(() {
        _error = 'Conversion failed.';
        _step = _Step.ready;
      });
    }
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
          builder: (context, _) => AspectRatio(
            aspectRatio: resultPlayer.aspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                resultPlayer.buildPlayer(),
                if (resultPlayer.isNativeHdr)
                  const Positioned(right: 8, top: 8, child: HdrBadge()),
              ],
            ),
          ),
        );
      }
      if (_step == _Step.converting && _previewImage != null) {
        return AspectRatio(
          aspectRatio: _previewAspectRatio ?? 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AnimatedSwitcher(
              duration: _previewFadeDuration,
              child: RawImage(
                key: ValueKey(_previewKey),
                image: _previewImage,
                fit: BoxFit.contain,
              ),
            ),
          ),
        );
      }
      final source = _sourcePreview;
      if (source != null && source.value.isInitialized) {
        return AspectRatio(
          aspectRatio: source.value.aspectRatio,
          child: GestureDetector(
            onTap: () => setState(() {
              source.value.isPlaying ? source.pause() : source.play();
            }),
            child: VideoPlayer(source),
          ),
        );
      }
    } else if (_kind == _Kind.image) {
      final outputPath = _outputPath;
      if (_step == _Step.done && outputPath != null) {
        // The native HDR view (bypassing Flutter's Skia texture pipeline)
        // shows the actual HLG/PQ or Ultra HDR gainmap brightness, same as
        // the video result preview.
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              HdrImageView(path: outputPath),
              if (HdrImageView.isSupportedPlatform)
                const Positioned(right: 8, top: 8, child: HdrBadge()),
            ],
          ),
        );
      }
      final inputPath = _inputPath;
      if (inputPath != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(File(inputPath), fit: BoxFit.contain),
        );
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.auto_awesome, size: 56, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        const Text('SDR → HDR', style: TextStyle(fontSize: 16, color: Colors.black54)),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _pick,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('Select'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HDR converter')),
      // エラーはAppBar直下、広告は画面最下部に独立して置く。両方を下側に
      // まとめると、エラー文が広告の一部のように見えてしまうため離す。
      body: SafeArea(
        child: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Expanded(child: Center(child: _buildPreview())),
                    if (_step == _Step.converting) ...[
                      LinearProgressIndicator(value: _progress > 0 ? _progress : null),
                      const SizedBox(height: 4),
                      Text('${(_progress * 100).toStringAsFixed(0)}%'),
                      const SizedBox(height: 8),
                    ],
                    if (_step == _Step.done)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle, color: Colors.green),
                            SizedBox(width: 8),
                            Text('Done'),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (_inputPath != null && _step != _Step.converting)
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _reset,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Change'),
                            ),
                          ),
                        if (_inputPath != null && _step != _Step.converting) const SizedBox(width: 12),
                        if (_step == _Step.ready || _step == _Step.done)
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _step == _Step.ready ? _convert : null,
                              icon: const Icon(Icons.auto_awesome),
                              label: const Text('Convert'),
                            ),
                          ),
                        if (_step == _Step.done) const SizedBox(width: 12),
                        if (_step == _Step.done)
                          Expanded(
                            child: FilledButton.icon(
                              key: _shareButtonKey,
                              onPressed: _share,
                              icon: const Icon(Icons.ios_share),
                              label: const Text('Share'),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const AdBanner(),
          ],
        ),
      ),
    );
  }
}
