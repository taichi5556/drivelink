import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase C: ナビ音声案内のシングルトン Service。
/// - 言語: ja-JP / レート: 0.5 / 音量: 1.0
/// - iOS: AVAudioSession.Category.playback + duckOthers で BGM を下げて案内
///   （Bluetooth モノラル化は既知リスクとして受容）
/// - 有効/無効は SharedPreferences (key: voice_guidance_enabled) で永続化、デフォルト ON
class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  static const _kEnabledKey = 'voice_guidance_enabled';

  final FlutterTts _tts = FlutterTts();
  bool _enabled = true;
  bool _initStarted = false;
  bool _initialized = false;

  bool get isEnabled => _enabled;

  Future<void> init() async {
    if (_initStarted) return;
    _initStarted = true;

    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabledKey) ?? true;

    try {
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [IosTextToSpeechAudioCategoryOptions.duckOthers],
      );
    } catch (_) {
      // Android では setIosAudioCategory は no-op（例外時もスキップ）
    }

    await _tts.setLanguage('ja-JP');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _initialized = true;
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, value);
    if (!value) {
      await _tts.stop();
    }
  }

  Future<void> speak(String text) async {
    if (!_initialized || !_enabled || text.isEmpty) return;
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> stop() async {
    await _tts.stop();
  }
}
