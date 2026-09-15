import AVFoundation
import Flutter
import UIKit

/// 連結済みプレビュー動画をHDR(EDR)の輝度のまま再生するためのPlatform View。
///
/// Flutterの`video_player`はデコードしたフレームを一旦`CVPixelBuffer`経由の
/// テクスチャへ書き出してから合成するため、その過程でHDRがSDRへトーン
/// マッピングされてしまう。このViewは`AVPlayerLayer`をFlutterの通常の
/// UIKitビュー階層へ直接埋め込み(テクスチャを介さない)ことで、EDRの
/// 輝度をそのまま画面に反映させる。
class HdrVideoPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return HdrVideoPlayerView(
      frame: frame,
      viewIdentifier: viewId,
      arguments: args,
      messenger: messenger
    )
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

/// AVPlayerLayerを自身の描画レイヤーとして持つコンテナ。
/// 通常のCore Animationコンポジット経路で描画されるため、
/// `wantsExtendedDynamicRangeContent`がそのまま画面出力に反映される。
private final class HdrPlayerContainerView: UIView {
  override static var layerClass: AnyClass { AVPlayerLayer.self }

  var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }
}

class HdrVideoPlayerView: NSObject, FlutterPlatformView {
  private let containerView: HdrPlayerContainerView
  private var player: AVQueuePlayer?
  private var looper: AVPlayerLooper?
  private let channel: FlutterMethodChannel
  private var presentationSizeObservation: NSKeyValueObservation?

  init(
    frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?,
    messenger: FlutterBinaryMessenger
  ) {
    containerView = HdrPlayerContainerView(frame: frame)
    containerView.backgroundColor = .black
    containerView.playerLayer.videoGravity = .resizeAspect
    // HDRの輝度(EDR)をそのまま再生する。falseだとSDRへトーンマッピングされる。
    // iOS 17未満はこのプロパティ自体が無く、システムの自動判定に委ねる。
    if #available(iOS 17.0, *) {
      containerView.playerLayer.wantsExtendedDynamicRangeContent = true
    }

    channel = FlutterMethodChannel(
      name: "com.eonlineservice.hdr/hdr_video_player_\(viewId)",
      binaryMessenger: messenger
    )

    super.init()

    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    guard let params = args as? [String: Any], let path = params["path"] as? String else {
      return
    }
    let looping = params["looping"] as? Bool ?? false
    let autoplay = params["autoplay"] as? Bool ?? false
    setUpPlayer(path: path, looping: looping, autoplay: autoplay)
  }

  func view() -> UIView {
    containerView
  }

  private func setUpPlayer(path: String, looping: Bool, autoplay: Bool) {
    let url = URL(fileURLWithPath: path)
    let item = AVPlayerItem(url: url)
    let queuePlayer = AVQueuePlayer()
    containerView.playerLayer.player = queuePlayer

    // presentationSizeは回転メタを反映済みの「実際に表示される向き」の
    // サイズなので、これをそのままDart側のアスペクト比として使う。
    presentationSizeObservation = item.observe(\.presentationSize, options: [.new]) {
      [weak self] _, change in
      guard let size = change.newValue, size.width > 0, size.height > 0 else { return }
      self?.channel.invokeMethod(
        "onVideoSize",
        arguments: ["width": Double(size.width), "height": Double(size.height)]
      )
    }

    if looping {
      // ループ再生はAVPlayerLooperにまかせ、フレーム落ちのない切り替えにする。
      looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
    } else {
      queuePlayer.insert(item, after: nil)
    }

    player = queuePlayer
    if autoplay {
      queuePlayer.play()
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "play":
      player?.play()
      result(nil)
    case "pause":
      player?.pause()
      result(nil)
    case "setLooping":
      // AVPlayerLooperは生成時にのみ設定できるため、生成後の切り替えは未対応。
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  deinit {
    player?.pause()
    channel.setMethodCallHandler(nil)
  }
}
