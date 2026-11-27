package com.photohub.compressor.ui.screens

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.photohub.compressor.background.BackgroundBackupManager
import com.photohub.compressor.data.*
import com.photohub.compressor.media.*
import com.photohub.compressor.ui.components.*
import com.photohub.compressor.ui.theme.*
import com.photohub.compressor.viewmodel.CompressViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CompressScreen(
    viewModel: CompressViewModel,
    settings: AppSettings,
    bgManager: BackgroundBackupManager
) {
    val context = LocalContext.current
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val duplicateState by viewModel.duplicateCleanerState.collectAsStateWithLifecycle()
    val settingsState by settings.state.collectAsStateWithLifecycle()
    val bgState by bgManager.state.collectAsStateWithLifecycle()

    var showMenu by remember { mutableStateOf(false) }

    val activeBgCount = maxOf(uiState.backgroundActiveCount, bgState.activeBackgroundCount)
    val heroMood = when {
        uiState.accessLevel == MediaAccessLevel.DENIED -> MascotMood.ALERT
        uiState.isScanning || uiState.isProcessing || activeBgCount > 0 -> MascotMood.UPLOADING
        bgState.stagedItems.isNotEmpty() || uiState.totalSavedBytes > 0L -> MascotMood.CELEBRATE
        else -> MascotMood.HAPPY
    }

    val detectProxyPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia(25)
    ) { uris ->
        if (uris.isNotEmpty()) {
            viewModel.inspectGalleryUris(uris)
        }
    }

    LaunchedEffect(uiState.shareFileReady) {
        val f = uiState.shareFileReady ?: return@LaunchedEffect
        shareFileViaChooser(context, f)
        viewModel.clearShareFileReady()
    }

    uiState.cleanupPreviewItems?.let { previewItems ->
        CleanupPreviewConfirmDialog(
            items = previewItems,
            onDismiss = { viewModel.dismissCleanupPreview() },
            onConfirm = { viewModel.confirmCleanupPreviewAndDelete() }
        )
    }

    uiState.galleryInspectionResults?.let { inspectionList ->
        GalleryProxyInspectionDialog(
            items = inspectionList,
            busyItemId = uiState.inspectionBusyId,
            onRestore = { item ->
                viewModel.restoreOriginalFromDetectedProxy(
                    itemId = item.id,
                    rawMasterHash = item.masterHash,
                    originalFilename = item.originalName,
                    isVideo = item.isVideo
                )
            },
            onShareOriginal = { item ->
                viewModel.shareOriginalFromDetectedProxy(
                    itemId = item.id,
                    rawMasterHash = item.masterHash,
                    originalFilename = item.originalName,
                    isVideo = item.isVideo
                )
            },
            onDismiss = { viewModel.dismissGalleryInspection() }
        )
    }

    val trashLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartIntentSenderForResult()
    ) { result ->
        val pendingIds = uiState.trashPromptRequest?.targetIds ?: uiState.pendingDeleteIds
        viewModel.clearTrashPromptRequest()
        if (result.resultCode == Activity.RESULT_OK) {
            viewModel.onTrashConfirmed(pendingIds)
        } else {
            viewModel.onTrashCancelled(pendingIds)
        }
    }

    LaunchedEffect(uiState.trashPromptRequest) {
        val req = uiState.trashPromptRequest ?: return@LaunchedEffect
        trashLauncher.launch(IntentSenderRequest.Builder(req.intentSender).build())
    }

    val duplicateTrashLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartIntentSenderForResult()
    ) { result ->
        val pendingIds = duplicateState.trashPromptRequest?.targetIds ?: emptyList()
        viewModel.clearDuplicateTrashPrompt()
        if (result.resultCode == Activity.RESULT_OK) {
            viewModel.onDuplicateTrashConfirmed(pendingIds)
        } else {
            viewModel.onDuplicateTrashCancelled()
        }
    }

    LaunchedEffect(duplicateState.trashPromptRequest) {
        val req = duplicateState.trashPromptRequest ?: return@LaunchedEffect
        duplicateTrashLauncher.launch(IntentSenderRequest.Builder(req.intentSender).build())
    }

    if (duplicateState.isOpen) {
        DuplicateCleanerDialog(
            state = duplicateState,
            onRescan = { viewModel.startDuplicateScan() },
            onToggleItem = { viewModel.toggleDuplicateItemSelection(it) },
            onLoadThumb = { viewModel.loadDuplicateThumbnailIfNeeded(it) },
            onAutoRemove = { viewModel.removeSelectedDuplicates() },
            onDismiss = { viewModel.dismissDuplicateCleaner() }
        )
    }

    LaunchedEffect(Unit) {
        viewModel.refreshPermissionsAndSync()
        if (uiState.candidates.isEmpty()) {
            viewModel.scanAndAutoCompressIfEnabled()
        }
    }

    if (uiState.deleteErrorAlertMessage != null) {
        AlertDialog(
            onDismissRequest = { viewModel.clearDeleteError() },
            title = { Text("Delete Original") },
            text = { Text(uiState.deleteErrorAlertMessage.orEmpty()) },
            confirmButton = {
                if (uiState.pendingDeleteIds.isNotEmpty()) {
                    TextButton(onClick = {
                        viewModel.clearDeleteError()
                        viewModel.triggerTrashConfirmation(uiState.pendingDeleteIds)
                    }) {
                        Text("Retry")
                    }
                }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = {
                        viewModel.dismissPendingDeleteAfterError()
                        openAppSettings(context)
                    }) {
                        Text("Settings")
                    }
                    TextButton(onClick = { viewModel.dismissPendingDeleteAfterError() }) {
                        Text("OK")
                    }
                }
            }
        )
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text("Backup", fontWeight = FontWeight.Bold) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background
                ),
                navigationIcon = {
                    IconButton(
                        onClick = { viewModel.scanLibrary() },
                        enabled = !uiState.isScanning && !uiState.isProcessing
                    ) {
                        if (uiState.isScanning) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Rounded.Refresh, contentDescription = "Scan")
                        }
                    }
                },
                actions = {
                    IconButton(
                        onClick = { viewModel.openDuplicateCleaner() },
                        enabled = !uiState.isProcessing
                    ) {
                        Icon(Icons.Rounded.ContentCopy, contentDescription = "Remove Duplicates")
                    }

                    IconButton(
                        onClick = {
                            detectProxyPicker.launch(
                                androidx.activity.result.PickVisualMediaRequest(
                                    ActivityResultContracts.PickVisualMedia.ImageAndVideo
                                )
                            )
                        },
                        enabled = !uiState.isInspectingGalleryUris && !uiState.isProcessing
                    ) {
                        Icon(Icons.Rounded.ImageSearch, contentDescription = "Check Proxy")
                    }

                    if (uiState.candidates.isNotEmpty()) {
                        Box {
                            IconButton(
                                onClick = { showMenu = true },
                                enabled = !uiState.isProcessing
                            ) {
                                Icon(Icons.Rounded.FilterList, contentDescription = "Sort")
                            }
                            DropdownMenu(
                                expanded = showMenu,
                                onDismissRequest = { showMenu = false }
                            ) {
                                CandidateSortMode.entries.forEach { mode ->
                                    DropdownMenuItem(
                                        text = { Text(mode.displayName) },
                                        leadingIcon = {
                                            if (uiState.sortMode == mode) {
                                                Icon(Icons.Rounded.Check, contentDescription = null)
                                            }
                                        },
                                        onClick = {
                                            viewModel.setSortMode(mode)
                                            showMenu = false
                                        }
                                    )
                                }
                                HorizontalDivider()
                                if (uiState.pendingVideoCandidates.isNotEmpty()) {
                                    DropdownMenuItem(
                                        text = { Text("Top Videos") },
                                        leadingIcon = { Icon(Icons.Rounded.Videocam, contentDescription = null) },
                                        onClick = {
                                            viewModel.selectTopVideos()
                                            showMenu = false
                                        }
                                    )
                                }
                                DropdownMenuItem(
                                    text = { Text("Select All") },
                                    onClick = {
                                        viewModel.selectAllEligible(true)
                                        showMenu = false
                                    }
                                )
                                DropdownMenuItem(
                                    text = { Text("Clear") },
                                    onClick = {
                                        viewModel.selectAllEligible(false)
                                        showMenu = false
                                    }
                                )
                            }
                        }
                    }
                }
            )
        },
        bottomBar = {
            if (uiState.selectedCount > 0) {
                Surface(
                    color = MaterialTheme.colorScheme.surface,
                    tonalElevation = 4.dp,
                    shadowElevation = 8.dp
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 10.dp)
                    ) {
                        val n = uiState.selectedCount
                        val label = when {
                            settingsState.isBackupOnlyMode -> "Back Up $n (Keep Originals)"
                            settingsState.keepLocalProxyInPhotos -> "Compress $n"
                            else -> "Backup $n"
                        }
                        GradientPrimaryButton(
                            text = label,
                            icon = if (!settingsState.isBackupOnlyMode && settingsState.keepLocalProxyInPhotos) {
                                Icons.Rounded.AutoAwesome
                            } else {
                                Icons.Rounded.CloudUpload
                            },
                            enabled = !uiState.isProcessing,
                            onClick = { viewModel.startProcessingSelectedPhotos() },
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
            }
        }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 14.dp, vertical = 4.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    if (uiState.accessLevel == MediaAccessLevel.LIMITED_ACCESS) {
                        CompactBannerCard(tint = PhotoHubAmber) {
                            Icon(Icons.Rounded.Warning, contentDescription = null, tint = PhotoHubAmber, modifier = Modifier.size(18.dp))
                            Text(
                                text = "Limited Access",
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.weight(1f)
                            )
                            Button(
                                onClick = { openAppSettings(context) },
                                colors = ButtonDefaults.buttonColors(containerColor = PhotoHubOrange),
                                shape = CircleShape,
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
                                modifier = Modifier.height(32.dp)
                            ) {
                                Text("Allow All", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
                            }
                        }
                    }

                    AnimatedVisibility(
                        visible = !settingsState.isBackupOnlyMode && bgState.stagedItems.isNotEmpty() && !uiState.isProcessing && !uiState.isAwaitingDeleteConfirmation
                    ) {
                        val count = bgState.stagedItems.size
                        val sizeStr = Formatter.formatFileSize(context, bgState.stagedSavedBytes)
                        CompactBannerCard(tint = PhotoHubMint) {
                            Icon(Icons.Rounded.Verified, contentDescription = null, tint = PhotoHubMint, modifier = Modifier.size(20.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = "$count Ready",
                                    style = MaterialTheme.typography.titleSmall,
                                    fontWeight = FontWeight.Bold
                                )
                                Text(
                                    text = "Free ~$sizeStr",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Button(
                                onClick = { viewModel.openStagedCleanupPreview() },
                                enabled = !uiState.isLoadingCleanupPreview,
                                colors = ButtonDefaults.buttonColors(containerColor = PhotoHubOrange),
                                shape = CircleShape,
                                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp),
                                modifier = Modifier.height(34.dp)
                            ) {
                                Text(if (uiState.isLoadingCleanupPreview) "…" else "Delete", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
                            }
                            IconButton(onClick = { bgManager.clearAllStagedItems() }, modifier = Modifier.size(26.dp)) {
                                Icon(Icons.Rounded.Close, contentDescription = "Dismiss", modifier = Modifier.size(16.dp))
                            }
                        }
                    }

                    AnimatedVisibility(visible = activeBgCount > 0) {
                        CompactBannerCard(tint = PhotoHubOrange) {
                            PulsingStatusDot(color = PhotoHubOrange)
                            Text(
                                text = "Uploading $activeBgCount",
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.weight(1f)
                            )
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                color = PhotoHubOrange
                            )
                        }
                    }

                    AnimatedVisibility(visible = uiState.recentlyDeletedNoticeCount > 0) {
                        val sizeStr = Formatter.formatFileSize(context, uiState.recentlyDeletedNoticeBytes)
                        CompactBannerCard(tint = PhotoHubAmber) {
                            Icon(Icons.Rounded.DeleteSweep, contentDescription = null, tint = PhotoHubOrange, modifier = Modifier.size(18.dp))
                            Text(
                                text = "Empty Trash · ~$sizeStr",
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.weight(1f)
                            )
                            TextButton(
                                onClick = {
                                    runCatching {
                                        val intent = Intent(Intent.ACTION_VIEW).apply {
                                            type = "image/*"
                                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                        }
                                        context.startActivity(intent)
                                    }
                                },
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)
                            ) {
                                Text("Gallery", fontWeight = FontWeight.Bold)
                            }
                            IconButton(onClick = { viewModel.dismissRecentlyDeletedNotice() }, modifier = Modifier.size(24.dp)) {
                                Icon(Icons.Rounded.Close, contentDescription = "Dismiss", modifier = Modifier.size(15.dp))
                            }
                        }
                    }

                    uiState.statusBanner?.takeIf { it.isNotBlank() }?.let { banner ->
                        CompactBannerCard(tint = PhotoHubOrange) {
                            Icon(Icons.Rounded.AutoAwesome, contentDescription = null, tint = PhotoHubOrange, modifier = Modifier.size(16.dp))
                            Text(
                                banner,
                                style = MaterialTheme.typography.bodySmall,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }

                    AnimatedVisibility(visible = uiState.isProcessing) {
                        Surface(
                            shape = RoundedCornerShape(18.dp),
                            color = MaterialTheme.colorScheme.surface,
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                modifier = Modifier.padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(12.dp)
                            ) {
                                SunnyMascot(mood = MascotMood.UPLOADING, size = 50.dp)
                                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    val pct = (uiState.overallProgressFraction * 100f).toInt()
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(
                                            text = "$pct%",
                                            style = MaterialTheme.typography.titleSmall,
                                            fontWeight = FontWeight.ExtraBold,
                                            color = PhotoHubOrange
                                        )
                                        Spacer(modifier = Modifier.width(6.dp))
                                        Text(
                                            text = "· ${uiState.completedCount}/${uiState.totalToProcess}",
                                            style = MaterialTheme.typography.labelMedium,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                    }
                                    LinearProgressIndicator(
                                        progress = { uiState.overallProgressFraction },
                                        color = PhotoHubOrange,
                                        trackColor = PhotoHubOrange.copy(alpha = 0.16f),
                                        modifier = Modifier.fillMaxWidth().height(7.dp).clip(CircleShape)
                                    )
                                }
                            }
                        }
                    }
                }

                if (uiState.candidates.isEmpty()) {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        SunnyMascot(mood = heroMood, size = 132.dp)
                        Spacer(modifier = Modifier.height(14.dp))
                        Text(
                            text = when {
                                uiState.accessLevel == MediaAccessLevel.DENIED -> "Photos Access"
                                uiState.isScanning -> "Scanning…"
                                activeBgCount > 0 -> "Syncing…"
                                else -> "Ready"
                            },
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.ExtraBold,
                            textAlign = TextAlign.Center
                        )

                        if (uiState.totalSavedBytes > 0L) {
                            Spacer(modifier = Modifier.height(8.dp))
                            WarmStatChip(
                                text = "Saved ${Formatter.formatFileSize(context, uiState.totalSavedBytes)}",
                                tint = PhotoHubMint,
                                icon = Icons.Rounded.AutoAwesome
                            )
                        }

                        Spacer(modifier = Modifier.height(22.dp))

                        if (uiState.accessLevel == MediaAccessLevel.DENIED) {
                            GradientPrimaryButton(
                                text = "Allow Photos",
                                icon = Icons.Rounded.PhotoLibrary,
                                onClick = { openAppSettings(context) }
                            )
                        } else {
                            GradientPrimaryButton(
                                text = "Auto Backup",
                                icon = Icons.Rounded.Bolt,
                                enabled = !uiState.isScanning && !uiState.isProcessing,
                                onClick = { viewModel.scanAndAutoCompressIfEnabled(forceNow = true) },
                                modifier = Modifier.widthIn(min = 210.dp)
                            )
                            Spacer(modifier = Modifier.height(10.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                SoftOrangeButton(
                                    text = "Pick",
                                    icon = Icons.Rounded.Checklist,
                                    enabled = !uiState.isScanning && !uiState.isProcessing,
                                    onClick = { viewModel.scanLibrary() }
                                )
                                SoftOrangeButton(
                                    text = "Check Proxy",
                                    icon = Icons.Rounded.ImageSearch,
                                    enabled = !uiState.isInspectingGalleryUris && !uiState.isProcessing,
                                    onClick = {
                                        detectProxyPicker.launch(
                                            androidx.activity.result.PickVisualMediaRequest(
                                                ActivityResultContracts.PickVisualMedia.ImageAndVideo
                                            )
                                        )
                                    }
                                )
                            }
                            Spacer(modifier = Modifier.height(10.dp))
                            SoftOrangeButton(
                                text = "Remove Duplicates",
                                icon = Icons.Rounded.ContentCopy,
                                enabled = !uiState.isProcessing,
                                onClick = { viewModel.openDuplicateCleaner() },
                                modifier = Modifier.widthIn(min = 210.dp)
                            )
                        }
                    }
                } else {
                    SummaryHeader(
                        uiState = uiState,
                        isBackupOnlyMode = settingsState.isBackupOnlyMode,
                        keepLocalProxy = settingsState.keepLocalProxyInPhotos,
                        onToggleKeepLocal = { settings.setKeepLocalProxyInPhotos(it) },
                        onSelectVideos = { viewModel.selectTopVideos() }
                    )

                    LazyColumn(modifier = Modifier.fillMaxSize()) {
                        items(uiState.candidates, key = { it.id }) { item ->
                            LaunchedEffect(item.id) {
                                viewModel.loadThumbnailIfNeeded(item)
                            }
                            CandidateRow(
                                item = item,
                                thumbnail = uiState.thumbnails[item.id],
                                onClick = { viewModel.toggleSelection(item.id) }
                            )
                            HorizontalDivider(
                                thickness = 0.5.dp,
                                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)
                            )
                        }
                    }
                }
            }

            if (uiState.isInspectingGalleryUris) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.40f)),
                    contentAlignment = Alignment.Center
                ) {
                    Surface(shape = RoundedCornerShape(24.dp), tonalElevation = 6.dp) {
                        Column(
                            modifier = Modifier.padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            SunnyMascot(mood = MascotMood.UPLOADING, size = 76.dp)
                            Text("Checking…", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CompactBannerCard(
    tint: Color,
    content: @Composable RowScope.() -> Unit
) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = tint.copy(alpha = 0.12f),
        border = BorderStroke(1.dp, tint.copy(alpha = 0.25f)),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            content = content
        )
    }
}

@Composable
private fun SummaryHeader(
    uiState: com.photohub.compressor.viewmodel.CompressUiState,
    isBackupOnlyMode: Boolean,
    keepLocalProxy: Boolean,
    onToggleKeepLocal: (Boolean) -> Unit,
    onSelectVideos: () -> Unit
) {
    val context = LocalContext.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            val estStr = Formatter.formatFileSize(context, uiState.totalEligibleEstimatedBytes)
            WarmStatChip(
                text = "${uiState.candidates.size} · ~$estStr",
                tint = PhotoHubOrange,
                icon = Icons.Rounded.PhotoLibrary
            )

            if (uiState.totalSavedBytes > 0L) {
                WarmStatChip(
                    text = Formatter.formatFileSize(context, uiState.totalSavedBytes),
                    tint = PhotoHubMint,
                    icon = Icons.Rounded.AutoAwesome
                )
            }

            Spacer(modifier = Modifier.weight(1f))

            if (uiState.pendingVideoCandidates.isNotEmpty() && !uiState.isProcessing) {
                val vidStr = Formatter.formatFileSize(context, uiState.pendingVideoEstimatedBytes)
                Surface(
                    onClick = onSelectVideos,
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.primaryContainer
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Icon(Icons.Rounded.Videocam, null, tint = MaterialTheme.colorScheme.onPrimaryContainer, modifier = Modifier.size(14.dp))
                        Text(vidStr, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onPrimaryContainer)
                    }
                }
            }
        }

        if (uiState.isCheckingServerProxies) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                CircularProgressIndicator(modifier = Modifier.size(13.dp), strokeWidth = 2.dp, color = PhotoHubOrange)
                Text("Checking proxies…", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }

        if (isBackupOnlyMode) {
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = PhotoHubMint.copy(alpha = 0.12f),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Icon(
                        Icons.Rounded.VerifiedUser,
                        contentDescription = null,
                        tint = PhotoHubMint,
                        modifier = Modifier.size(16.dp)
                    )
                    Text(
                        text = "Backup Only · Full originals stay untouched on phone",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }
            }
        } else {
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                SegmentedButton(
                    selected = keepLocalProxy,
                    onClick = { onToggleKeepLocal(true) },
                    shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2)
                ) {
                    Text("Keep Proxy", style = MaterialTheme.typography.labelMedium, maxLines = 1)
                }
                SegmentedButton(
                    selected = !keepLocalProxy,
                    onClick = { onToggleKeepLocal(false) },
                    shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2)
                ) {
                    Text("Delete Only", style = MaterialTheme.typography.labelMedium, maxLines = 1)
                }
            }
        }
    }
}

