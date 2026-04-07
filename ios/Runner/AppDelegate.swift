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
    // setupAudioSessionOnce() 削除 → 起動時のYouTube音量低下を防ぐ
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
    guard audioChannel == nil, let vc = getFlutterViewController() else { return }
    audioChannel = FlutterMethodChannel(name: "drivelink/audio", binaryMessenger: vc.binaryMessenger)
    audioChannel?.setMethodCallHandler { (call, result) in
      switch call.method {
      case "requestAudioFocus", "abandonAudioFocus":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    print("drivelink/audio チャンネル登録完了")
  }

  private func getFlutterViewController() -> FlutterViewController? {
    if let vc = window?.rootViewController as? FlutterViewController { return vc }
    for scene in UIApplication.shared.connectedScenes {
      if let ws = scene as? UIWindowScene {
        for w in ws.windows {
          if let vc = w.rootViewController as? FlutterViewController { return vc }
        }
      }
    }
    return nil
  }

  override func application(
    _ app: UIApplication, open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return super.application(app, open: url, options: options)
  }
}
