# DriveVoice - Claude作業引き継ぎ資料

## ユーザー・操作スタイル
- **初心者向けに説明すること**: 手順は番号付きで一つずつ、図や例を交えて分かりやすく
- コードを変更する前に必ず「何をどう変えるか」を日本語で説明してから実施
- 変更は**一つずつ**実装して動作確認してから次に進む
- **常に日本語で応答すること**

---

## 基本情報
- アプリ名: DriveVoice（Bundle ID: com.itoutaichi.drivelink）
- Flutter + Agora RTC + Firebase Realtime Database
- メイン画面: `lib/screens/main_screen.dart`
- iOS native: `ios/Runner/AppDelegate.swift`
- 招待リンク: `https://drivelink-a7ffb.web.app/join?room=CODE` → `drivevoice://join?room=CODE` にリダイレクト

---

## よく使うコマンド

### 実機デバッグ起動
```bash
# iPhone実機
flutter run --release -d 00008150-001865A41E38401C

# Android実機（ワイヤレス）
flutter run --release -d 192.168.0.26:44769
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
- IPA: `build/ios/ipa/DriveVoice.ipa`

### バージョン更新
`pubspec.yaml` の `version: X.X.X+XX` を編集（versionName+versionCode）

---

## バックアップブランチ
```bash
git checkout backup/before-bluetooth-fix  # 動作確認済みの安全な状態
git restore ios/Runner/AppDelegate.swift lib/screens/main_screen.dart  # 変更破棄
```

---

## ドライブモード / 通話モード仕様

### 変数
```dart
String _voiceMode = 'drive'; // 'drive' or 'talk'
```

### ドライブモード（デフォルト）
- Agoraチャンネルに**audienceとして参加**（音声受信のみ）
- PTTボタンは無効（ジェスチャーハンドラが null）
- ボタン外観：暗い青色、イヤホンアイコン、「受信のみ（ドライブモード）」
- Bluetooth音楽を保護：`audioSessionRestriction:128` によりAgoraがAVAudioSessionを変更しない
- iOS音声: `.playback` + `.mixWithOthers` + `.allowBluetoothA2DP`

### 通話モード
- Agoraチャンネルにbroadcasterとしてロール変更
- PTTボタンが有効（長押しで送信）
- ボタン外観：オレンジ色、通常のPTT表示

### モード切替処理（`_onModeSwitchTap`）
```
Drive → Talk:
  1. 警告ダイアログ表示（「音楽アプリは使用できなくなります」）
  2. _joinAgoraChannel() → updateChannelMediaOptions(broadcaster)
  3. setState(_voiceMode = 'talk')

Talk → Drive:
  1. _leaveAgoraChannel() → updateChannelMediaOptions(audience) + muteLocalAudioStream(true) + iOS restoreSession
  2. setState(_voiceMode = 'drive')
