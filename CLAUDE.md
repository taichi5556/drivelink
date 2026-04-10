# TouriLink - Claude作業引き継ぎ資料

## ユーザー・操作スタイル
- **初心者向けに説明すること**: 手順は番号付きで一つずつ、図や例を交えて分かりやすく
- コードを変更する前に必ず「何をどう変えるか」を日本語で説明してから実施
- 変更は**一つずつ**実装して動作確認してから次に進む
- **常に日本語で応答すること**

---

## 基本情報
- アプリ名: TouriLink（ツーリンク）（Bundle ID: com.itoutaichi.drivelink）
- Flutter + Firebase Realtime Database + Google Maps + AdMob
- **Agoraは削除済み**（音声通話機能なし）
- メイン画面: `lib/screens/main_screen.dart`
- iOS native: `ios/Runner/AppDelegate.swift`
- 招待リンク: `https://drivelink-a7ffb.web.app/join?room=CODE` → `drivevoice://join?room=CODE` にリダイレクト
- プライバシーポリシー: `https://taichi5556.github.io/drivelink/privacy_policy.html`
- app-ads.txt: `https://taichi5556.github.io/app-ads.txt`

---

## よく使うコマンド

### 実機デバッグ起動
```bash
# iPhone実機
flutter run --release -d 00008150-001865A41E38401C

# Android実機（ワイヤレス）
flutter run --release -d 192.168.0.26:44769
# または
flutter run --release -d SCG08
```

### ビルド
```bash
# Android: Google Play用AAB
flutter build appbundle --release

# Android: テスター配布用APK
flutter build apk --release

# iOS: App Store用IPA
flutter build ipa --release
```

ビルド成果物:
- AAB: `build/app/outputs/bundle/release/app-release.aab`
- APK: `build/app/outputs/flutter-apk/app-release.apk`
- IPA: `build/ios/ipa/TouriLink.ipa`

### バージョン更新
`pubspec.yaml` の `version: X.X.X+XX` を編集（versionName+versionCode）
- 現在のバージョン: `1.1.6+37`

---

## AdMob設定

### iOS
- App ID: `ca-app-pub-4544332023567609~3044889361`（Info.plist: GADApplicationIdentifier）
- バナー広告ユニットID: `ca-app-pub-4544332023567609/6687240610`

### Android
- App ID: `ca-app-pub-4544332023567609~2103342785`（AndroidManifest.xml）
- バナー広告ユニットID: `ca-app-pub-4544332023567609/4801658317`

### パブリッシャーID
- `pub-4544332023567609`

---

## iOS AppDelegate.swift の現状
Agora削除後はシンプルな構成：
```swift
import Flutter
import UIKit
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(...) -> Bool {
    GMSServices.provideAPIKey("...")
    GeneratedPluginRegistrant.register(with: self)
    return super.application(...)
  }
}
```
- AVAudioSession管理は不要（Agora削除済み）
- drivelink/audioチャンネルは削除済み

---

## バックアップブランチ
```bash
git checkout backup/before-agora-removal  # Agora削除後の現在の作業ブランチ
git checkout backup/before-bluetooth-fix  # 古い安全な状態（Agora有り）
```

---

## 未実装・残課題
- Firebase古いルーム自動削除（24時間以上前に期限切れのルームを削除）
- 通話モードでのマップマーカー色分け

---

## 将来の計画

### PTTトランシーバーアプリ（drivevoice_ptt）
- **別プロジェクト**として新規作成予定（`/Users/itoutaichi/projects/drivevoice_ptt`）
- TouriLinkのルームコードをディープリンクでPTTアプリに渡して同じルームに自動参加
- TouriLinkに「PTTで通話する」ボタンを追加し、drivevoice_pttを起動する
- PTTアプリはAgora RTCを使ったトランシーバー方式（長押し送信 or タップ送信）
- TouriLinkとdrivevoice_pttは独立したアプリとして動作し、Firebaseルームを共有する
- ディープリンク形式: `drivevoice://join?room=ROOMCODE`

---

## GitHub管理
- メインリポジトリ: `https://github.com/taichi5556/drivelink`
- GitHub Pages（プライバシーポリシー）: `https://github.com/taichi5556/drivelink` の `docs/` フォルダ
- GitHub Pages（app-ads.txt）: `https://github.com/taichi5556/taichi5556.github.io`
