import Flutter
import UIKit

/// Displays a still image (HEIC HLG/PQ) with its HDR (EDR) luminance shown
/// as-is, via a plain `UIImageView`.
///
/// Flutter's own `Image` widget renders through a Skia texture, which
/// tone-maps HDR content down to SDR — a native view is required, same
/// reasoning as `HdrVideoPlayerView`.
class HdrImageViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return HdrImageView(frame: frame, arguments: args)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

class HdrImageView: NSObject, FlutterPlatformView {
  private let imageView: UIImageView

  init(frame: CGRect, arguments args: Any?) {
    imageView = UIImageView(frame: frame)
    imageView.contentMode = .scaleAspectFit
    super.init()

    guard let params = args as? [String: Any], let path = params["path"] as? String else {
      return
    }
    guard let image = UIImage(contentsOfFile: path) else { return }
    imageView.image = image
    if #available(iOS 17.0, *) {
      // Renders the HEIC's HLG/PQ luminance as EDR instead of tone-mapping
      // it down to SDR.
      imageView.preferredImageDynamicRange = .high
    }
  }

  func view() -> UIView {
    imageView
  }
}
