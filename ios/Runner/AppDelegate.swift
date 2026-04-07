import Flutter
import UIKit
import GoogleMaps
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {

  private var audioChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GMSServices.provideAPIKey("AIzaSyDXDhBtGYtEET-8xpnUHJV-KJZRkjnVH-c")
    GeneratedPluginRegistrant.register(with: self)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    configureAudioSession(forRecording: false)
    // Scene ベースのライフサイクルに対応するため遅延登録
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      self.setupChannelIfNeeded()
    }
    return result
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    setupChannelIfNeeded()
  }

  private func setupChannelIfNeeded() {
    guard audioChannel == nil,
          let vc = getFlutterViewController() else { return }
    audioChannel = FlutterMethodChannel(
      name: "drivelink/audio",
      binaryMessenger: vc.binaryMessenger
    )
    audioChannel?.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "requestAudioFocus":
        self?.configureAudioSession(forRecording: true)
        result(nil)
      case "abandonAudioFocus":
        self?.configureAudioSession(forRecording: false)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    print("drivelink/audio チャンネル登録完了")
  }

  private func getFlutterViewController() -> FlutterViewController? {
    // 通常の window から試す
    if let vc = window?.rootViewController as? FlutterViewController {
      return vc
    }
    // UIScene ベース（iOS13+）から試す
    for scene in UIApplication.shared.connectedScenes {
      if let ws = scene as? UIWindowScene {
        for w in ws.windows {
          if let vc = w.rootViewController as? FlutterViewController {
            return vc
          }
        }
      }
    }
    return nil
  }

  private func configureAudioSession(forRecording: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
      if forRecording {
        try session.setCategory(
          .playAndRecord,
          mode: .voiceChat,
          options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers, .mixWithOthers]
        )
      } else {
        try session.setCategory(
          .playback,
          mode: .default,
          options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP]
        )
      }
      try session.setActive(true)
    } catch {
      print("AVAudioSession error: \(error)")
    }
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return super.application(app, open: url, options: options)
  }
}
