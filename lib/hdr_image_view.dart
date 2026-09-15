import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool get _isIOS => !kIsWeb && Platform.isIOS;
bool get _isAndroid => !kIsWeb && Platform.isAndroid;

const String _hdrImageViewType = 'com.eonlineservice.hdr/hdr_image_view';

/// Shows a still image, preserving native HDR luminance on iOS/Android via a
/// Platform View (`UIImageView` / `ImageView`) — Flutter's own `Image`
/// widget renders through a Skia texture, which tone-maps an HDR HEIC's
/// HLG/PQ content, and ignores an Ultra HDR JPEG's gainmap entirely, down to
/// a plain SDR look. Falls back to the regular `Image.file` elsewhere.
class HdrImageView extends StatelessWidget {
  const HdrImageView({super.key, required this.path});

  final String path;

  static bool get isSupportedPlatform => _isIOS || _isAndroid;

  @override
  Widget build(BuildContext context) {
    if (!isSupportedPlatform) {
      return Image.file(File(path), fit: BoxFit.contain);
    }
    final creationParams = <String, dynamic>{'path': path};
    if (Platform.isIOS) {
      return UiKitView(
        viewType: _hdrImageViewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    return AndroidView(
      viewType: _hdrImageViewType,
      creationParams: creationParams,
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
}
