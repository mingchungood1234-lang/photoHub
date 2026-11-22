package com.photohub.compressor.ui.screens

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
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
    val settingsState by settings.state.collectAsStateWithLifecycle()
    val bgState by bgManager.state.collectAsStateWithLifecycle()

    var showMenu by remember { mutableStateOf(false) }

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
                    originalFilename = item.originalName
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

    LaunchedEffect(Unit) {
        viewModel.refreshPermissionsAndSync()
        if (uiState.candidates.isEmpty()) {
            viewModel.scanAndAutoCompressIfEnabled()
        }
    }

    if (uiState.deleteErrorAlertMessage != null) {
        AlertDialog(
            onDismissRequest = { viewModel.clearDeleteError() },
            title = { Text("Delete Original Photo") },
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
                        Text("Open Settings")
                    }
                    TextButton(onClick = { viewModel.dismissPendingDeleteAfterError() }) {
                        Text("OK")
                    }
                }
            }
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Compress", fontWeight = FontWeight.SemiBold) },
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
                        onClick = {
                            detectProxyPicker.launch(
                                androidx.activity.result.PickVisualMediaRequest(
                                    ActivityResultContracts.PickVisualMedia.ImageAndVideo
                                )
                            )
                        },
                        enabled = !uiState.isInspectingGalleryUris && !uiState.isProcessing
                    ) {
                        Icon(Icons.Rounded.ImageSearch, contentDescription = "Detect Proxy in Gallery")
                    }

                    if (uiState.candidates.isNotEmpty()) {
                        Box {
                            IconButton(
                                onClick = { showMenu = true },
                                enabled = !uiState.isProcessing
                            ) {
                                Icon(Icons.Rounded.FilterList, contentDescription = "Sort & Filter")
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
                                        text = { Text("Select Largest Videos") },
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
                                    text = { Text("Deselect All") },
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
                Surface(tonalElevation = 3.dp, shadowElevation = 6.dp) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 12.dp)
                    ) {
                        Button(
                            onClick = { viewModel.startProcessingSelectedPhotos() },
                            enabled = !uiState.isProcessing,
                            shape = RoundedCornerShape(14.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(52.dp)
                        ) {
                            Icon(Icons.Rounded.VerifiedUser, contentDescription = null)
                            Spacer(modifier = Modifier.width(8.dp))
                            val n = uiState.selectedCount
                            val label = if (settingsState.keepLocalProxyInPhotos) {
                                "Upload, Compress & Delete $n Original${if (n == 1) "" else "s"}"
                            } else {
                                "Back Up & Delete $n Original${if (n == 1) "" else "s"}"
                            }
                            Text(label, fontWeight = FontWeight.SemiBold)
                        }
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
            if (uiState.accessLevel == MediaAccessLevel.LIMITED_ACCESS) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(PhotoHubOrange.copy(alpha = 0.15f))
                        .padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(Icons.Rounded.Warning, contentDescription = null, tint = PhotoHubOrange)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Limited Photos Access: Switch to Allow All in Android Settings to scan and remove all originals.",
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.weight(1f)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Button(
                        onClick = { openAppSettings(context) },
                        colors = ButtonDefaults.buttonColors(containerColor = PhotoHubOrange),
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                    ) {
                        Text("Full Access", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
                    }
                }
            }

            if (bgState.stagedItems.isNotEmpty() && !uiState.isProcessing && !uiState.isAwaitingDeleteConfirmation) {
                val count = bgState.stagedItems.size
                val sizeStr = Formatter.formatFileSize(context, bgState.stagedSavedBytes)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(PhotoHubIndigo.copy(alpha = 0.10f))
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(Icons.Rounded.Verified, contentDescription = null, tint = PhotoHubIndigo)
                    Spacer(modifier = Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "$count Original${if (count == 1) "" else "s"} Backed Up & Ready to Delete",
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            text = "Safely uploaded & SHA-256 verified on your server. Move original file${if (count == 1) "" else "s"} to Trash to free ~$sizeStr.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Spacer(modifier = Modifier.width(8.dp))
                    Button(
                        onClick = { viewModel.triggerStagedOvernightCleanupPrompt() },
                        colors = ButtonDefaults.buttonColors(containerColor = PhotoHubIndigo),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                    ) {
                        Text("Delete Originals", style = MaterialTheme.typography.labelSmall)
                    }
                    IconButton(onClick = { bgManager.clearAllStagedItems() }, modifier = Modifier.size(28.dp)) {
                        Icon(Icons.Rounded.Close, contentDescription = "Dismiss", modifier = Modifier.size(16.dp))
                    }
                }
            }

            if (uiState.backgroundActiveCount > 0) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(PhotoHubBlue.copy(alpha = 0.08f))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(modifier = Modifier.width(8.dp))
                    val c = uiState.backgroundActiveCount
                    Text(
                        text = "Background upload running for $c item${if (c == 1) "" else "s"} — automatically skipped from manual upload to prevent duplicates.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            if (uiState.recentlyDeletedNoticeCount > 0) {
                val sizeStr = Formatter.formatFileSize(context, uiState.recentlyDeletedNoticeBytes)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(PhotoHubOrange.copy(alpha = 0.12f))
                        .padding(12.dp),
                    verticalAlignment = Alignment.Top
                ) {
                    Icon(Icons.Rounded.Info, contentDescription = null, tint = PhotoHubOrange)
                    Spacer(modifier = Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "One More Step to Free ~$sizeStr Right Now",
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            text = "Android Gallery moved the ${uiState.recentlyDeletedNoticeCount} deleted original(s) to Trash for 30 days. Empty Gallery Trash to reclaim storage immediately.",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
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
                                contentPadding = PaddingValues(0.dp)
                            ) {
                                Text("Open Gallery", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                            }
                            TextButton(
                                onClick = { viewModel.dismissRecentlyDeletedNotice() },
                                contentPadding = PaddingValues(0.dp)
                            ) {
                                Text("Dismiss", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }

            uiState.statusBanner?.let { banner ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(PhotoHubBlue.copy(alpha = 0.10f))
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(Icons.Rounded.Info, contentDescription = null, tint = PhotoHubBlue)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(banner, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                }
            }

            if (uiState.isProcessing) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    LinearProgressIndicator(
                        progress = { uiState.overallProgressFraction },
                        modifier = Modifier.fillMaxWidth()
                    )
                    val pct = (uiState.overallProgressFraction * 100f).toInt()
                    Text(
                        text = "Uploading & Compressing $pct% (${uiState.completedCount}/${uiState.totalToProcess})…",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
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
                    Icon(
                        imageVector = Icons.Rounded.PhotoLibrary,
                        contentDescription = null,
                        modifier = Modifier.size(64.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(14.dp))
                    Text(
                        text = "Ready to Back Up & Free Space",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.SemiBold,
                        textAlign = TextAlign.Center
                    )
                    Spacer(modifier = Modifier.height(6.dp))
                    Text(
                        text = if (uiState.accessLevel == MediaAccessLevel.DENIED) {
                            "Photos & Videos permission is required. Open Android Settings to allow access."
                        } else {
                            "New photos & videos upload silently in the background, and photoHub notifies you when originals are ready to delete — or tap below to scan and free space now."
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center
                    )
                    Spacer(modifier = Modifier.height(18.dp))
                    if (uiState.accessLevel == MediaAccessLevel.DENIED) {
                        Button(onClick = { openAppSettings(context) }) {
                            Text("Open Android Settings")
                        }
                    } else {
                        Button(
                            onClick = { viewModel.scanAndAutoCompressIfEnabled(forceNow = true) },
                            enabled = !uiState.isScanning && !uiState.isProcessing
                        ) {
                            Text("Auto-Upload New Photos & Videos")
                        }
                        Spacer(modifier = Modifier.height(8.dp))
                        OutlinedButton(
                            onClick = { viewModel.scanLibrary() },
                            enabled = !uiState.isScanning && !uiState.isProcessing
                        ) {
                            Text("Scan & Choose Manually")
                        }
                        Spacer(modifier = Modifier.height(8.dp))
                        OutlinedButton(
                            onClick = {
                                detectProxyPicker.launch(
                                    androidx.activity.result.PickVisualMediaRequest(
                                        ActivityResultContracts.PickVisualMedia.ImageAndVideo
                                    )
                                )
                            },
                            enabled = !uiState.isInspectingGalleryUris && !uiState.isProcessing
                        ) {
                            Icon(Icons.Rounded.ImageSearch, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("Detect Proxy in Gallery")
                        }
                    }
                }
            } else {
                SummaryHeader(
                    uiState = uiState,
                    keepLocalProxy = settingsState.keepLocalProxyInPhotos,
                    onToggleKeepLocal = { settings.setKeepLocalProxyInPhotos(it) },
                    onSelectVideos = { viewModel.selectTopVideos() },
                    onSelectFilter = { viewModel.setFilterMode(it) }
                )

                val visibleList = uiState.displayedCandidates
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(visibleList, key = { it.id }) { item ->
                        LaunchedEffect(item.id) {
                            viewModel.loadThumbnailIfNeeded(item)
                        }
                        CandidateRow(
                            item = item,
                            thumbnail = uiState.thumbnails[item.id],
                            isBusy = uiState.inspectionBusyId == item.id,
                            onClick = { viewModel.toggleSelection(item.id) },
                            onRestoreProxy = if (item.isDetectedProxy && !item.masterHash.isNullOrBlank()) {
                                {
                                    viewModel.restoreOriginalFromDetectedProxy(
                                        itemId = item.id,
                                        rawMasterHash = item.masterHash,
                                        originalFilename = item.linkedOriginalName ?: item.filename,
                                        isVideo = item.isVideo
                                    )
                                }
                            } else {
                                null
                            }
                        )
                        HorizontalDivider(thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
                    }
                }
            }
        }

        if (uiState.isInspectingGalleryUris) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.45f)),
                contentAlignment = Alignment.Center
            ) {
                Surface(shape = RoundedCornerShape(16.dp), tonalElevation = 6.dp) {
                    Column(
                        modifier = Modifier.padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        CircularProgressIndicator()
                        Text("Detecting Proxy vs Original status…", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                    }
                }
            }
        }
        }
    }
}

