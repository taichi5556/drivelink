import 'package:flutter/services.dart';

class AndroidAutoService {
  static const _channel = MethodChannel(
    'com.itoutaichi.drivelink/android_auto',
  );

  static Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'startTalking':
          // TODO: Agoraの送話開始処理を呼ぶ
          print('Android Auto: 送話開始');
          break;
        case 'stopTalking':
          // TODO: Agoraの送話停止処理を呼ぶ
          print('Android Auto: 送話停止');
          break;
      }
    });
  }

  // メンバー状態をAndroid Autoに送信
  static Future<void> updateMemberStatus({
    required int count,
    required String speaker,
  }) async {
    try {
      await _channel.invokeMethod('updateMemberStatus', {
        'count': count,
        'speaker': speaker,
      });
    } catch (e) {
      // Android Auto未接続時は無視
    }
  }

  // 音声受信をAndroid Autoに通知
  static Future<void> notifyVoiceReceived(String speakerName) async {
    try {
      await _channel.invokeMethod('onVoiceReceived', {
        'name': speakerName,
      });
    } catch (e) {
      // Android Auto未接続時は無視
    }
  }
}
