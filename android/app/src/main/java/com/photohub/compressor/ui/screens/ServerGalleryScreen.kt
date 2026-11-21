package com.photohub.compressor.ui.screens

import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import android.content.ComponentName
import com.photohub.compressor.ShareOriginalActivity
import com.photohub.compressor.data.ServerPhoto
import com.photohub.compressor.media.ShareUtils
import com.photohub.compressor.sync.LocalProxySyncManager
import com.photohub.compressor.ui.theme.PhotoHubGreen
import com.photohub.compressor.ui.theme.PhotoHubOrange
import com.photohub.compressor.viewmodel.*
import kotlinx.coroutines.launch
import java.io.File
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

    val mediaPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        if (uri != null) viewModel.resolvePickedGalleryUri(uri)
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

    if (detailState != null) {
        ServerPhotoDetailDialog(
            detail = detailState!!,
            onDismiss = { viewModel.closePhotoDetail() },
            onCreateProxy = { viewModel.createProxyForDetail() },
            onShareOriginal = { viewModel.shareOriginalFromDetail() },
            onSaveProxy = { viewModel.saveProxyToGalleryFromDetail() },
            onRestoreOriginal = { viewModel.restoreFullMasterFromDetail() },
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
            TopAppBar(
                title = { Text("Server", fontWeight = FontWeight.SemiBold) },
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
                    Box {
                        val isFiltered = uiState.filterMode != ServerGalleryFilter.ALL ||
                            uiState.mediaTypeFilter != ServerMediaTypeFilter.ALL
                        IconButton(onClick = { showMenu = true }) {
                            Icon(
                                imageVector = if (isFiltered) Icons.Rounded.FilterAlt else Icons.Rounded.MoreVert,
                                contentDescription = "Filters"
                            )
                        }
                        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
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
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            when {
                uiState.isLoading && uiState.photos.isEmpty() -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            CircularProgressIndicator()
                            Spacer(modifier = Modifier.height(10.dp))
                            Text("Loading photos…")
                        }
                    }
                }
                uiState.errorMessage != null && uiState.photos.isEmpty() -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier.padding(24.dp)
                        ) {
                            Icon(Icons.Rounded.WifiOff, null, modifier = Modifier.size(56.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            Spacer(modifier = Modifier.height(10.dp))
                            Text("Could Not Connect", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                            Text(uiState.errorMessage.orEmpty(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Spacer(modifier = Modifier.height(12.dp))
                            Button(onClick = { viewModel.loadPhotos() }) { Text("Retry") }
                        }
                    }
                }
                uiState.photos.isEmpty() -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier.padding(24.dp)
                        ) {
                            Icon(Icons.Rounded.Cloud, null, modifier = Modifier.size(56.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            Spacer(modifier = Modifier.height(10.dp))
                            Text("No Backups Yet", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                            Text("Upload photos or store them on your PhotoHub server to browse them here.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Spacer(modifier = Modifier.height(12.dp))
                            Button(onClick = { viewModel.loadPhotos() }) { Text("Refresh") }
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
                                                Text("${sec.photos.size}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                            }
                                        }

                                        items(sec.photos, key = { "${sec.id}-${it.hash}" }) { photo ->
                                            LaunchedEffect(photo.hash, photo.needsProxy) {
                                                viewModel.loadCompressedPreviewIfNeeded(photo)
                                            }
                                            ServerThumbnailCell(
                                                photo = photo,
                                                bitmap = uiState.imageCache[photo.hash],
                                                showPlaceholder = (photo.hash in uiState.failedPreviewHashes) || (photo.isVideo && photo.needsProxy),
                                                onClick = { viewModel.openPhotoDetail(photo) }
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
                    TextButton(onClick = { viewModel.startBatchProxy() }) {
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
private fun ServerThumbnailCell(
    photo: ServerPhoto,
    bitmap: android.graphics.Bitmap?,
    showPlaceholder: Boolean,
    onClick: () -> Unit
) {
    Box(
        modifier = Modifier
            .aspectRatio(1f)
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .clickable(onClick = onClick),
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
