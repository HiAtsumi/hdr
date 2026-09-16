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
  private let channel: FlutterMethodChannel
  private var presentationSizeObservation: NSKeyValueObservation?
  private var itemDidEndObserver: NSObjectProtocol?
  // SNSアプリへ切り替える(共有シートを開く)などでバックグラウンドへ回ると、
  // システムがAVPlayerLayerの再生を強制停止し、表示中だったデコード済み
  // フレームも解放する。フォアグラウンド復帰時に自前で再生を再開しないと、
  // 再生済みフレームが無いままレイヤーが真っ黒に固定されてしまう。
  private var shouldBePlaying = false

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

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    guard let params = args as? [String: Any], let path = params["path"] as? String else {
      return
    }
    let looping = params["looping"] as? Bool ?? false
    let autoplay = params["autoplay"] as? Bool ?? false
    shouldBePlaying = autoplay
    setUpPlayer(path: path, looping: looping, autoplay: autoplay)
  }

  @objc private func applicationDidBecomeActive() {
    if shouldBePlaying {
      player?.play()
    }
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
      // AVQueuePlayer's default .advance behaviour removes an item from the
      // queue once it finishes — with only one item, that leaves currentItem
      // nil, so a later seek(to:)/play() on the player has nothing to act
      // on. .none keeps the (now-paused) item in place so the loop below can
      // rewind and replay it.
      queuePlayer.actionAtItemEnd = .none
    }
    queuePlayer.insert(item, after: nil)

    if looping {
      // AVPlayerLooper produced a runaway timeControlStatus churn (repeatedly
      // re-entering "playing" without visibly advancing) on some of our own
      // encoded HDR outputs — a plain end-of-item notification restarting
      // playback from zero is less clever but reliable for a single item.
      itemDidEndObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak queuePlayer] _ in
        queuePlayer?.seek(to: .zero)
        queuePlayer?.play()
      }
    }

    player = queuePlayer
    if autoplay {
      queuePlayer.play()
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "play":
      shouldBePlaying = true
      player?.play()
      result(nil)
    case "pause":
      shouldBePlaying = false
      player?.pause()
      result(nil)
    case "setLooping":
      // ループはitemDidEndObserverで固定的に設定しているため、生成後の切り替えは未対応。
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let itemDidEndObserver = itemDidEndObserver {
      NotificationCenter.default.removeObserver(itemDidEndObserver)
    }
    player?.pause()
    channel.setMethodCallHandler(nil)
  }
}
