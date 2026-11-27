package com.photohub.compressor.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Cloud
import androidx.compose.material.icons.rounded.PhotoLibrary
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
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

    if (!settingsState.hasCompletedOnboarding) {
        OnboardingScreen(
            initialMode = settingsState.backupStorageMode,
            isReplay = false,
            onComplete = { chosenMode ->
                settings.completeOnboarding(chosenMode)
                if (chosenMode == com.photohub.compressor.data.BackupStorageMode.BACKUP_ONLY) {
                    bgManager.clearAllStagedItems()
                }
            }
        )
        return
    }

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

    val navColors = NavigationBarItemDefaults.colors(
        selectedIconColor = MaterialTheme.colorScheme.primary,
        selectedTextColor = MaterialTheme.colorScheme.primary,
        indicatorColor = MaterialTheme.colorScheme.primaryContainer,
        unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
        unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant
    )

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = {
            NavigationBar(
                containerColor = MaterialTheme.colorScheme.surface,
                tonalElevation = 2.dp
            ) {
                NavigationBarItem(
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    colors = navColors,
                    icon = { Icon(Icons.Rounded.PhotoLibrary, contentDescription = "Backup") },
                    label = { Text("Backup") }
                )
                NavigationBarItem(
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    colors = navColors,
                    icon = { Icon(Icons.Rounded.Cloud, contentDescription = "Cloud") },
                    label = { Text("Cloud") }
                )
                NavigationBarItem(
                    selected = selectedTab == 2,
                    onClick = { selectedTab = 2 },
                    colors = navColors,
                    icon = { Icon(Icons.Rounded.Tune, contentDescription = "Settings") },
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
            AnimatedContent(
                targetState = selectedTab,
                transitionSpec = {
                    fadeIn(tween(200)) togetherWith fadeOut(tween(150))
                },
                label = "tabTransition"
            ) { tab ->
                when (tab) {
                    0 -> CompressScreen(viewModel = compressVm, settings = settings, bgManager = bgManager)
                    1 -> ServerGalleryScreen(viewModel = serverVm, syncManager = syncManager)
                    2 -> SettingsScreen(viewModel = settingsVm)
                }
            }
        }
    }
}
