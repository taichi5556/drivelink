import Flutter
import UIKit
import GoogleMaps
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var audioChannel: FlutterMethodChannel?
  private var silentPlayer: AVAudioPlayer?

  override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    GMSServices.provideAPIKey("AIzaSyDXDhBtGYtEET-8xpnUHJV-KJZRkjnVH-c")
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playAndRecord,
        mode: .default,
        options: [.defaultToSpeaker, .allowBluetooth]
      )
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("AVAudioSession error: \(error)")
    }
    GeneratedPluginRegistrant.register(with: self)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.setupChannelIfNeeded() }
    return result
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    setupChannelIfNeeded()
  }

  private func setupChannelIfNeeded() {
    guard audioChannel == nil, let vc = getFlutterViewController() else { return }
    audioChannel = FlutterMethodChannel(name: "drivelink/audio", binaryMessenger: vc.binaryMessenger)
    audioChannel?.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {

      case "requestAudioFocus":
        // PTT送信: .playAndRecord（マイク使用、YouTubeは継続）
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
          options: [.allowBluetoothA2DP, .mixWithOthers])
        try? session.setActive(true)
        result(nil)

      case "requestReceiveFocus":
        // 受信: Agora音声を聞こえるようにする
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        result(nil)

      case "abandonAudioFocus":
        // PTT終了: .playAndRecord + .allowBluetooth に戻す（App Store版と同じ）
        result(nil)
        self?.stopSilentAudio()
        DispatchQueue.global(qos: .userInitiated).async {
          let session = AVAudioSession.sharedInstance()
          try? session.setCategory(.playAndRecord, mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
          try? session.setActive(true)
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
    print("drivelink/audio チャンネル登録完了")
  }

  // 無音WAVをメモリ上で生成してループ再生
  private func startSilentAudio() {
    guard silentPlayer == nil else { return }
    // 44バイトのWAVヘッダー + 4410サンプル(0.1秒)の無音データ
    let sampleRate: UInt32 = 44100
    let numSamples: UInt32 = 4410
    let dataSize: UInt32 = numSamples * 2
    var wav = Data()
    func appendUInt32(_ v: UInt32) { var x = v.littleEndian; wav.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) }) }
    func appendUInt16(_ v: UInt16) { var x = v.littleEndian; wav.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) }) }
    wav.append(contentsOf: "RIFF".utf8); appendUInt32(36 + dataSize)
    wav.append(contentsOf: "WAVE".utf8)
    wav.append(contentsOf: "fmt ".utf8); appendUInt32(16)
    appendUInt16(1); appendUInt16(1); appendUInt32(sampleRate)
    appendUInt32(sampleRate * 2); appendUInt16(2); appendUInt16(16)
    wav.append(contentsOf: "data".utf8); appendUInt32(dataSize)
    wav.append(Data(count: Int(dataSize)))
    silentPlayer = try? AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue)
    silentPlayer?.numberOfLoops = -1
    silentPlayer?.volume = 0.0
    silentPlayer?.play()
    print("無音ループ開始")
  }

  private func stopSilentAudio() {
    silentPlayer?.stop()
    silentPlayer = nil
    print("無音ループ停止")
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

  override func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    return super.application(app, open: url, options: options)
  }
}
