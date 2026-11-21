package com.photohub.compressor

import android.app.Application
import com.photohub.compressor.background.BackgroundBackupManager

class PhotoHubApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        BackgroundBackupManager.getInstance(this).ensureMediaObserverAndSchedule()
    }
}
