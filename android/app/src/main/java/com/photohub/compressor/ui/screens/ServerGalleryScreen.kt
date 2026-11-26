package com.photohub.compressor.ui.screens

import android.content.ComponentName
import android.content.Intent
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.photohub.compressor.ShareOriginalActivity
import com.photohub.compressor.data.ServerPhoto
import com.photohub.compressor.media.MediaLibraryService
import com.photohub.compressor.media.ShareUtils
import com.photohub.compressor.sync.LocalProxySyncManager
import com.photohub.compressor.ui.components.GradientPrimaryButton
import com.photohub.compressor.ui.components.MascotMood
import com.photohub.compressor.ui.components.SunnyMascot
import com.photohub.compressor.ui.theme.PhotoHubGreen
import com.photohub.compressor.ui.theme.PhotoHubOrange
import com.photohub.compressor.viewmodel.*
import kotlinx.coroutines.launch
import java.io.File
import java.util.Locale
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ServerGalleryScreen(
    viewModel: ServerGalleryViewModel,
    syncManager: LocalProxySyncManager
) {
    val context = LocalContext.current
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val syncState by syncManager.state.collectAsStateWithLifecycle()
    val detailState by viewModel.detailState.collectAsStateWithLifecycle()

    val scope = rememberCoroutineScope()
    val gridState = rememberLazyGridState()
    var showMenu by remember { mutableStateOf(false) }
    var pendingRestoreIncludeProtected by remember { mutableStateOf<Boolean?>(null) }

    val mediaPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        if (uri != null) viewModel.resolvePickedGalleryUri(uri)
    }

    val galleryPermLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions()
    ) { _ ->
        val includeProtected = pendingRestoreIncludeProtected
        pendingRestoreIncludeProtected = null
        if (includeProtected != null) {
            if (viewModel.canWriteGallery()) {
                viewModel.executeRestoreConfirm(includeProtected)
            } else {
                viewModel.dismissRestoreConfirm()
                viewModel.reportRestorePermissionDenied()
            }
        }
    }

    fun triggerConfirmedRestore(includeAlreadyRestored: Boolean) {
        if (viewModel.canWriteGallery()) {
            viewModel.executeRestoreConfirm(includeAlreadyRestored)
        } else {
            pendingRestoreIncludeProtected = includeAlreadyRestored
            galleryPermLauncher.launch(MediaLibraryService.galleryReadWritePermissions())
        }
    }

    LaunchedEffect(Unit) {
        viewModel.onEnterScreen()
    }

    LaunchedEffect(uiState.shareFileReady) {
        val file = uiState.shareFileReady ?: return@LaunchedEffect
        shareFileViaChooser(context, file)
        viewModel.clearShareFileReady()
    }

    if (uiState.pickerErrorMessage != null) {
        AlertDialog(
            onDismissRequest = { viewModel.clearPickerError() },
            title = { Text("Cannot Resolve Original") },
            text = { Text(uiState.pickerErrorMessage.orEmpty()) },
            confirmButton = {
                TextButton(onClick = { viewModel.clearPickerError() }) { Text("OK") }
            }
        )
    }

    uiState.restoreConfirmRequest?.let { req ->
        BatchRestoreConfirmDialog(
            request = req,
            onDismiss = { viewModel.dismissRestoreConfirm() },
            onConfirm = { includeProtected -> triggerConfirmedRestore(includeProtected) }
        )
    }

    uiState.deleteConfirmTargets?.let { targets ->
        val totalBytes = targets.sumOf { maxOf(0L, it.size) }
        val sizeStr = Formatter.formatFileSize(context, totalBytes)
        AlertDialog(
            onDismissRequest = { viewModel.dismissDeleteConfirm() },
            title = { Text("Delete from Server?") },
            text = {
                Text(
                    "Permanently delete ${targets.size} backed-up original(s) (~$sizeStr) and their server proxies from your PhotoHub server? This cannot be undone."
                )
            },
            confirmButton = {
                Button(
                    onClick = { viewModel.executeDeleteSelected() },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error,
                        contentColor = MaterialTheme.colorScheme.onError
                    )
                ) {
                    Text("Delete ${targets.size}")
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.dismissDeleteConfirm() }) {
                    Text("Cancel")
                }
            }
        )
    }

    if (detailState != null) {
        ServerPhotoDetailDialog(
            detail = detailState!!,
            onDismiss = { viewModel.closePhotoDetail() },
            onCreateProxy = { viewModel.createProxyForDetail() },
            onShareOriginal = { viewModel.shareOriginalFromDetail() },
            onSaveProxy = { viewModel.saveProxyToGalleryFromDetail() },
            onRestoreOriginal = { viewModel.restoreFullMasterFromDetail() },
            onDeleteFromServer = { viewModel.deletePhotoFromDetail() },
            onToggleProtection = { viewModel.updateOriginalProtection(it) },
            onShareFileConsumed = { file ->
                shareFileViaChooser(context, file)
                viewModel.clearDetailShareFile()
            }
        )
    }

    // Build flat index offsets for scrolling to years & scrubber positions
    val anchorIndices = remember(uiState.timeline) {
        val map = mutableMapOf<String, Int>()
        val sectionIndices = mutableListOf<Int>()
        var idx = 0
        for (sec in uiState.timeline.sections) {
            if (sec.startsNewYear) {
                map["year-${sec.yearLabel}"] = idx
                idx++
            }
            map[sec.anchorId] = idx
            sectionIndices.add(idx)
            idx++ // section header
            idx += sec.photos.size
        }
        map to sectionIndices
    }

    Scaffold(
        topBar = {
            if (uiState.isSelectionMode) {
                val visible = uiState.visiblePhotos
                val allVisibleSelected = visible.isNotEmpty() &&
                    visible.all { it.hash.lowercase(Locale.ROOT) in uiState.selectedHashes }
                TopAppBar(
                    title = {
                        Text("${uiState.selectedHashes.size} Selected", fontWeight = FontWeight.SemiBold)
                    },
                    navigationIcon = {
                        TextButton(onClick = {
                            if (allVisibleSelected) viewModel.clearSelection() else viewModel.selectAllVisible()
                        }) {
                            Text(if (allVisibleSelected) "Clear" else "All")
                        }
                    },
                    actions = {
                        TextButton(onClick = { viewModel.exitSelectionMode() }) {
                            Text("Done", fontWeight = FontWeight.SemiBold)
                        }
                    }
                )
            } else {
                TopAppBar(
                    title = { Text("Cloud", fontWeight = FontWeight.Bold) },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.background
                    ),
                    navigationIcon = {
                        IconButton(
                            onClick = {
                                mediaPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                            },
                            enabled = !uiState.isResolvingPick
                        ) {
                            Icon(Icons.Rounded.IosShare, contentDescription = "Share Original from Gallery")
                        }
                    },
                    actions = {
                        TextButton(
                            onClick = { viewModel.enterSelectionMode() },
                            enabled = uiState.photos.isNotEmpty() && !uiState.isBatchRestoring && !uiState.isBatchProxying && !uiState.isBatchDeleting
                        ) {
                            Text("Select")
                        }

                        Box {
                            val isFiltered = uiState.filterMode != ServerGalleryFilter.ALL ||
                                uiState.mediaTypeFilter != ServerMediaTypeFilter.ALL
                            IconButton(onClick = { showMenu = true }) {
                                Icon(
                                    imageVector = if (isFiltered) Icons.Rounded.FilterAlt else Icons.Rounded.MoreVert,
                                    contentDescription = "Filters and Actions"
                                )
                            }
                            DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
                                if (uiState.photos.isNotEmpty()) {
                                    DropdownMenuItem(
                                        text = { Text("Select Photos to Restore or Delete") },
                                        leadingIcon = { Icon(Icons.Rounded.CheckBox, null) },
                                        enabled = !uiState.isBatchRestoring && !uiState.isBatchProxying && !uiState.isBatchDeleting,
                                        onClick = {
                                            showMenu = false
                                            viewModel.enterSelectionMode()
                                        }
                                    )
                                    HorizontalDivider()
                                }
                                Text(
                                    "Timeline View",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)
                                )
                                ServerTimelineGrouping.entries.forEach { mode ->
                                    DropdownMenuItem(
                                        text = { Text(mode.title) },
                                        leadingIcon = {
                                            if (uiState.timelineGrouping == mode) Icon(Icons.Rounded.Check, null)
                                        },
                                        onClick = {
                                            viewModel.setTimelineGrouping(mode)
                                            showMenu = false
                                        }
                                    )
                                }
                                HorizontalDivider()
                                Text(
                                    "Media Type",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)
                                )
                                ServerMediaTypeFilter.entries.forEach { media ->
                                    DropdownMenuItem(
                                        text = { Text(media.title) },
                                        leadingIcon = {
                                            if (uiState.mediaTypeFilter == media) Icon(Icons.Rounded.Check, null)
                                        },
                                        onClick = {
                                            viewModel.setMediaTypeFilter(media)
                                            showMenu = false
                                        }
                                    )
                                }
                                if (uiState.unproxiedCount > 0 || uiState.filterMode == ServerGalleryFilter.NEEDS_PROXY) {
                                    HorizontalDivider()
                                    DropdownMenuItem(
                                        text = { Text("All (${uiState.photos.size})") },
                                        leadingIcon = {
                                            if (uiState.filterMode == ServerGalleryFilter.ALL) Icon(Icons.Rounded.Check, null)
                                        },
                                        onClick = {
                                            viewModel.setFilterMode(ServerGalleryFilter.ALL)
                                            showMenu = false
                                        }
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Needs Proxy (${uiState.unproxiedCount})") },
                                        leadingIcon = {
                                            if (uiState.filterMode == ServerGalleryFilter.NEEDS_PROXY) Icon(Icons.Rounded.Check, null)
                                        },
                                        onClick = {
                                            viewModel.setFilterMode(ServerGalleryFilter.NEEDS_PROXY)
                                            showMenu = false
                                        }
                                    )
                                }
                            }
                        }

                        IconButton(
                            onClick = { viewModel.loadPhotos() },
                            enabled = !uiState.isLoading
                        ) {
                            if (uiState.isLoading) {
                                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                            } else {
                                Icon(Icons.Rounded.Refresh, contentDescription = "Refresh")
                            }
                        }
                    }
                )
            }
        },
        bottomBar = {
            if (uiState.isSelectionMode) {
                SelectionRestoreBottomBar(
                    uiState = uiState,
                    onRestoreSelected = { viewModel.requestRestoreSelected() },
                    onDeleteSelected = { viewModel.requestDeleteSelected() }
                )
            }
        }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            when {
                uiState.isLoading && uiState.photos.isEmpty() -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            SunnyMascot(mood = MascotMood.UPLOADING, size = 112.dp)
                            Text(
                                "Loading…",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold
                            )
                        }
                    }
                }
                uiState.errorMessage != null && uiState.photos.isEmpty() -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                            modifier = Modifier.padding(24.dp)
                        ) {
                            SunnyMascot(mood = MascotMood.ALERT, size = 116.dp)
                            Text("Offline", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.ExtraBold)
                            Text(
                                uiState.errorMessage.orEmpty(),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis
                            )
                            GradientPrimaryButton(text = "Retry", onClick = { viewModel.loadPhotos() })
                        }
                    }
                }
                uiState.photos.isEmpty() -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                            modifier = Modifier.padding(24.dp)
                        ) {
                            SunnyMascot(mood = MascotMood.SLEEPING, size = 120.dp)
                            Text("No Backups", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.ExtraBold)
                            GradientPrimaryButton(text = "Refresh", onClick = { viewModel.loadPhotos() })
                        }
                    }
                }
                else -> {
                    Column(modifier = Modifier.fillMaxSize()) {
                        if (uiState.timeline.years.size > 1) {
                            LazyRow(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                                    .padding(horizontal = 12.dp, vertical = 6.dp),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                items(uiState.timeline.years, key = { it.anchorId }) { yr ->
                                    val selected = uiState.selectedYearAnchor == yr.anchorId
                                    FilterChip(
                                        selected = selected,
                                        onClick = {
                                            viewModel.selectYearAnchor(yr.anchorId)
                                            val targetIdx = anchorIndices.first[yr.anchorId]
                                            if (targetIdx != null) {
                                                scope.launch { gridState.animateScrollToItem(targetIdx) }
                                            }
                                        },
                                        label = { Text(yr.label, style = MaterialTheme.typography.labelMedium) }
                                    )
                                }
                            }
                        }

                        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                            LazyVerticalGrid(
                                columns = GridCells.Adaptive(minSize = 110.dp),
                                state = gridState,
                                horizontalArrangement = Arrangement.spacedBy(2.dp),
                                verticalArrangement = Arrangement.spacedBy(2.dp),
                                modifier = Modifier.fillMaxSize()
                            ) {
                                uiState.errorMessage?.let { err ->
                                    item(span = { GridItemSpan(maxLineSpan) }) {
                                        Row(
                                            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Icon(Icons.Rounded.WifiOff, null, tint = PhotoHubOrange, modifier = Modifier.size(16.dp))
                                            Spacer(modifier = Modifier.width(6.dp))
                                            Text("Offline cache · $err", style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        }
                                    }
                                }

                                if (uiState.unproxiedCount > 0 || uiState.isBatchProxying || uiState.batchBannerMessage != null) {
                                    item(span = { GridItemSpan(maxLineSpan) }) {
                                        UnproxiedBanner(uiState = uiState, viewModel = viewModel)
                                    }
                                }

                                if (uiState.isBatchRestoring || uiState.restoreBannerMessage != null) {
                                    item(span = { GridItemSpan(maxLineSpan) }) {
                                        RestoreOriginalsBanner(uiState = uiState, viewModel = viewModel)
                                    }
                                }

                                if (uiState.isBatchDeleting || uiState.deleteBannerMessage != null) {
                                    item(span = { GridItemSpan(maxLineSpan) }) {
                                        DeletePhotosBanner(uiState = uiState, viewModel = viewModel)
                                    }
                                }

                                if (syncState.isSyncing) {
                                    item(span = { GridItemSpan(maxLineSpan) }) {
                                        Row(
                                            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                            Spacer(modifier = Modifier.width(8.dp))
                                            Text(
                                                text = syncState.statusText.ifBlank {
                                                    "Syncing proxies (${syncState.completedCount}/${syncState.totalCount})…"
                                                },
                                                style = MaterialTheme.typography.bodySmall,
                                                modifier = Modifier.weight(1f),
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                            TextButton(onClick = { syncManager.cancel() }) {
                                                Text("Stop", style = MaterialTheme.typography.labelSmall)
                                            }
                                        }
                                    }
                                }

                                if (uiState.timeline.sections.isEmpty()) {
                                    item(span = { GridItemSpan(maxLineSpan) }) {
                                        Column(
                                            modifier = Modifier.fillMaxWidth().padding(vertical = 44.dp),
                                            horizontalAlignment = Alignment.CenterHorizontally
                                        ) {
                                            Text("No items match the current filter.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                                            if (uiState.filterMode != ServerGalleryFilter.ALL || uiState.mediaTypeFilter != ServerMediaTypeFilter.ALL) {
                                                TextButton(onClick = {
                                                    viewModel.setFilterMode(ServerGalleryFilter.ALL)
                                                    viewModel.setMediaTypeFilter(ServerMediaTypeFilter.ALL)
                                                }) {
                                                    Text("Show All")
                                                }
                                            }
                                        }
                                    }
                                } else {
                                    for (sec in uiState.timeline.sections) {
                                        if (sec.startsNewYear && uiState.timelineGrouping != ServerTimelineGrouping.YEAR) {
                                            item(key = "yr-${sec.anchorId}", span = { GridItemSpan(maxLineSpan) }) {
                                                val yrInfo = uiState.timeline.years.firstOrNull { it.label == sec.yearLabel }
                                                Row(
                                                    modifier = Modifier
                                                        .fillMaxWidth()
                                                        .padding(start = 12.dp, end = 12.dp, top = 14.dp, bottom = 2.dp),
                                                    verticalAlignment = Alignment.CenterVertically
                                                ) {
                                                    Text(sec.yearLabel, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                                                    if (yrInfo != null) {
                                                        Text("${yrInfo.itemCount}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                                    }
                                                }
                                            }
                                        }

                                        item(key = "hdr-${sec.id}", span = { GridItemSpan(maxLineSpan) }) {
                                            Row(
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.94f))
                                                    .padding(horizontal = 12.dp, vertical = 6.dp),
                                                verticalAlignment = Alignment.CenterVertically
                                            ) {
                                                Text(sec.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                                                if (uiState.isSelectionMode) {
                                                    val secAllSelected = sec.photos.isNotEmpty() &&
                                                        sec.photos.all { it.hash.lowercase(Locale.ROOT) in uiState.selectedHashes }
                                                    TextButton(
                                                        onClick = { viewModel.toggleSectionSelection(sec.photos) },
                                                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                                                        modifier = Modifier.height(28.dp)
                                                    ) {
                                                        Text(
                                                            if (secAllSelected) "Clear" else "Select",
                                                            style = MaterialTheme.typography.labelSmall,
                                                            fontWeight = FontWeight.SemiBold
                                                        )
                                                    }
                                                } else {
                                                    Text("${sec.photos.size}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                                }
                                            }
                                        }

                                        items(sec.photos, key = { "${sec.id}-${it.hash}" }) { photo ->
                                            LaunchedEffect(photo.hash, photo.needsProxy) {
                                                viewModel.loadCompressedPreviewIfNeeded(photo)
                                            }
                                            val normHash = photo.hash.lowercase(Locale.ROOT)
                                            val isSelected = normHash in uiState.selectedHashes
                                            val restoredOrProtected = uiState.isRestoredOrProtected(photo)
                                            ServerThumbnailCell(
                                                photo = photo,
                                                bitmap = uiState.imageCache[photo.hash],
                                                showPlaceholder = (photo.hash in uiState.failedPreviewHashes) || (photo.isVideo && photo.needsProxy),
                                                isSelectionMode = uiState.isSelectionMode,
                                                isSelected = isSelected,
                                                isRestoredOrProtected = restoredOrProtected,
                                                onClick = {
                                                    if (uiState.isSelectionMode) {
                                                        viewModel.togglePhotoSelection(photo.hash)
                                                    } else {
                                                        viewModel.openPhotoDetail(photo)
                                                    }
                                                },
                                                onLongClick = {
                                                    if (!uiState.isSelectionMode && !uiState.isBatchRestoring && !uiState.isBatchProxying && !uiState.isBatchDeleting) {
                                                        viewModel.enterSelectionMode(photo.hash)
                                                    }
                                                }
                                            )
                                        }
                                    }
                                }
                            }

                            if (uiState.timeline.sections.size >= 6) {
                                TimelineScrubber(
                                    sections = uiState.timeline.sections,
                                    onScrubSection = { secIdx ->
                                        val sec = uiState.timeline.sections.getOrNull(secIdx) ?: return@TimelineScrubber
                                        viewModel.selectYearAnchor("year-${sec.yearLabel}")
                                        val gridPos = anchorIndices.first[sec.anchorId]
                                        if (gridPos != null) {
                                            scope.launch { gridState.scrollToItem(gridPos) }
                                        }
                                    },
                                    modifier = Modifier.align(Alignment.CenterEnd)
                                )
                            }
                        }
                    }
                }
            }

            if (uiState.isResolvingPick) {
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
                            Text(uiState.pickStatusText, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun UnproxiedBanner(
    uiState: ServerGalleryUiState,
    viewModel: ServerGalleryViewModel
) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            when {
                uiState.isBatchProxying -> {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        "Creating proxies ${uiState.batchCompleted}/${uiState.batchTotal}",
                        style = MaterialTheme.typography.bodySmall,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.weight(1f)
                    )
                    TextButton(onClick = { viewModel.stopBatchProxy() }) {
                        Text("Stop", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                    }
                }
                uiState.unproxiedCount > 0 -> {
                    Row(
                        modifier = Modifier
                            .weight(1f)
                            .clickable {
                                val next = if (uiState.filterMode == ServerGalleryFilter.NEEDS_PROXY) {
                                    ServerGalleryFilter.ALL
                                } else {
                                    ServerGalleryFilter.NEEDS_PROXY
                                }
                                viewModel.setFilterMode(next)
                            },
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(modifier = Modifier.size(7.dp).clip(CircleShape).background(PhotoHubOrange))
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(
                            text = if (uiState.filterMode == ServerGalleryFilter.NEEDS_PROXY) {
                                "Showing ${uiState.unproxiedCount} unproxied · Tap for All"
                            } else {
                                "${uiState.unproxiedCount} missing proxy"
                            },
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.Medium
                        )
                    }
                    TextButton(
                        onClick = { viewModel.startBatchProxy() },
                        enabled = !uiState.isBatchRestoring && !uiState.isBatchDeleting
                    ) {
                        Text("Proxy All", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                    }
                }
                uiState.batchBannerMessage != null -> {
                    Icon(Icons.Rounded.CheckCircle, null, tint = PhotoHubGreen, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        uiState.batchBannerMessage.orEmpty(),
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                    IconButton(onClick = { viewModel.dismissBatchBanner() }, modifier = Modifier.size(24.dp)) {
                        Icon(Icons.Rounded.Close, null, modifier = Modifier.size(14.dp))
                    }
                }
            }
        }
    }
}

@Composable
fun BatchRestoreConfirmDialog(
    request: com.photohub.compressor.viewmodel.BatchRestoreConfirmRequest,
    onDismiss: () -> Unit,
    onDeleteLeftoverProxies: (() -> Unit)? = null,
    onConfirm: (includeAlreadyRestored: Boolean) -> Unit
) {
    val context = LocalContext.current
    val freeText = request.deviceAvailableBytes?.let { Formatter.formatFileSize(context, it.coerceAtLeast(0L)) } ?: "Unknown"
    val blockedLowStorage = (!request.unrestoredTargets.isEmpty() && !request.hasEnoughStorageForUnrestored) ||
        (request.unrestoredTargets.isEmpty() && !(request.isRestoreAll && request.leftoverProxyCount > 0) && !request.hasEnoughStorageForAll)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                text = if (blockedLowStorage) "Low Phone Storage" else request.title,
                fontWeight = FontWeight.Bold
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (request.unrestoredTargets.isEmpty()) {
                    if (request.isRestoreAll && request.leftoverProxyCount > 0 && onDeleteLeftoverProxies != null) {
                        Text(
                            "All ${request.allTargets.size} restored · ${request.leftoverProxyCount} compressed copy(s) left in Gallery."
                        )
                        if (request.hasEnoughStorageForAll) {
                            TextButton(
                                onClick = { onConfirm(true) },
                                contentPadding = PaddingValues(horizontal = 4.dp, vertical = 2.dp)
                            ) {
                                Text("Re-download All (${request.allTargets.size})")
                            }
                        }
                    } else if (!request.hasEnoughStorageForAll && request.deviceAvailableBytes != null) {
                        val allSizeStr = Formatter.formatFileSize(context, request.allBytes)
                        val needExtra = Formatter.formatFileSize(
                            context,
                            ((request.allBytes + com.photohub.compressor.viewmodel.DeviceStorageHelper.MINIMUM_HEADROOM_BYTES) - request.deviceAvailableBytes).coerceAtLeast(0L)
                        )
                        Text("Need ~$allSizeStr · Phone free: $freeText\nFree up ~$needExtra before re-downloading.")
                    } else {
                        Text("All ${request.allTargets.size} already restored · Phone free: $freeText.")
                    }
                } else {
                    val sizeStr = Formatter.formatFileSize(context, request.unrestoredBytes)
                    if (!request.hasEnoughStorageForUnrestored && request.deviceAvailableBytes != null) {
                        val needExtra = Formatter.formatFileSize(
                            context,
                            ((request.unrestoredBytes + com.photohub.compressor.viewmodel.DeviceStorageHelper.MINIMUM_HEADROOM_BYTES) - request.deviceAvailableBytes).coerceAtLeast(0L)
                        )
                        Text("Need ~$sizeStr for ${request.unrestoredTargets.size} item(s) · Phone free: $freeText\nFree up ~$needExtra on your phone first.")
                    } else {
                        val proxyNote = when {
                            !request.isRestoreAll -> ""
                            request.willDisableAutoBackup -> " · Removes proxies & turns off Auto Backup."
                            else -> " · Removes compressed copies."
                        }
                        Text("Restore ${request.unrestoredTargets.size} (~$sizeStr) · Phone free: $freeText$proxyNote")
                        if (request.skippedCount > 0) {
                            Text(
                                "Skipping ${request.skippedCount} already restored.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            if (request.hasEnoughStorageForAll) {
                                TextButton(
                                    onClick = { onConfirm(true) },
                                    contentPadding = PaddingValues(horizontal = 4.dp, vertical = 2.dp)
                                ) {
                                    Text("Include all (${request.allTargets.size})")
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            if (request.unrestoredTargets.isEmpty()) {
                if (request.isRestoreAll && request.leftoverProxyCount > 0 && onDeleteLeftoverProxies != null) {
                    Button(
                        onClick = onDeleteLeftoverProxies,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.error,
                            contentColor = MaterialTheme.colorScheme.onError
                        )
                    ) {
                        Text("Delete ${request.leftoverProxyCount} Proxies")
                    }
                } else if (request.hasEnoughStorageForAll) {
                    Button(onClick = { onConfirm(true) }) {
                        Text("Re-download (${request.allTargets.size})")
                    }
                }
            } else if (request.hasEnoughStorageForUnrestored) {
                Button(onClick = { onConfirm(false) }) {
                    Text("Restore ${request.unrestoredTargets.size}")
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(if (blockedLowStorage) "OK" else "Cancel")
            }
        }
    )
}

@Composable
private fun RestoreOriginalsBanner(
    uiState: ServerGalleryUiState,
    viewModel: ServerGalleryViewModel
) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.45f),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (uiState.isBatchRestoring) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    "Restoring originals ${uiState.restoreCompleted}/${uiState.restoreTotal}",
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.weight(1f)
                )
                TextButton(onClick = { viewModel.stopBatchRestore() }) {
                    Text("Stop", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                }
            } else if (uiState.restoreBannerMessage != null) {
                Icon(Icons.Rounded.CheckCircle, null, tint = PhotoHubGreen, modifier = Modifier.size(16.dp))
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    uiState.restoreBannerMessage.orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                IconButton(onClick = { viewModel.dismissRestoreBanner() }, modifier = Modifier.size(24.dp)) {
                    Icon(Icons.Rounded.Close, null, modifier = Modifier.size(14.dp))
                }
            }
        }
    }
}

@Composable
private fun DeletePhotosBanner(
    uiState: ServerGalleryUiState,
    viewModel: ServerGalleryViewModel
) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.55f),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (uiState.isBatchDeleting) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.error
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    "Deleting selected photos from server…",
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.weight(1f)
                )
            } else if (uiState.deleteBannerMessage != null) {
                Icon(
                    Icons.Rounded.DeleteOutline,
                    null,
                    tint = MaterialTheme.colorScheme.error,
                    modifier = Modifier.size(16.dp)
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    uiState.deleteBannerMessage.orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                IconButton(onClick = { viewModel.dismissDeleteBanner() }, modifier = Modifier.size(24.dp)) {
                    Icon(Icons.Rounded.Close, null, modifier = Modifier.size(14.dp))
                }
            }
        }
    }
}

