package com.photohub.compressor.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Cloud
import androidx.compose.material.icons.rounded.PhotoLibrary
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.photohub.compressor.auth.GoogleAuthManager
import com.photohub.compressor.background.BackgroundBackupManager
import com.photohub.compressor.data.AppSettings
import com.photohub.compressor.sync.LocalProxySyncManager
import com.photohub.compressor.ui.screens.*
import com.photohub.compressor.viewmodel.CompressViewModel
import com.photohub.compressor.viewmodel.ServerGalleryViewModel
import com.photohub.compressor.viewmodel.SettingsViewModel
import kotlinx.coroutines.delay

@Composable
fun PhotoHubApp() {
    val context = LocalContext.current
    val settings = remember { AppSettings.getInstance(context) }
    val authManager = remember { GoogleAuthManager.getInstance(context) }
    val bgManager = remember { BackgroundBackupManager.getInstance(context) }
    val syncManager = remember { LocalProxySyncManager.getInstance(context) }

    val settingsState by settings.state.collectAsStateWithLifecycle()
    val bgState by bgManager.state.collectAsStateWithLifecycle()

    if (!settingsState.isSignedIn) {
        SignInScreen(settingsState = settingsState, authManager = authManager)
        return
    }

    var selectedTab by remember { mutableIntStateOf(0) }
    val compressVm: CompressViewModel = viewModel()
    val serverVm: ServerGalleryViewModel = viewModel()
    val settingsVm: SettingsViewModel = viewModel()

    LaunchedEffect(settingsState.isSignedIn) {
        authManager.refreshGatewayRouteAndStorage()
        syncManager.syncFromServerOnLaunch()
        bgManager.ensureMediaObserverAndSchedule()
    }

    LaunchedEffect(bgState.pendingOpenCleanupFromNotification) {
        if (bgState.pendingOpenCleanupFromNotification) {
            selectedTab = 0
            delay(350L)
            compressVm.handleNotificationOpenCleanup()
        }
    }

    Scaffold(
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    icon = { Icon(Icons.Rounded.PhotoLibrary, contentDescription = "Compress") },
                    label = { Text("Compress") }
                )
                NavigationBarItem(
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    icon = { Icon(Icons.Rounded.Cloud, contentDescription = "Server") },
                    label = { Text("Server") }
                )
                NavigationBarItem(
                    selected = selectedTab == 2,
                    onClick = { selectedTab = 2 },
                    icon = { Icon(Icons.Rounded.Settings, contentDescription = "Settings") },
                    label = { Text("Settings") }
                )
            }
        }
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(bottom = innerPadding.calculateBottomPadding())
        ) {
            when (selectedTab) {
                0 -> CompressScreen(viewModel = compressVm, settings = settings, bgManager = bgManager)
                1 -> ServerGalleryScreen(viewModel = serverVm, syncManager = syncManager)
                2 -> SettingsScreen(viewModel = settingsVm)
            }
        }
    }
}
