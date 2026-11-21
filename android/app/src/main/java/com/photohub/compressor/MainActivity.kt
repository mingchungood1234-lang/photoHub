package com.photohub.compressor

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import com.photohub.compressor.auth.GoogleAuthManager
import com.photohub.compressor.background.BackgroundBackupManager
import com.photohub.compressor.ui.PhotoHubApp
import com.photohub.compressor.ui.theme.PhotoHubTheme

class MainActivity : ComponentActivity() {
    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) {
        val bg = BackgroundBackupManager.getInstance(applicationContext)
        bg.refreshNotificationPermissionLabel()
        bg.ensureMediaObserverAndSchedule()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        handleIncomingIntent(intent)
        requestStartupPermissionsIfNeeded()

        setContent {
            PhotoHubTheme {
                PhotoHubApp()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        GoogleAuthManager.getInstance(applicationContext).cancelPendingUiStateIfReturnedWithoutCallback()
        BackgroundBackupManager.getInstance(applicationContext).apply {
            pruneMissingAssetsFromStaged()
            refreshNotificationPermissionLabel()
            triggerSilentAutoUpload(isMovingToBackground = false)
        }
    }

    override fun onStop() {
        super.onStop()
        BackgroundBackupManager.getInstance(applicationContext).apply {
            scheduleBackgroundWorkersIfEnabled()
            triggerSilentAutoUpload(isMovingToBackground = true)
        }
    }

    private fun handleIncomingIntent(intent: Intent?) {
        intent ?: return
        GoogleAuthManager.getInstance(applicationContext).handleAuthCallbackIntent(intent)
        if (intent.getBooleanExtra(EXTRA_OPEN_CLEANUP, false)) {
            intent.removeExtra(EXTRA_OPEN_CLEANUP)
            BackgroundBackupManager.getInstance(applicationContext).markOpenCleanupFromNotification()
        }
    }

    private fun requestStartupPermissionsIfNeeded() {
        val needed = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            needed += Manifest.permission.READ_MEDIA_IMAGES
            needed += Manifest.permission.READ_MEDIA_VIDEO
            needed += Manifest.permission.POST_NOTIFICATIONS
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                needed += Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
            }
        } else {
            needed += Manifest.permission.READ_EXTERNAL_STORAGE
            if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P) {
                needed += Manifest.permission.WRITE_EXTERNAL_STORAGE
            }
        }
        permissionLauncher.launch(needed.toTypedArray())
    }

    companion object {
        const val EXTRA_OPEN_CLEANUP = "open_cleanup_prompt"
    }
}