@Composable
private fun SelectionRestoreBottomBar(
    uiState: ServerGalleryUiState,
    onRestoreSelected: () -> Unit,
    onDeleteSelected: () -> Unit
) {
    val context = LocalContext.current
    val selectedList = uiState.photos.filter { it.hash.lowercase(Locale.ROOT) in uiState.selectedHashes }
    val unrestored = selectedList.filter { !uiState.isRestoredOrProtected(it) }
    val targetBytes = (if (unrestored.isNotEmpty()) unrestored else selectedList).sumOf { maxOf(0L, it.size) }
    val sizeStr = Formatter.formatFileSize(context, targetBytes)
    val actionsEnabled = selectedList.isNotEmpty() && !uiState.isBatchRestoring && !uiState.isBatchProxying && !uiState.isBatchDeleting

    Surface(tonalElevation = 6.dp, shadowElevation = 8.dp) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = if (selectedList.isEmpty()) "Tap photos to select" else "${selectedList.size} selected (~$sizeStr)",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )
                if (selectedList.isNotEmpty()) {
                    val alreadyCount = selectedList.size - unrestored.size
                    Text(
                        text = if (alreadyCount > 0) {
                            "${unrestored.size} to restore · $alreadyCount already restored"
                        } else {
                            "${unrestored.size} original(s) to download"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            Spacer(modifier = Modifier.width(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(
                    onClick = onDeleteSelected,
                    enabled = actionsEnabled,
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = MaterialTheme.colorScheme.error
                    ),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)
                ) {
                    Icon(Icons.Rounded.DeleteOutline, contentDescription = "Delete from Server", modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("Delete")
                }
                Button(
                    onClick = onRestoreSelected,
                    enabled = actionsEnabled,
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
                ) {
                    Icon(Icons.Rounded.CloudDownload, null, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("Restore")
                }
            }
        }
    }
}

@Composable
private fun ServerThumbnailCell(
    photo: ServerPhoto,
    bitmap: android.graphics.Bitmap?,
    showPlaceholder: Boolean,
    isSelectionMode: Boolean,
    isSelected: Boolean,
    isRestoredOrProtected: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit
) {
    Box(
        modifier = Modifier
            .aspectRatio(1f)
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .then(
                if (isSelected) Modifier.border(2.5.dp, MaterialTheme.colorScheme.primary)
                else Modifier
            )
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick
            ),
        contentAlignment = Alignment.Center
    ) {
        if (bitmap != null) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = photo.originalName,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        } else if (showPlaceholder) {
            Icon(
                imageVector = if (photo.isVideo) Icons.Rounded.Videocam else Icons.Rounded.Photo,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
        }

        if (isSelected) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.22f))
            )
        }

        if (photo.isVideo && bitmap != null) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(5.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.48f))
                    .padding(5.dp)
            ) {
                Icon(Icons.Rounded.PlayArrow, null, tint = Color.White, modifier = Modifier.size(14.dp))
            }
        }

        if (isSelectionMode) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(6.dp)
                    .size(22.dp)
                    .clip(CircleShape)
                    .background(
                        if (isSelected) MaterialTheme.colorScheme.primary
                        else Color.Black.copy(alpha = 0.38f)
                    )
                    .border(
                        width = 1.5.dp,
                        color = Color.White,
                        shape = CircleShape
                    ),
                contentAlignment = Alignment.Center
            ) {
                if (isSelected) {
                    Icon(
                        Icons.Rounded.Check,
                        contentDescription = "Selected",
                        tint = Color.White,
                        modifier = Modifier.size(14.dp)
                    )
                }
            }
        }

        if (isRestoredOrProtected) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(5.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.45f))
                    .padding(3.dp)
            ) {
                Icon(
                    Icons.Rounded.VerifiedUser,
                    contentDescription = "Restored Original",
                    tint = PhotoHubGreen,
                    modifier = Modifier.size(12.dp)
                )
            }
        }

        if (photo.needsProxy) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(6.dp)
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(PhotoHubOrange)
                    .border(1.dp, Color.White.copy(alpha = 0.85f), CircleShape)
            )
        }
    }
}

