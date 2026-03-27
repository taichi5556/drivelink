# DriveVoice 引き継ぎ資料 v6（2026/03/28更新）

## アプリ基本情報
- アプリ名: DriveVoice
- Bundle ID: com.itoutaichi.drivelink
- バージョン: 1.0.1（Build 5）← 最新！
- GitHub: https://github.com/taichi5556/drivelink（プライベート）
- プロジェクトパス: ~/projects/drivelink
- プライバシーポリシー: https://taichi5556.github.io/drivelink/privacy_policy.html

## 重要ID・キー
- Agora App ID: 9b3f59b1a52245b88a7cfbd33236f333
- Google Maps API Key: AIzaSyDXDhBtGYtEET-8xpnUHJV-KJZRkjnVH-c
- Firebase プロジェクトID: drivelink-a7ffb
- Firebase プロジェクト番号: 443481896764

## アカウント情報
- Apple ID: ta644644ta@yahoo.co.jp
- Google/Firebase: taichi5556@gmail.com
- Play Console: drivevoice.support@gmail.com
- GitHub: taichi5556

## iOS状況（最新）
- ステータス: 🟡 審査待ち（2026/03/28 0:43提出）
- 提出バージョン: 1.0.1 Build 5
- 提出ID: 67aef3e8-4c59-4938-8130-d4dac7045ae6
- リジェクト理由（対応済み）:
  - 1.5.0 Safety: サポートURL修正済み
  - 2.1.0 Performance: デモ動画提出済み・バグ修正済み

## iOS再提出の手順（次回用）
1. flutter build ipa --release
2. open ~/projects/drivelink/build/ios/ipa/
3. open -a Transporter → IPAをドラッグ → Deliver
4. App Store Connect → iOS App 1.0 → ビルドセクション
5. 青い数字にホバー → 赤い丸クリックで旧ビルド削除
6. ＋で新ビルド選択 → 審査へ提出

## Android状況
- Play Console登録完了・本人確認待ち
- ビルドコマンド: flutter build apk --release --target-platform android-arm64
- APK場所: ~/projects/drivelink/build/app/outputs/flutter-apk/
- 署名キーパスワード: z3wu6ghm
- 最新APK: DriveVoice_20260327.apk（Googleドライブ保存済み）

## 収益化プラン
- Phase 1: 全機能無料
- Phase 2: 無料（音声のみ）/ Standard ¥500 / Premium ¥980

## コード構成（重要ファイル）
- メイン画面: ~/projects/drivelink/lib/screens/main_screen.dart
- ログイン画面: ~/projects/drivelink/lib/screens/login_screen.dart
- エントリーポイント: ~/projects/drivelink/lib/main.dart
- Firebase設定: ~/projects/drivelink/lib/firebase_options.dart
- Podfile: ~/projects/drivelink/ios/Podfile

## 修正済みバグ履歴
1. 2026/03/27: iPadで「iPhoneテストさんが話しています」と表示されるバグ
   → main_screen.dart の _listenToRecordingUser() を修正
   → (_members[val] as Map?)?['nickname'] でUID直接参照に変更

2. 2026/03/27-28: シミュレーターコードがIPAに混入してTransporterでリジェクト
   → ios/Podfile の post_install に EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64 を追加
   → バージョンを1.0.1+5に変更して解決

## Transporterエラー対応（記録）
- エラー: objective_c.framework にシミュレーターsliceが混入
- 解決: Podfileのpost_installブロックを統合してEXCLUDED_ARCHSを設定

## App Store Connect ビルド変更方法（重要！）
- ビルドセクションの青い数字にマウスをホバー（クリックしない）
- 赤い丸が出たらクリック → 旧ビルド削除
- ＋ボタンで新ビルドを選択

## AIへの指示ルール
- 変更前に説明してから実行
- ターミナルコマンドで自動修正
- 一歩ずつ確認しながら進める
- 専門用語を最小限に
- 新しい会話開始時は必ずこの資料を読む

## 新しい会話を始めるときのコマンド（ユーザー辞書「dv」登録済み）
cat ~/projects/drivelink/HANDOVER.md && echo "=== main_screen.dart ===" && cat ~/projects/drivelink/lib/screens/main_screen.dart && echo "=== login_screen.dart ===" && cat ~/projects/drivelink/lib/screens/login_screen.dart && echo "=== main.dart ===" && cat ~/projects/drivelink/lib/main.dart
