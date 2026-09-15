import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let registrar = engineBridge.applicationRegistrar
    let hdrVideoPlayerFactory = HdrVideoPlayerViewFactory(messenger: registrar.messenger())
    registrar.register(
      hdrVideoPlayerFactory,
      withId: "com.eonlineservice.hdr/hdr_video_player"
    )
    let hdrImageViewFactory = HdrImageViewFactory()
    registrar.register(
      hdrImageViewFactory,
      withId: "com.eonlineservice.hdr/hdr_image_view"
    )
  }
}