@Composable
private fun CandidateRow(
    item: PhotoCandidate,
    thumbnail: android.graphics.Bitmap?,
    onClick: () -> Unit
) {
    val context = LocalContext.current
    val checkScale by animateFloatAsState(
        targetValue = if (item.isSelected) 1.08f else 1f,
        animationSpec = spring(dampingRatio = 0.6f, stiffness = 450f),
        label = "checkScale"
    )
    val badgeColor = when (item.state) {
        is PhotoCompressionState.Completed -> PhotoHubMint
        is PhotoCompressionState.ReadyToDelete -> PhotoHubAmber
        is PhotoCompressionState.AlreadyProxy -> PhotoHubOrange
        is PhotoCompressionState.Skipped, is PhotoCompressionState.Pending ->
            MaterialTheme.colorScheme.onSurfaceVariant
        is PhotoCompressionState.Failed -> PhotoHubRed
        else -> PhotoHubOrange
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .clickable(enabled = !item.state.isFinished, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = if (item.isSelected) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (item.isSelected) PhotoHubOrange else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            modifier = Modifier
                .size(25.dp)
                .scale(checkScale)
                .alpha(if (item.state.isFinished) 0.3f else 1f)
        )

        Spacer(modifier = Modifier.width(12.dp))

        Box(
            modifier = Modifier
                .size(56.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.BottomEnd
        ) {
            if (thumbnail != null) {
                Image(
                    bitmap = thumbnail.asImageBitmap(),
                    contentDescription = item.filename,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize()
                )
            }
            if (item.isVideo) {
                Box(
                    modifier = Modifier
                        .padding(3.dp)
                        .clip(CircleShape)
                        .background(PhotoHubOrange)
                        .padding(4.dp)
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Videocam,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(10.dp)
                    )
                }
            }
        }

        Spacer(modifier = Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = item.filename,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = item.estimatedSizeLabel(context),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                    color = if (item.isVideo) PhotoHubOrange else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            val dateSuffix = item.creationDateMs?.let { ms ->
                remember(ms) {
                    " · ${java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(java.util.Date(ms))}"
                }
            }.orEmpty()
            Text(
                text = "${item.resolutionLabel}$dateSuffix",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )

            if (item.state !is PhotoCompressionState.Pending || item.isBackedUpOnServer) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    if (item.state.isIntegrityVerified || item.isBackedUpOnServer) {
                        Icon(
                            imageVector = Icons.Rounded.Verified,
                            contentDescription = null,
                            tint = PhotoHubMint,
                            modifier = Modifier.size(14.dp)
                        )
                    }

                    val statusText = if (item.state is PhotoCompressionState.Pending && item.isBackedUpOnServer) {
                        "Backed Up"
                    } else {
                        item.state.label(context)
                    }
                    Text(
                        text = statusText,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = if (item.state is PhotoCompressionState.Pending && item.isBackedUpOnServer) PhotoHubMint else badgeColor,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
    }
}

@Composable
private fun GalleryProxyInspectionDialog(
    items: List<GalleryProxyInspectionItem>,
    busyItemId: String?,
    onRestore: (GalleryProxyInspectionItem) -> Unit,
    onShareOriginal: (GalleryProxyInspectionItem) -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val proxyCount = items.count { it.kind == GalleryMediaKind.PROXY }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                text = if (proxyCount > 0) "$proxyCount Proxy · ${items.size} Checked" else "${items.size} Original",
                fontWeight = FontWeight.Bold
            )
        },
        text = {
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 420.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                items(items, key = { it.id }) { item ->
                    val isBusy = busyItemId == item.id
                    Surface(
                        shape = RoundedCornerShape(16.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(
                            modifier = Modifier.padding(10.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(48.dp)
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(MaterialTheme.colorScheme.surface),
                                    contentAlignment = Alignment.Center
                                ) {
                                    if (item.thumbnail != null) {
                                        Image(
                                            bitmap = item.thumbnail.asImageBitmap(),
                                            contentDescription = item.displayName,
                                            contentScale = ContentScale.Crop,
                                            modifier = Modifier.fillMaxSize()
                                        )
                                    } else {
                                        Icon(
                                            if (item.isVideo) Icons.Rounded.Videocam else Icons.Rounded.Photo,
                                            contentDescription = null,
                                            tint = PhotoHubOrange
                                        )
                                    }
                                }
                                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Text(
                                        item.originalName ?: item.displayName,
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    val (verdictLabel, verdictColor) = when (item.kind) {
                                        GalleryMediaKind.PROXY -> "PROXY" to PhotoHubOrange
                                        GalleryMediaKind.ORIGINAL_BACKED_UP -> "ORIGINAL · SYNCED" to PhotoHubMint
                                        GalleryMediaKind.ORIGINAL_UNBACKED -> "ORIGINAL" to MaterialTheme.colorScheme.onSurfaceVariant
                                        GalleryMediaKind.UNKNOWN -> "UNKNOWN" to MaterialTheme.colorScheme.onSurfaceVariant
                                    }
                                    WarmStatChip(text = verdictLabel, tint = verdictColor)
                                }
                            }

                            val localStr = Formatter.formatFileSize(context, item.localSizeBytes)
                            val origStr = item.originalSizeBytes?.takeIf { it > 0L }?.let {
                                " → ${Formatter.formatFileSize(context, it)}"
                            }.orEmpty()
                            Text(
                                "$localStr$origStr",
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )

                            if (item.kind == GalleryMediaKind.PROXY && !item.masterHash.isNullOrBlank()) {
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    SoftOrangeButton(
                                        text = "Share",
                                        icon = Icons.Rounded.IosShare,
                                        enabled = busyItemId == null,
                                        onClick = { onShareOriginal(item) },
                                        modifier = Modifier.weight(1f)
                                    )
                                    GradientPrimaryButton(
                                        text = if (item.isProtectedOriginal) "Restored" else "Restore",
                                        icon = Icons.Rounded.CloudDownload,
                                        enabled = busyItemId == null,
                                        loading = isBusy,
                                        onClick = { onRestore(item) },
                                        modifier = Modifier.weight(1f)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Done", fontWeight = FontWeight.Bold) }
        }
    )
}

@Composable
private fun CleanupPreviewConfirmDialog(
    items: List<com.photohub.compressor.viewmodel.CleanupPreviewItem>,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit
) {
    val context = LocalContext.current
    val totalBytes = items.sumOf { it.savedBytes.coerceAtLeast(0L) }
    val totalStr = Formatter.formatFileSize(context, totalBytes)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Icon(Icons.Rounded.Verified, null, tint = PhotoHubMint, modifier = Modifier.size(22.dp))
                Text("Free ~$totalStr Safely", fontWeight = FontWeight.ExtraBold)
            }
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "These ${items.size} original(s) are SHA-256 verified on your cloud server and safe to remove from your phone:",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                androidx.compose.foundation.lazy.LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    items(items.take(24).size) { idx ->
                        val item = items[idx]
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier.width(68.dp)
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(64.dp)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant),
                                contentAlignment = Alignment.Center
                            ) {
                                if (item.thumbnail != null) {
                                    Image(
                                        bitmap = item.thumbnail.asImageBitmap(),
                                        contentDescription = item.filename,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize()
                                    )
                                } else {
                                    Icon(Icons.Rounded.Photo, null, tint = PhotoHubOrange)
                                }
                                Box(
                                    modifier = Modifier
                                        .align(Alignment.TopEnd)
                                        .padding(4.dp)
                                        .size(16.dp)
                                        .clip(CircleShape)
                                        .background(PhotoHubMint),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Icon(Icons.Rounded.Check, null, tint = Color.White, modifier = Modifier.size(11.dp))
                                }
                            }
                            Spacer(modifier = Modifier.height(3.dp))
                            Text(
                                text = Formatter.formatFileSize(context, item.savedBytes.coerceAtLeast(0L)),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1
                            )
                        }
                    }
                }
                if (items.size > 24) {
                    Text(
                        "+ ${items.size - 24} more verified item(s)",
                        style = MaterialTheme.typography.labelSmall,
                        color = PhotoHubOrange,
                        fontWeight = FontWeight.Bold
                    )
                }
            }
        },
        confirmButton = {
            Button(
                onClick = onConfirm,
                colors = ButtonDefaults.buttonColors(containerColor = PhotoHubOrange)
            ) {
                Text("Free Space (${items.size})", fontWeight = FontWeight.Bold)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}

@Composable
private fun DuplicateCleanerDialog(
    state: com.photohub.compressor.viewmodel.DuplicateCleanerUiState,
    onRescan: () -> Unit,
    onToggleItem: (String) -> Unit,
    onLoadThumb: (String) -> Unit,
    onAutoRemove: () -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val selectedCount = state.selectedDeleteItems.size
    val freedStr = Formatter.formatFileSize(context, state.selectedFreedBytes)

    androidx.compose.ui.window.Dialog(
        onDismissRequest = { if (!state.isDeleting) onDismiss() },
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Surface(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = 18.dp),
            shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
            color = MaterialTheme.colorScheme.background
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    TextButton(onClick = onDismiss, enabled = !state.isDeleting) {
                        Text("Close", fontWeight = FontWeight.Bold)
                    }
                    Text(
                        text = "Duplicate Cleaner",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.ExtraBold,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.weight(1f)
                    )
                    IconButton(onClick = onRescan, enabled = !state.isScanning && !state.isDeleting) {
                        Icon(Icons.Rounded.Refresh, contentDescription = "Rescan")
                    }
                }
                HorizontalDivider()

                when {
                    state.isScanning -> {
                        Column(
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(28.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center
                        ) {
                            SunnyMascot(mood = MascotMood.UPLOADING, size = 116.dp)
                            Spacer(modifier = Modifier.height(16.dp))
                            Text(
                                text = "Scanning for Duplicates…",
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.ExtraBold
                            )
                            Spacer(modifier = Modifier.height(6.dp))
                            Text(
                                text = state.progressLabel,
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.Center
                            )
                            Spacer(modifier = Modifier.height(16.dp))
                            val frac = (state.progressCurrent.toFloat() / state.progressTotal.coerceAtLeast(1).toFloat()).coerceIn(0f, 1f)
                            LinearProgressIndicator(
                                progress = { frac },
                                color = PhotoHubOrange,
                                trackColor = PhotoHubOrange.copy(alpha = 0.18f),
                                modifier = Modifier
                                    .width(240.dp)
                                    .height(7.dp)
                                    .clip(CircleShape)
                            )
                            Spacer(modifier = Modifier.height(12.dp))
                            Text(
                                text = "Checks duplicate proxies, exact SHA-256 files & visually identical copies locally on your phone.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.Center
                            )
                        }
                    }

                    state.result?.groups.isNullOrEmpty() -> {
                        Column(
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(28.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center
                        ) {
                            SunnyMascot(mood = MascotMood.CELEBRATE, size = 124.dp)
                            Spacer(modifier = Modifier.height(16.dp))
                            if (state.completedRemovedCount > 0) {
                                val doneSize = Formatter.formatFileSize(context, state.completedFreedBytes)
                                Text(
                                    text = "Duplicates Removed!",
                                    style = MaterialTheme.typography.headlineSmall,
                                    fontWeight = FontWeight.ExtraBold
                                )
                                Spacer(modifier = Modifier.height(8.dp))
                                WarmStatChip(
                                    text = "Moved ${state.completedRemovedCount} duplicate(s) · ~$doneSize",
                                    tint = PhotoHubMint,
                                    icon = Icons.Rounded.AutoAwesome
                                )
                                Spacer(modifier = Modifier.height(10.dp))
                                Text(
                                    text = "Moved safely to Trash (recoverable for 30 days). The best copy of every photo was kept.",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    textAlign = TextAlign.Center
                                )
                            } else {
                                Text(
                                    text = "No Duplicates Found",
                                    style = MaterialTheme.typography.headlineSmall,
                                    fontWeight = FontWeight.ExtraBold
                                )
                                Spacer(modifier = Modifier.height(8.dp))
                                Text(
                                    text = state.errorMessage
                                        ?: "Scanned ${state.result?.scannedCount ?: 0} item(s) on your phone. Your photo gallery is spotless!",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    textAlign = TextAlign.Center
                                )
                            }
                            Spacer(modifier = Modifier.height(22.dp))
                            GradientPrimaryButton(
                                text = "Done",
                                icon = Icons.Rounded.Check,
                                onClick = onDismiss,
                                modifier = Modifier.widthIn(min = 180.dp)
                            )
                        }
                    }

                    else -> {
                        val groups = state.result!!.groups
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(MaterialTheme.colorScheme.surface)
                                .padding(horizontal = 16.dp, vertical = 10.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                WarmStatChip(
                                    text = "${groups.size} group(s) · $selectedCount dup(s)",
                                    tint = PhotoHubOrange,
                                    icon = Icons.Rounded.ContentCopy
                                )
                                WarmStatChip(
                                    text = "Free ~$freedStr",
                                    tint = PhotoHubMint,
                                    icon = Icons.Rounded.AutoAwesome
                                )
                            }
                            state.statusMessage?.let {
                                Text(it, style = MaterialTheme.typography.labelMedium, color = PhotoHubMint)
                            }
                            state.errorMessage?.let {
                                Text(it, style = MaterialTheme.typography.labelMedium, color = PhotoHubRed)
                            }
                        }

                        LazyColumn(
                            modifier = Modifier
                                .weight(1f)
                                .fillMaxWidth(),
                            contentPadding = PaddingValues(14.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            items(groups, key = { it.id }) { group ->
                                Surface(
                                    shape = RoundedCornerShape(18.dp),
                                    color = MaterialTheme.colorScheme.surface,
                                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
                                ) {
                                    Column(
                                        modifier = Modifier.padding(12.dp),
                                        verticalArrangement = Arrangement.spacedBy(10.dp)
                                    ) {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            WarmStatChip(text = group.reason.label, tint = PhotoHubOrange)
                                            Spacer(modifier = Modifier.width(8.dp))
                                            Text(
                                                text = "${group.items.size} copies",
                                                style = MaterialTheme.typography.labelMedium,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant
                                            )
                                            Spacer(modifier = Modifier.weight(1f))
                                            Text(
                                                text = "Save ~${Formatter.formatFileSize(context, group.reclaimableBytes)}",
                                                style = MaterialTheme.typography.labelMedium,
                                                fontWeight = FontWeight.Bold,
                                                color = PhotoHubMint
                                            )
                                        }

                                        androidx.compose.foundation.lazy.LazyRow(
                                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                                        ) {
                                            items(group.items.size) { idx ->
                                                val item = group.items[idx]
                                                LaunchedEffect(item.id) { onLoadThumb(item.id) }
                                                val isMarked = !item.isKeep && item.id in state.selectedDeleteIds
                                                val borderColor = when {
                                                    item.isKeep -> PhotoHubMint
                                                    isMarked -> PhotoHubRed
                                                    else -> MaterialTheme.colorScheme.outlineVariant
                                                }
                                                Column(
                                                    modifier = Modifier
                                                        .width(96.dp)
                                                        .clickable(enabled = !item.isKeep) { onToggleItem(item.id) },
                                                    verticalArrangement = Arrangement.spacedBy(4.dp)
                                                ) {
                                                    Box(
                                                        modifier = Modifier
                                                            .size(96.dp)
                                                            .clip(RoundedCornerShape(12.dp))
                                                            .background(MaterialTheme.colorScheme.surfaceVariant)
                                                            .clickable(enabled = !item.isKeep) { onToggleItem(item.id) },
                                                        contentAlignment = Alignment.Center
                                                    ) {
                                                        val bmp = state.thumbnails[item.id]
                                                        if (bmp != null) {
                                                            Image(
                                                                bitmap = bmp.asImageBitmap(),
                                                                contentDescription = item.filename,
                                                                contentScale = ContentScale.Crop,
                                                                modifier = Modifier.fillMaxSize()
                                                            )
                                                        } else {
                                                            Icon(
                                                                if (item.isVideo) Icons.Rounded.Videocam else Icons.Rounded.Photo,
                                                                contentDescription = null,
                                                                tint = PhotoHubOrange
                                                            )
                                                        }
                                                        Surface(
                                                            modifier = Modifier
                                                                .align(Alignment.TopStart)
                                                                .padding(5.dp),
                                                            shape = CircleShape,
                                                            color = when {
                                                                item.isKeep -> PhotoHubMint
                                                                isMarked -> PhotoHubRed
                                                                else -> Color.Black.copy(alpha = 0.65f)
                                                            }
                                                        ) {
                                                            Text(
                                                                text = when {
                                                                    item.isKeep -> "KEEP"
                                                                    isMarked -> "REMOVE"
                                                                    else -> "SKIP"
                                                                },
                                                                style = MaterialTheme.typography.labelSmall,
                                                                fontWeight = FontWeight.ExtraBold,
                                                                color = Color.White,
                                                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                                            )
                                                        }
                                                        Surface(
                                                            modifier = Modifier.fillMaxSize(),
                                                            shape = RoundedCornerShape(12.dp),
                                                            color = Color.Transparent,
                                                            border = BorderStroke(2.5.dp, borderColor)
                                                        ) {}
                                                    }
                                                    Text(
                                                        text = Formatter.formatFileSize(context, item.sizeBytes.coerceAtLeast(0L)),
                                                        style = MaterialTheme.typography.labelSmall,
                                                        fontWeight = FontWeight.Bold,
                                                        maxLines = 1
                                                    )
                                                    Text(
                                                        text = if (item.isProxy) "Proxy" else "${item.width}×${item.height}",
                                                        style = MaterialTheme.typography.labelSmall,
                                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                        maxLines = 1
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Surface(
                            color = MaterialTheme.colorScheme.surface,
                            tonalElevation = 4.dp,
                            shadowElevation = 8.dp
                        ) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 16.dp, vertical = 12.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                GradientPrimaryButton(
                                    text = if (state.isDeleting) {
                                        "Removing Duplicates…"
                                    } else {
                                        "Auto Remove $selectedCount Duplicate${if (selectedCount == 1) "" else "s"} (~$freedStr)"
                                    },
                                    icon = Icons.Rounded.DeleteSweep,
                                    enabled = selectedCount > 0 && !state.isDeleting,
                                    loading = state.isDeleting,
                                    onClick = onAutoRemove,
                                    modifier = Modifier.fillMaxWidth()
                                )
                                Text(
                                    text = "Always keeps the best original · Removed copies stay in Trash for 30 days",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    textAlign = TextAlign.Center
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun openAppSettings(context: android.content.Context) {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
        data = Uri.fromParts("package", context.packageName, null)
        flags = Intent.FLAG_ACTIVITY_NEW_TASK
    }
    context.startActivity(intent)
}
