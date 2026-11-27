package com.photohub.compressor.ui.screens

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.photohub.compressor.data.*
import com.photohub.compressor.media.MediaLibraryService
import com.photohub.compressor.ui.components.*
import com.photohub.compressor.ui.theme.*
import com.photohub.compressor.viewmodel.SettingsViewModel
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(viewModel: SettingsViewModel) {
    val context = LocalContext.current
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val settingsState by viewModel.settings.state.collectAsStateWithLifecycle()
    val bgState by viewModel.bgManager.state.collectAsStateWithLifecycle()
    val syncState by viewModel.syncManager.state.collectAsStateWithLifecycle()

    var showHourMenu by remember { mutableStateOf(false) }
    var showFormatMenu by remember { mutableStateOf(false) }
    var showResMenu by remember { mutableStateOf(false) }
    var showDetailMenu by remember { mutableStateOf(false) }
    var pendingRestoreIncludeProtected by remember { mutableStateOf<Boolean?>(null) }

    val testTrashLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartIntentSenderForResult()
    ) { result ->
        viewModel.onDiagnosticTrashResult(result.resultCode == Activity.RESULT_OK)
    }

    val proxyDeleteLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartIntentSenderForResult()
    ) { result ->
        viewModel.onProxyDeleteConfirmationResult(result.resultCode == Activity.RESULT_OK)
    }

    val restoreGalleryPermLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions()
    ) { _ ->
        val includeProtected = pendingRestoreIncludeProtected
        pendingRestoreIncludeProtected = null
        if (includeProtected != null) {
            if (viewModel.canWriteGallery()) {
                viewModel.executeRestoreOriginalsConfirm(includeProtected)
            } else {
                viewModel.dismissRestoreOriginalsConfirm()
                viewModel.reportRestoreOriginalsPermissionDenied()
            }
        }
    }

    fun triggerConfirmedRestoreOriginals(includeAlreadyRestored: Boolean) {
        if (viewModel.canWriteGallery()) {
            viewModel.executeRestoreOriginalsConfirm(includeAlreadyRestored)
        } else {
            pendingRestoreIncludeProtected = includeAlreadyRestored
            restoreGalleryPermLauncher.launch(MediaLibraryService.galleryReadWritePermissions())
        }
    }

    LaunchedEffect(uiState.pendingTestTrashIntentSender) {
        val sender = uiState.pendingTestTrashIntentSender ?: return@LaunchedEffect
        viewModel.clearPendingTestTrash()
        testTrashLauncher.launch(IntentSenderRequest.Builder(sender).build())
    }

    LaunchedEffect(uiState.pendingProxyDeleteIntentSender) {
        val sender = uiState.pendingProxyDeleteIntentSender ?: return@LaunchedEffect
        viewModel.clearPendingProxyDeleteIntent()
        proxyDeleteLauncher.launch(IntentSenderRequest.Builder(sender).build())
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                viewModel.onAppear()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    LaunchedEffect(Unit) {
        viewModel.onAppear()
        if (settingsState.isSignedIn) {
            if (settingsState.serverStorage == null) {
                viewModel.refreshAccountAndStorage()
            }
            viewModel.refreshRestoreOriginalsSummary(fetchRemote = true)
        }
    }

    uiState.restoreOriginalsConfirmRequest?.let { req ->
        BatchRestoreConfirmDialog(
            request = req,
            onDismiss = { viewModel.dismissRestoreOriginalsConfirm() },
            onDeleteLeftoverProxies = { viewModel.executeDeleteLeftoverCompressedProxies() },
            onConfirm = { includeProtected -> triggerConfirmedRestoreOriginals(includeProtected) }
        )
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text("Settings", fontWeight = FontWeight.Bold) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background
                )
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            // 1. Account Card with Sunny Mascot
            item {
                WarmCard {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        SunnyMascot(
                            mood = if (bgState.activeBackgroundCount > 0) MascotMood.UPLOADING else MascotMood.HAPPY,
                            size = 56.dp
                        )
                        Spacer(modifier = Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(
                                text = settingsState.userName.ifBlank { "Account" },
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            if (settingsState.userEmail.isNotBlank()) {
                                Text(
                                    text = settingsState.userEmail,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                WarmStatChip(
                                    text = settingsState.assignedNodeId,
                                    tint = PhotoHubMint,
                                    icon = Icons.Rounded.Dns
                                )
                                uiState.connectionStatus?.let { status ->
                                    val ok = status.startsWith("Connected")
                                    Text(
                                        text = if (ok) "Online" else "Offline",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = if (ok) PhotoHubMint else PhotoHubRed,
                                        fontWeight = FontWeight.Bold
                                    )
                                }
                            }
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        SoftOrangeButton(
                            text = if (uiState.isTestingConnection) "Checking…" else "Refresh",
                            icon = Icons.Rounded.Refresh,
                            enabled = !uiState.isTestingConnection,
                            onClick = { viewModel.refreshAccountAndStorage() },
                            modifier = Modifier.weight(1f)
                        )
                        Surface(
                            onClick = { viewModel.signOut() },
                            shape = CircleShape,
                            color = PhotoHubRed.copy(alpha = 0.12f),
                            modifier = Modifier.height(46.dp)
                        ) {
                            Box(
                                modifier = Modifier.padding(horizontal = 18.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Text("Sign Out", color = PhotoHubRed, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelLarge)
                            }
                        }
                    }
                }
            }

            // 2. Storage Card
            item {
                val storage = settingsState.serverStorage
                SectionBlock(title = "Storage", icon = Icons.Rounded.Storage) {
                    if (storage != null) {
                        val tint = when {
                            storage.usageFraction >= 0.9f -> PhotoHubRed
                            storage.usageFraction >= 0.75f -> PhotoHubOrange
                            else -> PhotoHubMint
                        }
                        Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.fillMaxWidth()) {
                            Text(
                                text = Formatter.formatFileSize(context, storage.usedBytes),
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.ExtraBold
                            )
                            Spacer(modifier = Modifier.width(6.dp))
                            val limit = storage.effectiveLimitBytes
                            Text(
                                text = if (limit != null) "/ ${Formatter.formatFileSize(context, limit)}" else "used",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.weight(1f)
                            )
                            if (limit != null) {
                                Text(
                                    text = "${(storage.usageFraction * 100f).roundToInt()}%",
                                    style = MaterialTheme.typography.labelLarge,
                                    color = tint,
                                    fontWeight = FontWeight.ExtraBold
                                )
                            }
                        }

                        if (storage.effectiveLimitBytes != null) {
                            LinearProgressIndicator(
                                progress = { storage.usageFraction },
                                color = tint,
                                trackColor = tint.copy(alpha = 0.15f),
                                modifier = Modifier.fillMaxWidth().height(8.dp)
                            )
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            storage.remainingBytes?.let { rem ->
                                WarmStatChip(
                                    text = "${Formatter.formatFileSize(context, rem)} free",
                                    tint = PhotoHubMint,
                                    icon = Icons.Rounded.CheckCircle
                                )
                            }
                            Spacer(modifier = Modifier.weight(1f))
                            storage.itemCount?.let { count ->
                                Text(
                                    "$count items",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        if (storage.mastersBytes != null && storage.proxiesBytes != null) {
                            Row(modifier = Modifier.fillMaxWidth()) {
                                Text("Originals · Proxies", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
                                Text(
                                    "${Formatter.formatFileSize(context, storage.mastersBytes)} · ${Formatter.formatFileSize(context, storage.proxiesBytes)}",
                                    style = MaterialTheme.typography.labelSmall,
                                    fontWeight = FontWeight.SemiBold
                                )
                            }
                        }
                    } else {
                        Text(
                            text = if (uiState.isTestingConnection) "Loading…" else "Tap Refresh",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            // 3. Auto Backup Card
            item {
                SectionBlock(title = "Auto Backup", icon = Icons.Rounded.CloudUpload) {
                    SwitchRow("Background Upload", settingsState.nightlyAutoBackupEnabled) { enabled ->
                        viewModel.settings.setNightlyAutoBackupEnabled(enabled)
                        viewModel.bgManager.scheduleBackgroundWorkersIfEnabled()
                        if (enabled) viewModel.bgManager.triggerSilentAutoUpload(isMovingToBackground = false)
                    }
                    SwitchRow("Silent Delete", settingsState.silentAutoDeleteOriginals) { enabled ->
                        viewModel.setSilentAutoDeleteOriginals(enabled)
                        if (enabled && !uiState.hasAllFilesAccess) {
                            openAllFilesAccessSettings(context)
                        }
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("All Files Access", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            WarmStatChip(
                                text = if (uiState.hasAllFilesAccess) "Allowed" else "Needed",
                                tint = if (uiState.hasAllFilesAccess) PhotoHubMint else PhotoHubAmber
                            )
                            TextButton(onClick = { openAllFilesAccessSettings(context) }) {
                                Text(if (uiState.hasAllFilesAccess) "Manage" else "Grant")
                            }
                        }
                    }
                    SwitchRow("Delete Alerts", settingsState.notifyWhenBackgroundUploadFinishes) {
                        viewModel.settings.setNotifyWhenBackgroundUploadFinishes(it)
                    }
                    SwitchRow(
                        label = "Charger Only",
                        checked = settingsState.nightlyRequiresCharging,
                        enabled = settingsState.nightlyAutoBackupEnabled
                    ) {
                        viewModel.settings.setNightlyRequiresCharging(it)
                        viewModel.bgManager.scheduleBackgroundWorkersIfEnabled()
                    }

                    Box {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text("Reminder", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            TextButton(
                                onClick = { showHourMenu = true },
                                enabled = settingsState.nightlyAutoBackupEnabled
                            ) {
                                Text("${settingsState.morningReminderHour}:00 AM", fontWeight = FontWeight.SemiBold)
                            }
                        }
                        DropdownMenu(expanded = showHourMenu, onDismissRequest = { showHourMenu = false }) {
                            (6..11).forEach { hr ->
                                DropdownMenuItem(
                                    text = { Text("$hr:00 AM") },
                                    onClick = {
                                        viewModel.settings.setMorningReminderHour(hr)
                                        showHourMenu = false
                                    }
                                )
                            }
                        }
                    }

                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("Alerts", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                        val allowed = bgState.notificationPermissionLabel == "Allowed"
                        WarmStatChip(
                            text = if (allowed) "Allowed" else "Off",
                            tint = if (allowed) PhotoHubMint else PhotoHubAmber
                        )
                    }

                    if (bgState.stagedItems.isNotEmpty()) {
                        val sz = Formatter.formatFileSize(context, bgState.stagedSavedBytes)
                        WarmStatChip(
                            text = "${bgState.stagedItems.size} ready · ~$sz",
                            tint = PhotoHubOrange,
                            icon = Icons.Rounded.DeleteOutline
                        )
                    }

                    if (bgState.lastRunSummary.isNotBlank()) {
                        Text(
                            bgState.lastRunSummary,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }

                    SoftOrangeButton(
                        text = "Test Alert (5s)",
                        icon = Icons.Rounded.NotificationsActive,
                        onClick = { viewModel.bgManager.sendTestMorningAlert() },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }

            // 4. Proxy Card
            item {
                SectionBlock(title = "Proxy", icon = Icons.Rounded.AutoAwesome) {
                    SwitchRow("Auto Scan", settingsState.autoCompressOnOpen) {
                        viewModel.settings.setAutoCompressOnOpen(it)
                    }
                    SwitchRow("Keep Proxy", settingsState.keepLocalProxyInPhotos) {
                        viewModel.settings.setKeepLocalProxyInPhotos(it)
                    }

                    Box {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text("Format", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            TextButton(onClick = { showFormatMenu = true }) {
                                Text(settingsState.proxyFormat.displayName, fontWeight = FontWeight.SemiBold)
                            }
                        }
                        DropdownMenu(expanded = showFormatMenu, onDismissRequest = { showFormatMenu = false }) {
                            ProxyFormat.entries.forEach { fmt ->
                                DropdownMenuItem(
                                    text = { Text(fmt.displayName) },
                                    onClick = {
                                        viewModel.settings.setProxyFormat(fmt)
                                        showFormatMenu = false
                                    }
                                )
                            }
                        }
                    }

                    val resPreset = ProxyResolutionPreset.fromStoredPixels(settingsState.proxyMaxPixelSize)
                    val detailPreset = ProxyDetailPreset.fromStoredQuality(settingsState.proxyQuality)

                    Box {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text("Size", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            TextButton(onClick = { showResMenu = true }) {
                                Text(resPreset.title, fontWeight = FontWeight.SemiBold)
                            }
                        }
                        DropdownMenu(expanded = showResMenu, onDismissRequest = { showResMenu = false }) {
                            ProxyResolutionPreset.entries.forEach { preset ->
                                DropdownMenuItem(
                                    text = { Text(preset.title) },
                                    onClick = {
                                        viewModel.settings.setProxyMaxPixelSize(preset.maxPixelSize)
                                        showResMenu = false
                                    }
                                )
                            }
                        }
                    }

                    Box {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text("Quality", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            TextButton(onClick = { showDetailMenu = true }) {
                                Text(detailPreset.title, fontWeight = FontWeight.SemiBold)
                            }
                        }
                        DropdownMenu(expanded = showDetailMenu, onDismissRequest = { showDetailMenu = false }) {
                            ProxyDetailPreset.entries.forEach { detail ->
                                DropdownMenuItem(
                                    text = { Text(detail.title) },
                                    onClick = {
                                        viewModel.settings.setProxyQuality(detail.qualityValue)
                                        showDetailMenu = false
                                    }
                                )
                            }
                        }
                    }
                }
            }

            // 5. Restore Originals Card
            item {
                SectionBlock(title = "Restore Originals", icon = Icons.Rounded.CloudDownload) {
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("Status", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                        when {
                            uiState.isLoadingRestoreSummary && !uiState.hasLoadedRestoreSummary -> {
                                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            }
                            uiState.restoreLibraryTotalCount > 0 && uiState.restoreLibraryUnrestoredCount > 0 -> {
                                val sizeStr = Formatter.formatFileSize(context, uiState.restoreLibraryUnrestoredBytes)
                                WarmStatChip(
                                    text = "${uiState.restoreLibraryUnrestoredCount} · ~$sizeStr",
                                    tint = PhotoHubOrange
                                )
                            }
                            uiState.restoreLibraryTotalCount > 0 -> {
                                WarmStatChip(
                                    text = "All ${uiState.restoreLibraryTotalCount}",
                                    tint = PhotoHubMint,
                                    icon = Icons.Rounded.Verified
                                )
                            }
                            else -> {
                                Text("0 items", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }

                    uiState.deviceAvailableBytes?.let { phoneFree ->
                        val lowSpace = uiState.restoreLibraryUnrestoredBytes > 0L &&
                            phoneFree < uiState.restoreLibraryUnrestoredBytes + com.photohub.compressor.viewmodel.DeviceStorageHelper.MINIMUM_HEADROOM_BYTES
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text("Phone Free", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            WarmStatChip(
                                text = Formatter.formatFileSize(context, phoneFree),
                                tint = if (lowSpace) PhotoHubRed else PhotoHubMint,
                                icon = if (lowSpace) Icons.Rounded.Warning else Icons.Rounded.PhoneAndroid
                            )
                        }
                    }

                    if (uiState.isBatchRestoringOriginals) {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            SunnyMascot(mood = MascotMood.UPLOADING, size = 44.dp)
                            Spacer(modifier = Modifier.width(8.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    "${uiState.restoreOriginalsCompleted}/${uiState.restoreOriginalsTotal}",
                                    style = MaterialTheme.typography.titleSmall,
                                    fontWeight = FontWeight.Bold,
                                    color = PhotoHubOrange
                                )
                                if (uiState.restoreOriginalsCurrentName.isNotBlank()) {
                                    Text(
                                        uiState.restoreOriginalsCurrentName,
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                }
                            }
                            TextButton(onClick = { viewModel.stopRestoreOriginals() }) {
                                Text("Stop", color = PhotoHubRed, fontWeight = FontWeight.Bold)
                            }
                        }
                    } else {
                        GradientPrimaryButton(
                            text = "Restore All to Gallery",
                            icon = Icons.Rounded.CloudDownload,
                            enabled = settingsState.normalizedBaseUrl != null && settingsState.isSignedIn,
                            loading = uiState.isLoadingRestoreSummary,
                            onClick = { viewModel.requestRestoreAllOriginals() },
                            modifier = Modifier.fillMaxWidth()
                        )

                        uiState.restoreOriginalsMessage?.let { msg ->
                            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                Text(msg, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
                                IconButton(onClick = { viewModel.dismissRestoreOriginalsMessage() }, modifier = Modifier.size(24.dp)) {
                                    Icon(Icons.Rounded.Close, null, modifier = Modifier.size(14.dp))
                                }
                            }
                        }
                    }
                }
            }

            // 6. Local Cache Card
            item {
                SectionBlock(title = "Local Cache", icon = Icons.Rounded.FolderCopy) {
                    SwitchRow("Save to Gallery", settingsState.autoSaveProxiesToPhotosApp) {
                        viewModel.settings.setAutoSaveProxiesToPhotosApp(it)
                    }
                    SwitchRow("App Cache", settingsState.autoDownloadLocalProxies) {
                        viewModel.settings.setAutoDownloadLocalProxies(it)
                    }
                    SwitchRow(
                        label = "Cache Videos",
                        checked = settingsState.autoDownloadLocalVideos,
                        enabled = settingsState.autoDownloadLocalProxies || settingsState.autoSaveProxiesToPhotosApp
                    ) {
                        viewModel.settings.setAutoDownloadLocalVideos(it)
                    }

                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("Cache Size", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                        Text(
                            Formatter.formatFileSize(context, uiState.localProxyCacheBytes),
                            style = MaterialTheme.typography.titleSmall,
                            color = PhotoHubOrange,
                            fontWeight = FontWeight.Bold
                        )
                    }

                    if (syncState.isSyncing) {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                "${syncState.completedCount}/${syncState.totalCount}",
                                style = MaterialTheme.typography.bodySmall,
                                modifier = Modifier.weight(1f)
                            )
                            TextButton(onClick = { viewModel.syncManager.cancel() }) {
                                Text("Stop", color = PhotoHubRed)
                            }
                        }
                    } else {
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                            SoftOrangeButton(
                                text = "Sync Proxies",
                                icon = Icons.Rounded.Download,
                                enabled = settingsState.normalizedBaseUrl != null,
                                onClick = { viewModel.downloadAllMissingToPhotos() },
                                modifier = Modifier.weight(1f)
                            )
                            Surface(
                                onClick = { viewModel.clearLocalProxyCache() },
                                enabled = uiState.localProxyCacheBytes > 0L,
                                shape = CircleShape,
                                color = PhotoHubRed.copy(alpha = if (uiState.localProxyCacheBytes > 0L) 0.12f else 0.05f),
                                modifier = Modifier.height(46.dp)
                            ) {
                                Box(modifier = Modifier.padding(horizontal = 18.dp), contentAlignment = Alignment.Center) {
                                    Text(
                                        "Clear",
                                        color = if (uiState.localProxyCacheBytes > 0L) PhotoHubRed else MaterialTheme.colorScheme.onSurfaceVariant,
                                        fontWeight = FontWeight.Bold,
                                        style = MaterialTheme.typography.labelLarge
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // 7. Photos Access Card
            item {
                SectionBlock(title = "Photos Access", icon = Icons.Rounded.PhotoLibrary) {
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("Permission", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                        WarmStatChip(
                            text = uiState.mediaPermissionLabel,
                            tint = if (uiState.mediaPermissionLabel == "Full Access") PhotoHubMint else PhotoHubAmber
                        )
                    }

                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                        SoftOrangeButton(
                            text = if (uiState.isTestingDelete) "Testing…" else "Test Trash",
                            enabled = !uiState.isTestingDelete,
                            onClick = { viewModel.runDeleteDiagnostic() },
                            modifier = Modifier.weight(1f)
                        )
                        SoftOrangeButton(
                            text = "App Settings",
                            onClick = {
                                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                    data = Uri.fromParts("package", context.packageName, null)
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                                context.startActivity(intent)
                            },
                            modifier = Modifier.weight(1f)
                        )
                    }

                    uiState.deleteDiagResult?.let { msg ->
                        Text(msg, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionBlock(
    title: String,
    icon: ImageVector,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Icon(icon, contentDescription = null, tint = PhotoHubOrange, modifier = Modifier.size(15.dp))
            Text(
                text = title.uppercase(),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.ExtraBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        WarmCard(content = content)
    }
}

@Composable
private fun SwitchRow(
    label: String,
    checked: Boolean,
    enabled: Boolean = true,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f)
        )
        Switch(checked = checked, onCheckedChange = onCheckedChange, enabled = enabled)
    }
}

private fun openAllFilesAccessSettings(context: android.content.Context) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        val pkgIntent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
            data = Uri.fromParts("package", context.packageName, null)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val openedPkg = runCatching { context.startActivity(pkgIntent) }.isSuccess
        if (openedPkg) return

        val allIntent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val openedAll = runCatching { context.startActivity(allIntent) }.isSuccess
        if (openedAll) return
    }
    val detailsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
        data = Uri.fromParts("package", context.packageName, null)
        flags = Intent.FLAG_ACTIVITY_NEW_TASK
    }
    runCatching { context.startActivity(detailsIntent) }
}
