dart_path = '/Users/itoutaichi/projects/drivelink/lib/screens/main_screen.dart'
kt_path = '/Users/itoutaichi/projects/drivelink/android/app/src/main/kotlin/com/itoutaichi/drivelink/auto/DriveVoiceMethodChannel.kt'

with open(dart_path, 'r') as f:
    dart = f.read()

with open(kt_path, 'r') as f:
    kt = f.read()

# ===== Fix1: audioScenario =====
old = 'scenario: AudioScenarioType.audioScenarioChatroom,'
new = 'scenario: AudioScenarioType.audioScenarioGameStreaming,'
if old in dart:
    dart = dart.replace(old, new)
    print('✅ Fix1: audioScenarioGameStreaming')
else:
    print('⚠️ Fix1: 既に適用済み')

# ===== Fix2: 送話開始時にenableAudio追加 =====
old = '''    if (!_agoraJoined) {
      debugPrint('Agora未接続のため録音不可');
      return;
    }
    // Agoraのマイク送信を開始'''
new = '''    if (!_agoraJoined) {
      debugPrint('Agora未接続のため録音不可');
      return;
    }
    // 送話時のみAgoraオーディオを有効化
    await _agoraEngine?.enableAudio();
    await _agoraEngine?.setDefaultAudioRouteToSpeakerphone(true);
    // Agoraのマイク送信を開始'''
if old in dart:
    dart = dart.replace(old, new)
    print('✅ Fix2: 送話開始時enableAudio')
else:
    print('⚠️ Fix2: 既に適用済みまたは未発見')

# ===== Fix3: 送話停止時にdisableAudio追加 =====
old = '''    await _db.child('rooms/${widget.roomCode}/recording_user').remove();
    if (mounted) setState(() => _isRecording = false);
    debugPrint('Agora録音停止');'''
new = '''    await _db.child('rooms/${widget.roomCode}/recording_user').remove();
    // 送話終了後Agoraオーディオ無効化（音楽ステレオ復帰）
    await _agoraEngine?.disableAudio();
    if (mounted) setState(() { _isRecording = false; _recordSeconds = 0; });
    debugPrint('Agora録音停止');'''
if old in dart:
    dart = dart.replace(old, new)
    print('✅ Fix3: 送話停止時disableAudio')
else:
    print('⚠️ Fix3: 既に適用済みまたは未発見')

# ===== Fix4: 受信時enableAudio/disableAudio追加 =====
old = '''      if (mounted) {
        setState(() {
          _isOtherRecording = val != null && val != widget.userId;
          if (_isOtherRecording) _fromNickname = otherNick;
          _showReceiving = _isOtherRecording;
        });
      }'''
new = '''      final wasReceiving = _isOtherRecording;
      final isNowReceiving = val != null && val != widget.userId;
      if (!wasReceiving && isNowReceiving) {
        await _agoraEngine?.enableAudio();
        await _agoraEngine?.setDefaultAudioRouteToSpeakerphone(true);
      } else if (wasReceiving && !isNowReceiving) {
        await _agoraEngine?.disableAudio();
      }
      if (mounted) {
        setState(() {
          _isOtherRecording = isNowReceiving;
          if (_isOtherRecording) _fromNickname = otherNick;
          _showReceiving = _isOtherRecording;
        });
      }'''
if old in dart:
    dart = dart.replace(old, new)
    print('✅ Fix4: 受信時enableAudio/disableAudio')
else:
    print('⚠️ Fix4: 既に適用済みまたは未発見')

# ===== Fix5: Kotlin stopBluetoothSco削除 =====
old_sco = '''            audioManager.isBluetoothScoOn = false
            audioManager.stopBluetoothSco()'''
new_sco = '''            // SCO停止は車のBT切断を引き起こすため削除'''
if old_sco in kt:
    kt = kt.replace(old_sco, new_sco)
    print('✅ Fix5: stopBluetoothSco削除')
else:
    print('⚠️ Fix5: 既に適用済み')

# ===== Fix6: Kotlin MODE_NORMAL追加 =====
old_mode = '''            android.util.Log.d("DriveVoice", "AudioFocus解放")'''
new_mode = '''            audioManager.mode = AudioManager.MODE_NORMAL
            android.util.Log.d("DriveVoice", "AudioFocus解放・A2DP復帰")'''
if old_mode in kt:
    kt = kt.replace(old_mode, new_mode)
    print('✅ Fix6: MODE_NORMAL追加')
else:
    print('⚠️ Fix6: 既に適用済み')

with open(dart_path, 'w') as f:
    f.write(dart)

with open(kt_path, 'w') as f:
    f.write(kt)

print('\n全修正完了！')