@Composable
private fun SummaryHeader(
    uiState: com.photohub.compressor.viewmodel.CompressUiState,
    keepLocalProxy: Boolean,
    onToggleKeepLocal: (Boolean) -> Unit,
    onSelectVideos: () -> Unit,
    onSelectFilter: (CompressFilterMode) -> Unit
) {
    val context = LocalContext.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f))
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.VerifiedUser, contentDescription = null, tint = PhotoHubGreen, modifier = Modifier.size(16.dp))
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = "SHA-256 verified before delete · Originals stay restorable",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f)
            )
            if (uiState.totalSavedBytes > 0L) {
                val savedStr = Formatter.formatFileSize(context, uiState.totalSavedBytes)
                Surface(
                    shape = CircleShape,
                    color = PhotoHubGreen.copy(alpha = 0.16f)
                ) {
                    Text(
                        text = "Saved $savedStr",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = PhotoHubGreen,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                    )
                }
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "${uiState.candidates.size} Items · Selected ${uiState.selectedCount}",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )
                val estStr = Formatter.formatFileSize(context, uiState.totalEligibleEstimatedBytes)
                Text(
                    text = if (uiState.detectedProxyCount > 0) {
                        "Uncompressed: ~$estStr · ${uiState.detectedProxyCount} proxy(s) detected"
                    } else {
                        "Estimated phone space: ~$estStr"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            if (uiState.pendingVideoCandidates.isNotEmpty() && !uiState.isProcessing) {
                val vidStr = Formatter.formatFileSize(context, uiState.pendingVideoEstimatedBytes)
                OutlinedButton(
                    onClick = onSelectVideos,
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                ) {
                    Icon(Icons.Rounded.Videocam, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("Videos (~$vidStr)", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold)
                }
            }
        }

        if (uiState.detectedProxyCount > 0 || uiState.filterMode != CompressFilterMode.ALL) {
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                val modes = listOf(
                    CompressFilterMode.ALL to "All (${uiState.candidates.size})",
                    CompressFilterMode.ORIGINALS to "Originals (${uiState.originalCandidatesCount})",
                    CompressFilterMode.PROXIES to "Proxies (${uiState.detectedProxyCount})"
                )
                modes.forEachIndexed { index, (mode, label) ->
                    SegmentedButton(
                        selected = uiState.filterMode == mode,
                        onClick = { onSelectFilter(mode) },
                        shape = SegmentedButtonDefaults.itemShape(index = index, count = modes.size)
                    ) {
                        Text(label, style = MaterialTheme.typography.labelSmall, maxLines = 1)
                    }
                }
            }
        }

        if (uiState.isCheckingServerProxies) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                Text(
                    text = "Checking server index for renamed Gallery proxies…",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
            SegmentedButton(
                selected = keepLocalProxy,
                onClick = { onToggleKeepLocal(true) },
                shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2)
            ) {
                Text("Replace Original w/ Proxy", style = MaterialTheme.typography.labelMedium, maxLines = 1)
            }
            SegmentedButton(
                selected = !keepLocalProxy,
                onClick = { onToggleKeepLocal(false) },
                shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2)
            ) {
                Text("Delete Original Only", style = MaterialTheme.typography.labelMedium, maxLines = 1)
            }
        }

        Text(
            text = if (keepLocalProxy) {
                "After upload & SHA-256 verification: keeps a lightweight proxy in Gallery and prompts you to delete the large original."
            } else {
                "After upload & SHA-256 verification: prompts you to delete the original from Gallery completely (stays backed up on Server)."
            },
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun CandidateRow(
    item: PhotoCandidate,
    thumbnail: android.graphics.Bitmap?,
    isBusy: Boolean,
    onClick: () -> Unit,
    onRestoreProxy: (() -> Unit)?
) {
    val context = LocalContext.current
    val badgeColor = when (item.state) {
        is PhotoCompressionState.Completed -> PhotoHubGreen
        is PhotoCompressionState.ReadyToDelete -> PhotoHubOrange
        is PhotoCompressionState.AlreadyProxy -> PhotoHubBlue
        is PhotoCompressionState.Skipped, is PhotoCompressionState.Pending ->
            MaterialTheme.colorScheme.onSurfaceVariant
        is PhotoCompressionState.Failed -> PhotoHubRed
        else -> PhotoHubBlue
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = !item.state.isFinished, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = if (item.isSelected) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (item.isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .size(26.dp)
                .alpha(if (item.state.isFinished) 0.3f else 1f)
        )

        Spacer(modifier = Modifier.width(12.dp))

        Box(
            modifier = Modifier
                .size(56.dp)
                .clip(RoundedCornerShape(8.dp))
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
                        .background(Color.Black.copy(alpha = 0.65f))
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
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = item.estimatedSizeLabel(context),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Medium,
                    color = if (item.isVideo) PhotoHubOrange else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = item.resolutionLabel,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                item.creationDateMs?.let { ms ->
                    val dateText = remember(ms) {
                        java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(java.util.Date(ms))
                    }
                    Text(
                        text = dateText,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (item.state.isIntegrityVerified) {
                    Icon(
                        imageVector = Icons.Rounded.VerifiedUser,
                        contentDescription = null,
                        tint = PhotoHubGreen,
                        modifier = Modifier.size(14.dp)
                    )
                } else if (item.isDetectedProxy) {
                    Surface(shape = CircleShape, color = PhotoHubBlue.copy(alpha = 0.14f)) {
                        Text(
                            text = "PROXY",
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.Bold,
                            color = PhotoHubBlue,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp)
                        )
                    }
                } else if (item.isBackedUpOnServer) {
                    Surface(shape = CircleShape, color = PhotoHubGreen.copy(alpha = 0.14f)) {
                        Text(
                            text = "ORIGINAL · BACKED UP",
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.Bold,
                            color = PhotoHubGreen,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp)
                        )
                    }
                }

                val statusText = when {
                    item.isDetectedProxy -> {
                        val src = item.detectionSource ?: "Detected"
                        val origSz = item.linkedOriginalBytes?.takeIf { it > 0L }?.let {
                            " · Orig ${Formatter.formatFileSize(context, it)}"
                        }.orEmpty()
                        "$src$origSz"
                    }
                    else -> item.state.label(context)
                }
                Text(
                    text = statusText,
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = badgeColor,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }

        if (onRestoreProxy != null) {
            Spacer(modifier = Modifier.width(6.dp))
            if (isBusy) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                IconButton(onClick = onRestoreProxy) {
                    Icon(
                        Icons.Rounded.CloudDownload,
                        contentDescription = "Restore Original",
                        tint = MaterialTheme.colorScheme.primary
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
                text = if (proxyCount > 0) {
                    "Detected $proxyCount Proxy of ${items.size}"
                } else {
                    "Checked ${items.size} Gallery Item(s)"
                },
                fontWeight = FontWeight.SemiBold
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
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
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
                                        .clip(RoundedCornerShape(8.dp))
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
                                            contentDescription = null
                                        )
                                    }
                                }
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        item.originalName ?: item.displayName,
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.Medium,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    val (verdictLabel, verdictColor) = when (item.kind) {
                                        GalleryMediaKind.PROXY -> "COMPRESSED PROXY" to PhotoHubOrange
                                        GalleryMediaKind.ORIGINAL_BACKED_UP -> "ORIGINAL (BACKED UP)" to PhotoHubGreen
                                        GalleryMediaKind.ORIGINAL_UNBACKED -> "ORIGINAL (NOT BACKED UP)" to MaterialTheme.colorScheme.onSurfaceVariant
                                        GalleryMediaKind.UNKNOWN -> "ORIGINAL / UNKNOWN (OFFLINE)" to MaterialTheme.colorScheme.onSurfaceVariant
                                    }
                                    Surface(shape = CircleShape, color = verdictColor.copy(alpha = 0.14f)) {
                                        Text(
                                            verdictLabel,
                                            style = MaterialTheme.typography.labelSmall,
                                            fontWeight = FontWeight.Bold,
                                            color = verdictColor,
                                            modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp)
                                        )
                                    }
                                }
                            }

                            val localStr = Formatter.formatFileSize(context, item.localSizeBytes)
                            val origStr = item.originalSizeBytes?.takeIf { it > 0L }?.let {
                                " · Server Original: ${Formatter.formatFileSize(context, it)}"
                            }.orEmpty()
                            val signalText = if (item.signals.isNotEmpty()) {
                                "Detected via: ${item.signals.joinToString(", ")}"
                            } else {
                                "No proxy tag or server proxy match found"
                            }
                            Text(
                                "Local size: $localStr$origStr\n$signalText",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )

                            if (item.kind == GalleryMediaKind.PROXY && !item.masterHash.isNullOrBlank()) {
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    OutlinedButton(
                                        onClick = { onShareOriginal(item) },
                                        enabled = busyItemId == null,
                                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                                    ) {
                                        Icon(Icons.Rounded.IosShare, null, modifier = Modifier.size(16.dp))
                                        Spacer(modifier = Modifier.width(4.dp))
                                        Text("Share Original", style = MaterialTheme.typography.labelSmall)
                                    }
                                    Button(
                                        onClick = { onRestore(item) },
                                        enabled = busyItemId == null,
                                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                                    ) {
                                        if (isBusy) {
                                            CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp, color = Color.White)
                                        } else {
                                            Icon(Icons.Rounded.CloudDownload, null, modifier = Modifier.size(16.dp))
                                        }
                                        Spacer(modifier = Modifier.width(4.dp))
                                        Text(
                                            if (item.isProtectedOriginal) "Restored ✓" else "Restore",
                                            style = MaterialTheme.typography.labelSmall
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        }
    )
}

private fun openAppSettings(context: android.content.Context) {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
        data = Uri.fromParts("package", context.packageName, null)
        flags = Intent.FLAG_ACTIVITY_NEW_TASK
    }
    context.startActivity(intent)
}
