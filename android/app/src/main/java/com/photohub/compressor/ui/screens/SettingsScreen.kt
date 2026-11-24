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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.photohub.compressor.data.*
import com.photohub.compressor.media.MediaLibraryService
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
    var showUploadModeMenu by remember { mutableStateOf(false) }
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
        topBar = {
            TopAppBar(title = { Text("Settings", fontWeight = FontWeight.SemiBold) })
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // 1. Account Section
            item {
                SectionCard(
                    title = "Account",
                    footer = "Automatically connected to your assigned PhotoHub server instance via Google Login."
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Icon(
                            imageVector = Icons.Rounded.AccountCircle,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(36.dp)
                        )
                        Spacer(modifier = Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = settingsState.userName.ifBlank { "Google Account" },
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.SemiBold
                            )
                            if (settingsState.userEmail.isNotBlank()) {
                                Text(
                                    text = settingsState.userEmail,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            settingsState.normalizedBaseUrl?.let { nodeUrl ->
                                Text(
                                    text = nodeUrl,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1
                                )
                            }
                        }
                        Surface(shape = CircleShape, color = PhotoHubGreen.copy(alpha = 0.14f)) {
                            Text(
                                text = settingsState.assignedNodeId,
                                style = MaterialTheme.typography.labelSmall,
                                color = PhotoHubGreen,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                            )
                        }
                    }

                    HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        TextButton(
                            onClick = { viewModel.refreshAccountAndStorage() },
                            enabled = !uiState.isTestingConnection,
                            contentPadding = PaddingValues(0.dp),
                            modifier = Modifier.weight(1f)
                        ) {
                            Text("Refresh Connection & Storage", modifier = Modifier.fillMaxWidth())
                        }
                        if (uiState.isTestingConnection) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        }
                    }

                    uiState.connectionStatus?.let { status ->
                        Text(
                            text = status,
                            style = MaterialTheme.typography.bodySmall,
                            color = if (status.startsWith("Connected")) PhotoHubGreen else PhotoHubRed
                        )
                    }

                    HorizontalDivider(modifier = Modifier.padding(vertical = 6.dp))

                    TextButton(
                        onClick = { viewModel.signOut() },
                        contentPadding = PaddingValues(0.dp)
                    ) {
                        Text("Sign Out", color = PhotoHubRed, fontWeight = FontWeight.SemiBold)
                    }
                }
            }

            // 2. Server Storage Limit Section
            item {
                val storage = settingsState.serverStorage
                val footer = if (storage?.isFixedQuota == true) {
                    "Uploads stop automatically when your assigned storage quota is reached so data integrity is always protected."
                } else {
                    "Shows your used backup storage and available capacity on your assigned server node."
                }
                SectionCard(title = "Server Storage Limit", footer = footer) {
                    if (storage != null) {
                        val tint = when {
                            storage.usageFraction >= 0.9f -> PhotoHubRed
                            storage.usageFraction >= 0.75f -> PhotoHubOrange
                            else -> PhotoHubGreen
                        }
                        Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.fillMaxWidth()) {
                            Text(
                                text = Formatter.formatFileSize(context, storage.usedBytes),
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold
                            )
                            Spacer(modifier = Modifier.width(6.dp))
                            val limit = storage.effectiveLimitBytes
                            Text(
                                text = if (limit != null) "of ${Formatter.formatFileSize(context, limit)}" else "used",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.weight(1f)
                            )
                            if (limit != null) {
                                Text(
                                    text = "${(storage.usageFraction * 100f).roundToInt()}%",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = tint,
                                    fontWeight = FontWeight.SemiBold
                                )
                            }
                        }

                        if (storage.effectiveLimitBytes != null) {
                            Spacer(modifier = Modifier.height(6.dp))
                            LinearProgressIndicator(
                                progress = { storage.usageFraction },
                                color = tint,
                                modifier = Modifier.fillMaxWidth()
                            )
                        }

                        Spacer(modifier = Modifier.height(6.dp))
                        Row(modifier = Modifier.fillMaxWidth()) {
                            storage.remainingBytes?.let { rem ->
                                val remText = if (storage.isFixedQuota) {
                                    "${Formatter.formatFileSize(context, rem)} remaining"
                                } else {
                                    "${Formatter.formatFileSize(context, rem)} free on server"
                                }
                                Text(remText, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
                            }
                            storage.itemCount?.let { count ->
                                Text(
                                    "$count item${if (count == 1) "" else "s"}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        if (storage.mastersBytes != null && storage.proxiesBytes != null) {
                            HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                            Row(modifier = Modifier.fillMaxWidth()) {
                                Text("Originals · Proxies", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
                                Text(
                                    "${Formatter.formatFileSize(context, storage.mastersBytes)} · ${Formatter.formatFileSize(context, storage.proxiesBytes)}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    } else {
                        Text(
                            text = if (uiState.isTestingConnection) "Checking server storage…" else "Tap Refresh Connection & Storage to load your quota.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            // 3. Silent Background Upload & Delete Alerts Section
            item {
                SectionCard(
                    title = "Silent Background Upload & Delete Alerts",
                    footer = "New photos & videos trigger WorkManager silently in the background (even when the app is closed). Enable 'Silent Auto-Delete Originals' + grant All Files Access to permanently delete verified originals without notifications or Trash popups; otherwise photoHub notifies you to confirm Trash."
                ) {
                    SwitchRow("Silent Auto Background Upload", settingsState.nightlyAutoBackupEnabled) { enabled ->
                        viewModel.settings.setNightlyAutoBackupEnabled(enabled)
                        viewModel.bgManager.scheduleBackgroundWorkersIfEnabled()
                        if (enabled) viewModel.bgManager.triggerSilentAutoUpload(isMovingToBackground = false)
                    }
                    SwitchRow(
                        label = "Silent Auto-Delete Originals (No Popup)",
                        checked = settingsState.silentAutoDeleteOriginals,
                        enabled = true
                    ) { enabled ->
                        viewModel.setSilentAutoDeleteOriginals(enabled)
                        if (enabled && !uiState.hasAllFilesAccess) {
                            openAllFilesAccessSettings(context)
                        }
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("All Files Access (Silent Delete)", style = MaterialTheme.typography.bodyMedium)
                                Text(
                                    text = if (uiState.hasAllFilesAccess) {
                                        "Allowed — verified originals can delete silently"
                                    } else {
                                        "Required on Android 11+ to skip Trash popups"
                                    },
                                    style = MaterialTheme.typography.labelSmall,
                                    color = if (uiState.hasAllFilesAccess) PhotoHubGreen else PhotoHubOrange
                                )
                            }
                            TextButton(
                                onClick = { openAllFilesAccessSettings(context) },
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)
                            ) {
                                Text(if (uiState.hasAllFilesAccess) "Manage" else "Grant")
                            }
                        }
                    }
                    SwitchRow("Notify When Ready to Delete Originals", settingsState.notifyWhenBackgroundUploadFinishes) {
                        viewModel.settings.setNotifyWhenBackgroundUploadFinishes(it)
                    }
                    SwitchRow(
                        label = "Require Charger for Large Batches",
                        checked = settingsState.nightlyRequiresCharging,
                        enabled = settingsState.nightlyAutoBackupEnabled
                    ) {
                        viewModel.settings.setNightlyRequiresCharging(it)
                        viewModel.bgManager.scheduleBackgroundWorkersIfEnabled()
                    }

                    Box {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("Overnight Reminder Time", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            TextButton(
                                onClick = { showHourMenu = true },
                                enabled = settingsState.nightlyAutoBackupEnabled
                            ) {
                                Text("${settingsState.morningReminderHour}:00 AM")
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

                    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("Notification Permission", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                        Text(
                            bgState.notificationPermissionLabel,
                            style = MaterialTheme.typography.bodySmall,
                            color = if (bgState.notificationPermissionLabel == "Allowed") PhotoHubGreen else MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }

                    if (bgState.stagedItems.isNotEmpty()) {
                        val sz = Formatter.formatFileSize(context, bgState.stagedSavedBytes)
                        val c = bgState.stagedItems.size
                        Text(
                            "Ready to Delete on Phone: $c original${if (c == 1) "" else "s"} (free ~$sz)",
                            style = MaterialTheme.typography.bodySmall,
                            color = PhotoHubIndigo,
                            fontWeight = FontWeight.Medium
                        )
                    }

                    if (bgState.lastRunSummary.isNotBlank()) {
                        Text(
                            bgState.lastRunSummary,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }

                    TextButton(
                        onClick = { viewModel.bgManager.sendTestMorningAlert() },
                        contentPadding = PaddingValues(0.dp)
                    ) {
                        Text("Send Test 'Delete Originals' Alert (5s)")
                    }
                }
            }

            // 4. Lightweight Proxy Settings
            item {
                SectionCard(
                    title = "Lightweight Proxy Settings",
                    footer = "Full-resolution originals always upload first untouched. Lower resolution (e.g. 480p or 720p) keeps local proxies and preview transfers super lightweight while freeing maximum space."
                ) {
                    SwitchRow("Auto Scan & Upload on App Open", settingsState.autoCompressOnOpen) {
                        viewModel.settings.setAutoCompressOnOpen(it)
                    }
                    SwitchRow("Keep Compressed Proxy in Gallery", settingsState.keepLocalProxyInPhotos) {
                        viewModel.settings.setKeepLocalProxyInPhotos(it)
                    }

                    Box {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text("Upload Mode", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            TextButton(onClick = { showUploadModeMenu = true }) {
                                Text(settingsState.uploadMode.displayName)
                            }
                        }
                        DropdownMenu(expanded = showUploadModeMenu, onDismissRequest = { showUploadModeMenu = false }) {
                            UploadMode.entries.forEach { mode ->
                                DropdownMenuItem(
                                    text = { Text(mode.displayName) },
                                    onClick = {
                                        viewModel.settings.setUploadMode(mode)
                                        showUploadModeMenu = false
                                    }
                                )
                            }
                        }
                    }

                    Box {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text("Format", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            TextButton(onClick = { showFormatMenu = true }) {
                                Text(settingsState.proxyFormat.displayName)
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
                            Text("Resolution (Photo & Video)", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            TextButton(onClick = { showResMenu = true }) {
                                Text(resPreset.title)
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
                            Text("File Size vs Detail", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            TextButton(onClick = { showDetailMenu = true }) {
                                Text(detailPreset.title)
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

                    Text(
                        text = resPreset.resolutionHint,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            // 5. Safety Section
            item {
                SectionCard(title = "How Safety & Original Deletion Works") {
                    Text(
                        text = "1. Your phone computes the SHA-256 checksum of the full-resolution original.\n" +
                            "2. The original uploads to your server in the foreground or silently in the background via WorkManager.\n" +
                            "3. Only after your server verifies the exact SHA-256 checksum on disk does photoHub save the proxy and ask you to move the original photo to Trash.\n" +
                            "4. Android Gallery holds trashed originals for 30 days (empty Trash anytime to free space right away), while full-resolution originals remain restorable.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            // 6. Diagnostics Section
            item {
                SectionCard(title = "Android Photos Diagnostics") {
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("Photos Permission", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                        Text(
                            text = uiState.mediaPermissionLabel,
                            style = MaterialTheme.typography.bodySmall,
                            color = if (uiState.mediaPermissionLabel == "Full Access") PhotoHubGreen else PhotoHubOrange,
                            fontWeight = FontWeight.Medium
                        )
                    }
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        TextButton(
                            onClick = { viewModel.runDeleteDiagnostic() },
                            enabled = !uiState.isTestingDelete,
                            contentPadding = PaddingValues(0.dp),
                            modifier = Modifier.weight(1f)
                        ) {
                            Text("Test Native Trash Alert (Latest Photo)", modifier = Modifier.fillMaxWidth())
                        }
                        if (uiState.isTestingDelete) CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    }
                    TextButton(
                        onClick = {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.fromParts("package", context.packageName, null)
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            context.startActivity(intent)
                        },
                        contentPadding = PaddingValues(0.dp)
                    ) {
                        Text("Open Android Settings for photoHub")
                    }
                    uiState.deleteDiagResult?.let { msg ->
                        Text(msg, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            // 7. Local Proxy Storage Section
            item {
                SectionCard(
                    title = "Local Proxy Storage",
                    footer = "Compressed image previews and MP4 video proxies are saved into your phone Gallery automatically without re-uploading them or creating duplicates. When you share a compressed item from Android Gallery via 'Fetch & Share Original' (or attach from 'photoHub' in Android's file picker), photoHub auto-fetches the full-resolution original from your server."
                ) {
                    SwitchRow("Auto-Save Proxies to Gallery", settingsState.autoSaveProxiesToPhotosApp) {
                        viewModel.settings.setAutoSaveProxiesToPhotosApp(it)
                    }

                    if (syncState.isSyncing) {
                        Row(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                text = syncState.statusText.ifBlank { "Downloading (${syncState.completedCount}/${syncState.totalCount})…" },
                                style = MaterialTheme.typography.bodySmall,
                                modifier = Modifier.weight(1f)
                            )
                            TextButton(onClick = { viewModel.syncManager.cancel() }) { Text("Stop") }
                        }
                    } else {
                        TextButton(
                            onClick = { viewModel.downloadAllMissingToPhotos() },
                            enabled = settingsState.normalizedBaseUrl != null,
                            contentPadding = PaddingValues(0.dp)
                        ) {
                            Icon(Icons.Rounded.Download, null, modifier = Modifier.size(18.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("Download All Proxies to Gallery")
                        }
                        if (syncState.statusText.isNotBlank()) {
                            Text(syncState.statusText, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }

                    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                        Text("Cached Proxies in App", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                        Text(
                            Formatter.formatFileSize(context, uiState.localProxyCacheBytes),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontWeight = FontWeight.Medium
                        )
                    }

                    SwitchRow("Auto-Cache Proxies in App", settingsState.autoDownloadLocalProxies) {
                        viewModel.settings.setAutoDownloadLocalProxies(it)
                    }
                    SwitchRow(
                        label = "Auto-Download Compressed Videos (.mp4)",
                        checked = settingsState.autoDownloadLocalVideos,
                        enabled = settingsState.autoDownloadLocalProxies || settingsState.autoSaveProxiesToPhotosApp
                    ) {
                        viewModel.settings.setAutoDownloadLocalVideos(it)
                    }

                    TextButton(
                        onClick = { viewModel.clearLocalProxyCache() },
                        enabled = uiState.localProxyCacheBytes > 0L,
                        contentPadding = PaddingValues(0.dp)
                    ) {
                        Text("Clear Local Proxy Cache", color = if (uiState.localProxyCacheBytes > 0L) PhotoHubRed else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            // 8. Restore Originals Section
            item {
                SectionCard(
                    title = "Restore Originals",
                    footer = "Downloads full-resolution originals from your server into your phone Gallery, deletes matching compressed proxy copies from Gallery, and marks originals protected so automatic proxy cleanup will not re-compress them."
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("Originals Status", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                        when {
                            uiState.isLoadingRestoreSummary && !uiState.hasLoadedRestoreSummary -> {
                                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            }
                            uiState.restoreLibraryTotalCount > 0 && uiState.restoreLibraryUnrestoredCount > 0 -> {
                                val sizeStr = Formatter.formatFileSize(context, uiState.restoreLibraryUnrestoredBytes)
                                Text(
                                    "${uiState.restoreLibraryUnrestoredCount} of ${uiState.restoreLibraryTotalCount} not restored (~$sizeStr)",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            uiState.restoreLibraryTotalCount > 0 -> {
                                Text(
                                    "All ${uiState.restoreLibraryTotalCount} protected/restored",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = PhotoHubGreen,
                                    fontWeight = FontWeight.Medium
                                )
                            }
                            uiState.hasLoadedRestoreSummary -> {
                                Text(
                                    "0 items on server",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            else -> {
                                Text(
                                    "Tap Restore to check",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }

                    if (uiState.isBatchRestoringOriginals) {
                        Column(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(
                                    "Restoring originals (${uiState.restoreOriginalsCompleted}/${uiState.restoreOriginalsTotal})…",
                                    style = MaterialTheme.typography.bodySmall,
                                    fontWeight = FontWeight.Medium,
                                    modifier = Modifier.weight(1f)
                                )
                                TextButton(onClick = { viewModel.stopRestoreOriginals() }) {
                                    Text("Stop")
                                }
                            }
                            if (uiState.restoreOriginalsCurrentName.isNotBlank()) {
                                Text(
                                    uiState.restoreOriginalsCurrentName,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1
                                )
                            }
                        }
                    } else {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            TextButton(
                                onClick = { viewModel.requestRestoreAllOriginals() },
                                enabled = settingsState.normalizedBaseUrl != null &&
                                    settingsState.isSignedIn &&
                                    !uiState.isLoadingRestoreSummary,
                                contentPadding = PaddingValues(0.dp),
                                modifier = Modifier.weight(1f)
                            ) {
                                Icon(Icons.Rounded.CloudDownload, null, modifier = Modifier.size(18.dp))
                                Spacer(modifier = Modifier.width(6.dp))
                                Text("Restore All Originals to Gallery", modifier = Modifier.weight(1f))
                            }
                            if (uiState.isLoadingRestoreSummary) {
                                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            }
                        }

                        uiState.restoreOriginalsMessage?.let { msg ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    msg,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.weight(1f)
                                )
                                IconButton(
                                    onClick = { viewModel.dismissRestoreOriginalsMessage() },
                                    modifier = Modifier.size(24.dp)
                                ) {
                                    Icon(Icons.Rounded.Close, null, modifier = Modifier.size(14.dp))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionCard(
    title: String,
    footer: String? = null,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            text = title.uppercase(),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 4.dp)
        )
        Surface(
            shape = MaterialTheme.shapes.large,
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = 1.dp,
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(
                modifier = Modifier.padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
                content = content
            )
        }
        if (!footer.isNullOrBlank()) {
            Text(
                text = footer,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 4.dp)
            )
        }
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
