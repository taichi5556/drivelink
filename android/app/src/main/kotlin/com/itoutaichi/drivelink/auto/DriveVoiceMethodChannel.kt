package com.itoutaichi.drivelink.auto

import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngine
import android.content.Context
import android.media.AudioManager
import android.media.AudioFocusRequest
import android.os.Build

object DriveVoiceMethodChannel {

    private var channel: MethodChannel? = null
    private var audioChannel: MethodChannel? = null
    private var carScreen: DriveVoiceMainCarScreen? = null
    private var audioFocusRequest: AudioFocusRequest? = null

    fun setup(flutterEngine: FlutterEngine) {
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.itoutaichi.drivelink/android_auto"
        )

        // Flutterからの受信
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateMemberStatus" -> {
                    val count = call.argument<Int>("count") ?: 0
                    val speaker = call.argument<String>("speaker") ?: ""
                    carScreen?.updateStatus(count, speaker)
                    result.success(null)
                }
                "onVoiceReceived" -> {
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // AudioFocusチャンネル（ダッキング用）
        audioChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "drivelink/audio"
        )

        audioChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestAudioFocus" -> {
                    requestAudioFocus(flutterEngine)
                    result.success(true)
                }
                "abandonAudioFocus" -> {
                    abandonAudioFocus(flutterEngine)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requestAudioFocus(flutterEngine: FlutterEngine) {
        try {
            val context = flutterEngine.dartExecutor.binaryMessenger
                .javaClass
                .getDeclaredField("applicationContext")
                .also { it.isAccessible = true }
                .get(flutterEngine.dartExecutor.binaryMessenger) as? Context
            // contextが取れない場合はMainActivityから取得するため
            // MainActivity側でも設定する
        } catch (e: Exception) {
            android.util.Log.e("DriveVoice", "AudioFocus context error: ${e.message}")
        }
    }

    private fun abandonAudioFocus(flutterEngine: FlutterEngine) {
        // MainActivity側で処理
    }

    fun requestAudioFocusFromContext(context: Context) {
        try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            // Bluetooth HFP SCO（着信中表示）を明示的に停止
            @Suppress("DEPRECATION")
            // SCO停止は車のBT切断を引き起こすため削除
            // HFP無効化はAgora側(che.audio.enable.bt.hfp:false)で対応
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = AudioFocusRequest.Builder(
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                ).build()
                audioFocusRequest = request
                audioManager.requestAudioFocus(request)
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(
                    null,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                )
            }
            android.util.Log.d("DriveVoice", "AudioFocus取得")
        } catch (e: Exception) {
            android.util.Log.e("DriveVoice", "AudioFocus取得エラー: ${e.message}")
        }
    }

    fun abandonAudioFocusFromContext(context: Context) {
        try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(null)
            }
            // A2DP復帰のためMODE_NORMALに強制復元
            audioManager.mode = AudioManager.MODE_NORMAL
            android.util.Log.d("DriveVoice", "AudioFocus解放・A2DP復帰")
        } catch (e: Exception) {
            android.util.Log.e("DriveVoice", "AudioFocus解放エラー: ${e.message}")
        }
    }

    // Android AutoからFlutterへ送信
    fun sendToFlutter(action: String) {
        channel?.invokeMethod(action, null)
    }

    fun setCarScreen(screen: DriveVoiceMainCarScreen) {
        carScreen = screen
    }
}
