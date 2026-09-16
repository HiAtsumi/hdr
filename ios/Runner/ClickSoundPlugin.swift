import AudioToolbox
import Flutter

/// Ultra-low-latency UI tap sound via Apple's System Sound Services — the
/// same mechanism `SystemSoundType.click` itself uses, but playing our own
/// gentler sound instead of the harsh built-in keyboard click.
///
/// AVAudioPlayer-based playback (what the audioplayers package uses) has to
/// activate/verify the audio session and prepare a buffer on every call,
/// which is audible as sluggishness for a tap sound that needs to feel
/// instant. AudioServices is built specifically for short (<30s),
/// instant-latency UI sound effects and skips all of that.
final class ClickSoundPlugin: NSObject {
  private var soundID: SystemSoundID = 0

  static func register(with registrar: FlutterApplicationRegistrar) {
    let instance = ClickSoundPlugin()
    instance.loadSound()

    let channel = FlutterMethodChannel(
      name: "com.eonlineservice.hdr/click_sound",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "play":
        if instance.soundID != 0 {
          AudioServicesPlaySystemSound(instance.soundID)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func loadSound() {
    let key = FlutterDartProject.lookupKey(forAsset: "assets/sounds/click.wav")
    guard let path = Bundle.main.path(forResource: key, ofType: nil) else { return }
    AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &soundID)
  }

  deinit {
    if soundID != 0 {
      AudioServicesDisposeSystemSoundID(soundID)
    }
  }
}