```

### UIウィジェット（`_buildModeSwitch`）
- PTTボタンの左横に縦型2ボタントグル
- Drive: 青色（アクティブ）/ Talk: オレンジ色（アクティブ）
- 両ボタンに `HitTestBehavior.opaque` 設定済み（透明時もタップ検出）

---

## Agora初期化の重要な順序

```dart
// _initAgora() の正しい順序
1. initialize(appId)
2. setParameters('audioSessionRestriction: 128')  // ← enableAudio()より必ず前
3. setParameters('bt.hfp: false')                 // ← enableAudio()より必ず前
4. setClientRole(audience)
5. enableAudio()
6. muteLocalAudioStream(true)
7. setAudioProfile(musicHighQuality, chatroom)
8. setDefaultAudioRouteToSpeakerphone(true)
9. registerEventHandler()
10. joinChannel(audience, autoSubscribeAudio: true, publishMicrophoneTrack: false)
// ドライブモードでもaudienceとして参加（audioSessionRestriction:128でBluetooth保護）
```

**絶対禁止**: `setParameters(audioSessionRestriction)` を `enableAudio()` より後に置くと
Bluetooth音楽が停止したり音質が劣化する。

### _joinAgoraChannel()（Drive→Talk切替時）
```dart
updateChannelMediaOptions(broadcaster, publishMicrophoneTrack: false, autoSubscribeAudio: true)
// joinChannel()は呼ばない（すでに参加済み）
```

### _leaveAgoraChannel()（Talk→Drive切替時）
```dart
updateChannelMediaOptions(audience, publishMicrophoneTrack: false, autoSubscribeAudio: true)
muteLocalAudioStream(true)
iOS: audioChannel.invokeMethod('restoreSession')
// leaveChannel()は呼ばない（audienceのまま継続参加）
```

---

## PTTの仕組み

### ボタンジェスチャー
```dart
onLongPressStart: (_voiceMode == 'drive' || _isOtherRecording) ? null : (_) => _startRecording()
onLongPressEnd:   (_voiceMode == 'drive' || _isOtherRecording) ? null : (_) => _stopRecording()
onTapDown:        _voiceMode == 'drive' ? null : (_) => muteLocalAudioStream(false)
```

### _startRecording() の主要チェック
```dart
if (_isOtherRecording || _isRecording) return;
if (!_agoraJoined) return; // 接続前の安全ガード
iOS: requestAudioFocus（HFP防止のためspeaker固定）
updateChannelMediaOptions(publishMicrophoneTrack: true)
Firebase recording_user にuserIdをセット
muteLocalAudioStream(false)
```

### _stopRecording()
```dart
updateChannelMediaOptions(publishMicrophoneTrack: false)
muteLocalAudioStream(true)
Firebase recording_user を削除
iOS: abandonAudioFocus
finally: _isRecording = false（エラーでも必ずリセット）
```

---

## iOS AVAudioSession管理（AppDelegate.swift）

| メソッド | カテゴリ | 用途 |
|---|---|---|
| 起動時 | `.playback` + `.mixWithOthers` + `.allowBluetoothA2DP` | アプリ起動時の初期設定 |
| `restoreSession` | `.playback` + `.mixWithOthers` + `.allowBluetoothA2DP` | ドライブモード復帰時 |
| `requestAudioFocus` | `.playAndRecord` + `.mixWithOthers` + `.allowBluetoothA2DP` | PTT送信開始時 |
| `abandonAudioFocus` | `.playAndRecord` + `.defaultToSpeaker` + `.allowBluetooth` + 非同期 | PTT送信終了時 |
| `requestReceiveFocus` | `.playback` + `.mixWithOthers` | PTT受信時（定義済みだが現在未使用） |

---

## 過去の失敗と教訓

### ❌ やってはいけないこと
1. `setParameters(audioSessionRestriction)` を `enableAudio()` より後に設定
   → Bluetooth音質劣化・音楽停止の原因
2. Agoraの初期化・チャンネル参加処理を大きく変更すること全般
   → 必ずバックアップブランチで動作確認してから変更すること
3. ドライブモード時に `updateChannelMediaOptions(broadcaster)` を呼ぶ
   → PTT送信が意図せず有効になる

### ✅ 現在の正しい設計
- ドライブモード起動時: audienceとしてchannelに参加（音声受信のみ）
- 通話モード切替時: `updateChannelMediaOptions(broadcaster)` でロール変更
- ドライブモード切替時: `updateChannelMediaOptions(audience)` でロール変更 + restoreSession

---

## 将来の計画
- **PTTトランシーバーアプリ（drivevoice_ptt）を別途作成予定**
  - DriveVoiceのルームコードをディープリンクでPTTアプリに渡して同じルームに自動参加できるようにする
  - DriveVoiceに「PTTで通話する」ボタンを追加予定

---

## 未実装・残課題
- Firebase古いルーム自動削除（24時間以上前に期限切れのルームを削除）
- 通話モードでのマップマーカー色分け（talk=オレンジ, drive=シアン）
- **PTT方式の変更（慎重に実装すること）**:
  - 長押し → タップで録音開始、もう1タップで送信に変更
  - 最大録音時間を30秒 → 20秒に変更
  - 画面上のカウントダウンも20秒に合わせて変更
  - バイブレーションは1回目（録音開始）・2回目（送信）ともに継続して必要
  - PTTボタンの表示文字も変更する（通話モードのみ）: 待機中→「タップして録音」、録音中→「タップして送信」
  - ドライブモードのボタン表示は「受信のみ（ドライブモード）」のまま変更しない
  - 他の機能を壊さないよう変更は最小限に
