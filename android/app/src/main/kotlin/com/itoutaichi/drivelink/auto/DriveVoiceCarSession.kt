package com.itoutaichi.drivelink.auto

import android.content.Intent
import androidx.car.app.Screen
import androidx.car.app.Session

class DriveVoiceCarSession : Session() {

    override fun onCreateScreen(intent: Intent): Screen {
        return DriveVoiceMainCarScreen(carContext)
    }
}
