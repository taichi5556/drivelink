package com.itoutaichi.drivelink.auto

import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.model.*

class DriveVoiceMainCarScreen(carContext: CarContext) : Screen(carContext) {

    private var isTalking = false
    private var currentSpeaker = ""
    private var memberCount = 0

    override fun onGetTemplate(): Template {

        // 🎙️ トランシーバーボタン
        val talkAction = Action.Builder()
            .setTitle(if (isTalking) "送信中..." else "長押しで送信")
            .setBackgroundColor(
                if (isTalking) CarColor.RED else CarColor.BLUE
            )
            .setOnClickListener {
                toggleTalking()
            }
            .build()

        // 👥 メンバー情報
        val memberRow = Row.Builder()
            .setTitle("オンライン: ${memberCount}人")
            .addText(
                if (currentSpeaker.isNotEmpty())
                    "${currentSpeaker}が話し中..."
                else
                    "待機中"
            )
            .build()

        return MessageTemplate.Builder(
            if (currentSpeaker.isNotEmpty())
                "${currentSpeaker}が話し中"
            else
                "DriveVoice"
        )
            .setHeaderAction(Action.APP_ICON)
            .addAction(talkAction)
            .build()
    }

    private fun toggleTalking() {
        isTalking = !isTalking
        DriveVoiceMethodChannel.sendToFlutter(
            if (isTalking) "startTalking" else "stopTalking"
        )
        invalidate()
    }

    fun updateStatus(count: Int, speaker: String) {
        memberCount = count
        currentSpeaker = speaker
        invalidate()
    }
}
