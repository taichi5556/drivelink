import re

dart_path = '/Users/itoutaichi/projects/drivelink/lib/screens/main_screen.dart'
kt_path = '/Users/itoutaichi/projects/drivelink/android/app/src/main/kotlin/com/itoutaichi/drivelink/auto/DriveVoiceMethodChannel.kt'

with open(dart_path, 'r') as f:
    dart = f.read()

with open(kt_path, 'r') as f:
    kt = f.read()

# ===== Dart修正1: audioScenarioChatroom → GameStreaming =====
old = 'scenario: AudioScenarioType.audioScenarioChatroom,'
new = 'scenario: AudioScenarioType.audioScenarioGameStreaming,'
if old in dart:
    dart = dart.replace(old, new)
    print('✅ Fix1: audioScenarioGameStreaming')
else:
    print('⚠️ Fix1: 既に適用済みまたは未発見')

# ===== Dart修正2: 受信開始時にenableAudio追加 =====
old = '''        await _requestAudioFocus();   // ダッキング開始
      } else if (wasReceiving && !isNowReceiving) {
        await _abandonAudioFocus();   // ダッキング解除
        await _releaseAgora();        // release Agora (stereo recovery)'''
new = '''        await _agoraEngine?.enableAudio();
        await _agoraEngine?.setDefaultAudioRouteToSpeakerphone(true);
        await _requestAudioFocus();   // ダッキング開始
      } else if (wasReceiving && !isNowReceiving) {
        await _agoraEngine?.disableAudio();
        await _abandonAudioFocus();   // ダッキング解除'''
if old in dart:
    dart = dart.replace(old, new)
    print('✅ Fix2: 受信時enableAudio/disableAudio')
else:
    print('⚠️ Fix2: 既に適用済みまたは未発見')

# ===== Dart修正3: 送話開始時にenableAudio追加 =====
old = '''    await _requestAudioFocus();
    // Agoraのマイク送信を開始'''
new = '''    await _requestAudioFocus();
    // 送話時のみAgoraオーディオを有効化
    await _agoraEngine?.enableAudio();
    await _agoraEngine?.setDefaultAudioRouteToSpeakerphone(true);
    // Agoraのマイク送信を開始'''
if old in dart:
    dart = dart.replace(old, new)
    print('✅ Fix3: 送話開始時enableAudio')
else:
    print('⚠️ Fix3: 既に適用済みまたは未発見')

# ===== Dart修正4: 送話停止時にdisableAudio追加・releaseAgora削除 =====
old = '''    await _db.child('rooms/${widget.roomCode}/recording_user').remove();
    // 音楽ダッキング解除
    await _abandonAudioFocus();'''
new = '''    await _db.child('rooms/${widget.roomCode}/recording_user').remove();
    // 送話終了後Agoraオーディオ無効化（音楽ステレオ復帰）
    await _agoraEngine?.disableAudio();
    // 音楽ダッキング解除
    await _abandonAudioFocus();'''
if old in dart:
    dart = dart.replace(old, new)
    print('✅ Fix4: 送話停止時disableAudio')
else:
    print('⚠️ Fix4: 既に適用済みまたは未発見')

# ===== Kotlin修正1: stopBluetoothSco削除 =====
old_sco = '''            audioManager.isBluetoothScoOn = false
            audioManager.stopBluetoothSco()'''
new_sco = '''            // SCO停止は車のBT切断を引き起こすため削除
            // HFP無効化はAgora側(che.audio.enable.bt.hfp:false)で対応'''
if old_sco in kt:
    kt = kt.replace(old_sco, new_sco)
    print('✅ Fix5: stopBluetoothSco削除')
else:
    print('⚠️ Fix5: 既に適用済みまたは未発見')

# ===== Kotlin修正2: abandonAudioFocus時にMODE_NORMAL追加 =====
old_mode = '''            android.util.Log.d("DriveVoice", "AudioFocus解放")
        } catch (e: Exception) {
            android.util.Log.e("DriveVoice", "AudioFocus解放エラー: ${e.message}")'''
new_mode = '''            // A2DP復帰のためMODE_NORMALに強制復元
            audioManager.mode = AudioManager.MODE_NORMAL
            android.util.Log.d("DriveVoice", "AudioFocus解放・A2DP復帰")
        } catch (e: Exception) {
            android.util.Log.e("DriveVoice", "AudioFocus解放エラー: ${e.message}")'''
if old_mode in kt:
    kt = kt.replace(old_mode, new_mode)
    print('✅ Fix6: MODE_NORMAL追加')
else:
    print('⚠️ Fix6: 既に適用済みまたは未発見')

with open(dart_path, 'w') as f:
    f.write(dart)

with open(kt_path, 'w') as f:
    f.write(kt)

print('\n完了！')
