import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

bool get isWeb => kIsWeb;

/// Shares a converted HDR file (image or video) through the OS share sheet —
/// includes "Save to Photos"/"ファイルに保存" among the share targets, so this
/// doubles as the save flow. Ported from the sister app `videoconnect`'s
/// `ShareProvider`.
class ShareProvider {
  Future<void> shareFile({
    required String titleText,
    required String filePath,
    required RenderBox renderBox,
  }) async {
    if (!kIsWeb) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(filePath)],
          subject: titleText,
          text: titleText,
          sharePositionOrigin: shareButtonRect(renderBox),
        ),
      );
    } else {
      await SharePlus.instance.share(
        ShareParams(
          text: titleText,
          subject: titleText,
          sharePositionOrigin: shareButtonRect(renderBox),
        ),
      );
    }
  }

  // sharePositionOrigin(iPad対応)
  Rect shareButtonRect(RenderBox renderBox) {
    Size size = renderBox.size;
    return Rect.fromLTWH(0, 0, size.width, size.height / 2);
  }
}