@Composable
private fun TimelineScrubber(
    sections: List<ServerTimelineSection>,
    onScrubSection: (Int) -> Unit,
    modifier: Modifier = Modifier
) {
    var heightPx by remember { mutableIntStateOf(1) }
    var fraction by remember { mutableFloatStateOf(0f) }
    var isScrubbing by remember { mutableStateOf(false) }
    var activeSecIndex by remember { mutableIntStateOf(-1) }

    Box(
        modifier = modifier
            .fillMaxHeight()
            .width(32.dp)
            .padding(vertical = 40.dp, horizontal = 2.dp)
            .onSizeChanged { heightPx = it.height.coerceAtLeast(1) }
            .pointerInput(sections.size) {
                detectVerticalDragGestures(
                    onDragStart = { offset ->
                        isScrubbing = true
                        fraction = (offset.y / heightPx.toFloat()).coerceIn(0f, 1f)
                        val idx = (fraction * (sections.size - 1)).roundToInt().coerceIn(0, sections.size - 1)
                        if (idx != activeSecIndex) {
                            activeSecIndex = idx
                            onScrubSection(idx)
                        }
                    },
                    onVerticalDrag = { change, _ ->
                        change.consume()
                        fraction = (change.position.y / heightPx.toFloat()).coerceIn(0f, 1f)
                        val idx = (fraction * (sections.size - 1)).roundToInt().coerceIn(0, sections.size - 1)
                        if (idx != activeSecIndex) {
                            activeSecIndex = idx
                            onScrubSection(idx)
                        }
                    },
                    onDragEnd = { isScrubbing = false },
                    onDragCancel = { isScrubbing = false }
                )
            }
    ) {
        val handleHeightPx = 100
        val handleOffsetY = ((heightPx - handleHeightPx).coerceAtLeast(1) * fraction).roundToInt()

        Box(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .offset { IntOffset(0, handleOffsetY) }
                .padding(end = 3.dp)
                .width(if (isScrubbing) 6.dp else 4.dp)
                .height(36.dp)
                .clip(CircleShape)
                .background(
                    if (isScrubbing) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.28f)
                )
        )

        if (isScrubbing && activeSecIndex in sections.indices) {
            val sec = sections[activeSecIndex]
            Surface(
                shape = CircleShape,
                color = Color.Black.copy(alpha = 0.85f),
                shadowElevation = 4.dp,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .offset { IntOffset(-130, handleOffsetY) }
            ) {
                Text(
                    text = sec.scrubLabel,
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
                )
            }
        }
    }
}

fun shareFileViaChooser(context: android.content.Context, file: File) {
    val chooser = ShareUtils.buildShareChooserIntent(
        context = context,
        files = listOf(file),
        title = "Share Original",
        excludeComponents = arrayOf(ComponentName(context, ShareOriginalActivity::class.java))
    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(chooser)
}
