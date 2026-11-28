package com.photohub.compressor.ui.screens

import android.content.ComponentName
import android.content.Intent
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.photohub.compressor.ShareOriginalActivity
import com.photohub.compressor.data.ServerPhoto
import com.photohub.compressor.media.MediaLibraryService
import com.photohub.compressor.media.ShareUtils
import com.photohub.compressor.sync.LocalProxySyncManager
import com.photohub.compressor.ui.components.CloudLoadingSkeleton
import com.photohub.compressor.ui.components.GradientPrimaryButton
import com.photohub.compressor.ui.components.MascotMood
import com.photohub.compressor.ui.components.PulsingStatusDot
import com.photohub.compressor.ui.components.SoftOrangeButton
import com.photohub.compressor.ui.components.SunnyMascot
import com.photohub.compressor.ui.components.WarmShimmerBox
import com.photohub.compressor.ui.theme.PhotoHubAmber
import com.photohub.compressor.ui.theme.PhotoHubDeepOrange
import com.photohub.compressor.ui.theme.PhotoHubGreen
import com.photohub.compressor.ui.theme.PhotoHubMint
import com.photohub.compressor.ui.theme.PhotoHubOrange
import com.photohub.compressor.ui.theme.PhotoHubRed
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
        val permanent = uiState.deleteConfirmIsPermanent
        AlertDialog(
            onDismissRequest = { viewModel.dismissDeleteConfirm() },
            title = { Text(if (permanent) "Delete Permanently?" else "Move to Trash?") },
            text = {
                Text(
                    if (permanent) {
                        "Permanently delete ${targets.size} item(s) (~$sizeStr) from your server? This cannot be undone."
                    } else {
                        "Move ${targets.size} item(s) (~$sizeStr) to Trash? You can restore them anytime within 30 days."
                    }
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
                    Text(if (permanent) "Delete Forever (${targets.size})" else "Move to Trash (${targets.size})")
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
        val visibleList = uiState.visiblePhotos
        val activeHash = detailState!!.photo.hash
        val initIdx = visibleList.indexOfFirst { it.hash.equals(activeHash, ignoreCase = true) }.coerceAtLeast(0)
        ServerPhotoDetailDialog(
            detail = detailState!!,
            allPhotos = if (visibleList.isNotEmpty()) visibleList else listOf(detailState!!.photo),
            initialIndex = initIdx,
            getCachedThumbnail = { hash -> viewModel.getCachedThumbnail(hash) },
            onPageChanged = { photo -> viewModel.openPhotoDetail(photo) },
            onDismiss = { viewModel.closePhotoDetail() },
            onCreateProxy = { viewModel.createProxyForDetail() },
            onShareOriginal = { viewModel.shareOriginalFromDetail() },
            onSaveProxy = { viewModel.saveProxyToGalleryFromDetail() },
            onRestoreOriginal = { viewModel.restoreFullMasterFromDetail() },
            onDeleteFromServer = { viewModel.deletePhotoFromDetail() },
            onRestoreFromTrash = { viewModel.restorePhotoFromTrashDetail() },
            onToggleFavorite = { viewModel.toggleFavoriteFromDetail() },
            onCreateShareLink = { title, hours, pass -> viewModel.createShareLinkFromDetail(title, hours, pass) },
            onClearShareLink = { viewModel.clearCreatedShareLink() },
            onToggleProtection = { viewModel.updateOriginalProtection(it) },
            onShareFileConsumed = { file ->
                shareFileViaChooser(context, file)
                viewModel.clearDetailShareFile()
            }
        )
    }

    val hasUnproxiedBanner = uiState.unproxiedCount > 0 || uiState.isBatchProxying || uiState.batchBannerMessage != null
    val hasRestoreBanner = uiState.isBatchRestoring || uiState.isBatchUpdatingProtection || uiState.restoreBannerMessage != null
    val hasDeleteBanner = uiState.isBatchDeleting || uiState.deleteBannerMessage != null

    // Build flat index offsets for scrolling to years & scrubber positions (accounts for Hero + Control Bar + active banners)
    val anchorIndices = remember(
        uiState.timeline,
        uiState.timelineGrouping,
        uiState.errorMessage,
        hasUnproxiedBanner,
        hasRestoreBanner,
        hasDeleteBanner,
        uiState.isViewingTrash,
        syncState.isSyncing
    ) {
        val map = mutableMapOf<String, Int>()
        val sectionIndices = mutableListOf<Int>()
        var idx = 2 // CloudHeroStorageCard + CloudControlBar
        if (uiState.errorMessage != null) idx++
        if (hasUnproxiedBanner) idx++
        if (hasRestoreBanner) idx++
        if (hasDeleteBanner) idx++
        if (uiState.isViewingTrash) idx++
        if (syncState.isSyncing) idx++
        for (sec in uiState.timeline.sections) {
            if (sec.startsNewYear && uiState.timelineGrouping != ServerTimelineGrouping.YEAR) {
                map["year-${sec.yearLabel}"] = idx
                idx++
            } else if (uiState.timelineGrouping == ServerTimelineGrouping.YEAR) {
                map["year-${sec.yearLabel}"] = idx
            }
            map[sec.anchorId] = idx
            sectionIndices.add(idx)
            idx++ // section header
            idx += sec.photos.size
        }
        map to sectionIndices
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            if (uiState.isSelectionMode) {
                val visible = uiState.visiblePhotos
                val allVisibleSelected = visible.isNotEmpty() &&
                    visible.all { it.hash.lowercase(Locale.ROOT) in uiState.selectedHashes }
                TopAppBar(
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.background
                    ),
                    title = {
                        Text("${uiState.selectedHashes.size} Selected", fontWeight = FontWeight.ExtraBold)
                    },
                    navigationIcon = {
                        TextButton(onClick = {
                            if (allVisibleSelected) viewModel.clearSelection() else viewModel.selectAllVisible()
                        }) {
                            Text(if (allVisibleSelected) "Clear" else "Select All", fontWeight = FontWeight.Bold)
                        }
                    },
                    actions = {
                        TextButton(onClick = { viewModel.exitSelectionMode() }) {
                            Text("Done", fontWeight = FontWeight.Bold)
                        }
                    }
                )
            } else {
                TopAppBar(
                    title = { Text("Cloud", fontWeight = FontWeight.ExtraBold) },
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
                            enabled = uiState.photos.isNotEmpty() && !uiState.isBatchRestoring && !uiState.isBatchProxying && !uiState.isBatchDeleting && !uiState.isBatchUpdatingProtection
                        ) {
                            Text("Select", fontWeight = FontWeight.Bold)
                        }

                        Box {
                            IconButton(onClick = { showMenu = true }) {
                                Icon(
                                    imageVector = if (uiState.hasActiveFilter) Icons.Rounded.FilterAlt else Icons.Rounded.MoreVert,
                                    contentDescription = "Filters and Actions",
                                    tint = if (uiState.hasActiveFilter) PhotoHubOrange else LocalContentColor.current
                                )
                            }
                            DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
                                if (uiState.photos.isNotEmpty()) {
                                    DropdownMenuItem(
                                        text = { Text("Select Photos to Restore or Delete") },
                                        leadingIcon = { Icon(Icons.Rounded.CheckBox, null) },
                                        enabled = !uiState.isBatchRestoring && !uiState.isBatchProxying && !uiState.isBatchDeleting && !uiState.isBatchUpdatingProtection,
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
                                    "Media Filter",
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
                                CircularProgressIndicator(
                                    modifier = Modifier.size(19.dp),
                                    strokeWidth = 2.dp,
                                    color = PhotoHubOrange
                                )
                            } else {
                                Icon(Icons.Rounded.Refresh, contentDescription = "Refresh")
                            }
                        }
                    }
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
                    CloudLoadingSkeleton()
                }
                uiState.errorMessage != null && uiState.photos.isEmpty() -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Surface(
                            shape = RoundedCornerShape(24.dp),
                            color = MaterialTheme.colorScheme.surface,
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 24.dp)
                        ) {
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(12.dp),
                                modifier = Modifier.padding(24.dp)
                            ) {
                                SunnyMascot(mood = MascotMood.ALERT, size = 114.dp)
                                Text(
                                    "Could Not Reach Cloud",
                                    style = MaterialTheme.typography.titleLarge,
                                    fontWeight = FontWeight.ExtraBold
                                )
                                Text(
                                    uiState.errorMessage.orEmpty(),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    textAlign = TextAlign.Center,
                                    maxLines = 3,
                                    overflow = TextOverflow.Ellipsis
                                )
                                GradientPrimaryButton(
                                    text = "Retry Connection",
                                    icon = Icons.Rounded.Refresh,
                                    onClick = { viewModel.loadPhotos() }
                                )
                            }
                        }
                    }
                }
                uiState.photos.isEmpty() -> {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Surface(
                            shape = RoundedCornerShape(24.dp),
                            color = MaterialTheme.colorScheme.surface,
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 24.dp)
                        ) {
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(12.dp),
                                modifier = Modifier.padding(24.dp)
                            ) {
                                SunnyMascot(mood = MascotMood.SLEEPING, size = 118.dp)
                                Text(
                                    "No Cloud Backups Yet",
                                    style = MaterialTheme.typography.titleLarge,
                                    fontWeight = FontWeight.ExtraBold
                                )
                                Text(
                                    "Head to the Backup tab to upload your first full-resolution photos & videos.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    textAlign = TextAlign.Center
                                )
                                GradientPrimaryButton(
                                    text = "Refresh Cloud",
                                    icon = Icons.Rounded.Refresh,
                                    onClick = { viewModel.loadPhotos() }
                                )
                            }
                        }
                    }
                }
                else -> {
                    Box(modifier = Modifier.fillMaxSize()) {
                        LazyVerticalGrid(
                            columns = GridCells.Adaptive(minSize = 104.dp),
                            state = gridState,
                            contentPadding = PaddingValues(
                                start = 12.dp,
                                end = 12.dp,
                                top = 8.dp,
                                bottom = if (uiState.isSelectionMode) 96.dp else 20.dp
                            ),
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                            modifier = Modifier.fillMaxSize()
                        ) {
                            // Web-matched Warm Sunset Hero & Storage Summary Card
                            item(key = "cloud-hero", span = { GridItemSpan(maxLineSpan) }) {
                                CloudHeroStorageCard(uiState = uiState, isSyncing = syncState.isSyncing)
                            }

                            // Web-matched Search, Filter Pills, Grouping & Year Quick-Jump Toolbar
                            item(key = "cloud-controls", span = { GridItemSpan(maxLineSpan) }) {
                                CloudControlBar(
                                    uiState = uiState,
                                    viewModel = viewModel,
                                    onSelectYear = { anchorId ->
                                        viewModel.selectYearAnchor(anchorId)
                                        val targetIdx = anchorIndices.first[anchorId]
                                        if (targetIdx != null) {
                                            scope.launch { gridState.animateScrollToItem(targetIdx) }
                                        }
                                    }
                                )
                            }

                            uiState.errorMessage?.let { err ->
                                item(key = "cloud-offline-banner", span = { GridItemSpan(maxLineSpan) }) {
                                    Surface(
                                        shape = RoundedCornerShape(14.dp),
                                        color = MaterialTheme.colorScheme.primaryContainer,
                                        border = BorderStroke(1.dp, PhotoHubOrange.copy(alpha = 0.32f)),
                                        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)
                                    ) {
                                        Row(
                                            modifier = Modifier.padding(horizontal = 14.dp, vertical = 9.dp),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Icon(Icons.Rounded.WifiOff, null, tint = PhotoHubOrange, modifier = Modifier.size(16.dp))
                                            Spacer(modifier = Modifier.width(8.dp))
                                            Text(
                                                "Offline cache · $err",
                                                style = MaterialTheme.typography.bodySmall,
                                                fontWeight = FontWeight.Medium,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                        }
                                    }
                                }
                            }

                            if (hasUnproxiedBanner) {
                                item(key = "cloud-unproxied-banner", span = { GridItemSpan(maxLineSpan) }) {
                                    UnproxiedBanner(uiState = uiState, viewModel = viewModel)
                                }
                            }

                            if (hasRestoreBanner) {
                                item(key = "cloud-restore-banner", span = { GridItemSpan(maxLineSpan) }) {
                                    RestoreOriginalsBanner(uiState = uiState, viewModel = viewModel)
                                }
                            }

                            if (hasDeleteBanner) {
                                item(key = "cloud-delete-banner", span = { GridItemSpan(maxLineSpan) }) {
                                    DeletePhotosBanner(uiState = uiState, viewModel = viewModel)
                                }
                            }

                            if (uiState.isViewingTrash) {
                                item(key = "cloud-trash-info-banner", span = { GridItemSpan(maxLineSpan) }) {
                                    Surface(
                                        shape = RoundedCornerShape(16.dp),
                                        color = PhotoHubRed.copy(alpha = 0.08f),
                                        border = BorderStroke(1.dp, PhotoHubRed.copy(alpha = 0.28f)),
                                        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)
                                    ) {
                                        Row(
                                            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                                        ) {
                                            Icon(Icons.Rounded.DeleteSweep, null, tint = PhotoHubRed, modifier = Modifier.size(20.dp))
                                            Column(modifier = Modifier.weight(1f)) {
                                                Text(
                                                    "Trash · 30-Day Safety Bin",
                                                    style = MaterialTheme.typography.labelMedium,
                                                    fontWeight = FontWeight.ExtraBold
                                                )
                                                Text(
                                                    if (uiState.trashPhotos.isEmpty()) "No deleted items."
                                                    else "${uiState.trashPhotos.size} item(s) · Auto-removed after 30 days",
                                                    style = MaterialTheme.typography.labelSmall,
                                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                                )
                                            }
                                            if (uiState.trashPhotos.isNotEmpty()) {
                                                Button(
                                                    onClick = { viewModel.requestEmptyTrashAll() },
                                                    colors = ButtonDefaults.buttonColors(containerColor = PhotoHubRed),
                                                    shape = CircleShape,
                                                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
                                                    modifier = Modifier.height(32.dp)
                                                ) {
                                                    Text("Empty", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            if (syncState.isSyncing) {
                                item(key = "cloud-sync-banner", span = { GridItemSpan(maxLineSpan) }) {
                                    Surface(
                                        shape = RoundedCornerShape(16.dp),
                                        color = MaterialTheme.colorScheme.surface,
                                        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                                        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)
                                    ) {
                                        Row(
                                            modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            CircularProgressIndicator(
                                                modifier = Modifier.size(16.dp),
                                                strokeWidth = 2.dp,
                                                color = PhotoHubOrange
                                            )
                                            Spacer(modifier = Modifier.width(10.dp))
                                            Text(
                                                text = syncState.statusText.ifBlank {
                                                    "Syncing previews (${syncState.completedCount}/${syncState.totalCount})…"
                                                },
                                                style = MaterialTheme.typography.bodySmall,
                                                fontWeight = FontWeight.SemiBold,
                                                modifier = Modifier.weight(1f),
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                            TextButton(
                                                onClick = { syncManager.cancel() },
                                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)
                                            ) {
                                                Text(
                                                    "Stop",
                                                    style = MaterialTheme.typography.labelSmall,
                                                    fontWeight = FontWeight.Bold,
                                                    color = PhotoHubDeepOrange
                                                )
                                            }
                                        }
                                    }
                                }
                            }

                            if (uiState.timeline.sections.isEmpty()) {
                                item(key = "cloud-empty-filter", span = { GridItemSpan(maxLineSpan) }) {
                                    Column(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(vertical = 36.dp, horizontal = 20.dp),
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        verticalArrangement = Arrangement.spacedBy(10.dp)
                                    ) {
                                        SunnyMascot(mood = MascotMood.SLEEPING, size = 84.dp)
                                        Text(
                                            "No Matching Items",
                                            style = MaterialTheme.typography.titleMedium,
                                            fontWeight = FontWeight.ExtraBold
                                        )
                                        Text(
                                            text = if (uiState.searchQuery.isNotBlank()) {
                                                "No backed-up items match \"${uiState.searchQuery}\"."
                                            } else {
                                                "Try clearing your filter or switching tabs."
                                            },
                                            style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            textAlign = TextAlign.Center
                                        )
                                        if (uiState.hasActiveFilter) {
                                            SoftOrangeButton(
                                                text = "Clear Filters",
                                                onClick = { viewModel.clearFilters() }
                                            )
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
                                                    .padding(top = 12.dp, bottom = 2.dp),
                                                verticalAlignment = Alignment.CenterVertically
                                            ) {
                                                Text(
                                                    sec.yearLabel,
                                                    style = MaterialTheme.typography.titleLarge,
                                                    fontWeight = FontWeight.ExtraBold,
                                                    modifier = Modifier.weight(1f)
                                                )
                                                if (yrInfo != null) {
                                                    Surface(
                                                        shape = CircleShape,
                                                        color = MaterialTheme.colorScheme.primaryContainer
                                                    ) {
                                                        Text(
                                                            "${yrInfo.itemCount} items",
                                                            style = MaterialTheme.typography.labelSmall,
                                                            fontWeight = FontWeight.Bold,
                                                            color = PhotoHubOrange,
                                                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    item(key = "hdr-${sec.id}", span = { GridItemSpan(maxLineSpan) }) {
                                        Row(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .padding(top = 8.dp, bottom = 2.dp),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Text(
                                                sec.title,
                                                style = MaterialTheme.typography.titleSmall,
                                                fontWeight = FontWeight.ExtraBold,
                                                modifier = Modifier.weight(1f)
                                            )
                                            if (uiState.isSelectionMode) {
                                                val secAllSelected = sec.photos.isNotEmpty() &&
                                                    sec.photos.all { it.hash.lowercase(Locale.ROOT) in uiState.selectedHashes }
                                                Surface(
                                                    onClick = { viewModel.toggleSectionSelection(sec.photos) },
                                                    shape = CircleShape,
                                                    color = MaterialTheme.colorScheme.primaryContainer
                                                ) {
                                                    Text(
                                                        if (secAllSelected) "Clear" else "Select",
                                                        style = MaterialTheme.typography.labelSmall,
                                                        fontWeight = FontWeight.Bold,
                                                        color = PhotoHubOrange,
                                                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
                                                    )
                                                }
                                            } else {
                                                Surface(
                                                    shape = CircleShape,
                                                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.85f)
                                                ) {
                                                    Text(
                                                        "${sec.photos.size}",
                                                        style = MaterialTheme.typography.labelSmall,
                                                        fontWeight = FontWeight.Bold,
                                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                                                    )
                                                }
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
                                        val thumbBitmap = remember(photo.hash, uiState.thumbnailCacheVersion) {
                                            viewModel.getCachedThumbnail(photo.hash)
                                        }
                                        ServerThumbnailCell(
                                            photo = photo,
                                            bitmap = thumbBitmap,
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
                                                if (!uiState.isSelectionMode && !uiState.isBatchRestoring && !uiState.isBatchProxying && !uiState.isBatchDeleting && !uiState.isBatchUpdatingProtection) {
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

                        // Floating Pill Selection Action Bar (matches webpage `.selection-bar`)
                        if (uiState.isSelectionMode) {
                            SelectionRestoreBottomBar(
                                uiState = uiState,
                                onRestoreSelected = {
                                    if (uiState.isViewingTrash) viewModel.restoreSelectedFromTrash()
                                    else viewModel.requestRestoreSelected()
                                },
                                onAllowReproxySelected = { viewModel.allowReproxySelected() },
                                onDeleteSelected = { viewModel.requestDeleteSelected() },
                                modifier = Modifier
                                    .align(Alignment.BottomCenter)
                                    .padding(horizontal = 14.dp, vertical = 10.dp)
                            )
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
                    Surface(
                        shape = RoundedCornerShape(22.dp),
                        color = MaterialTheme.colorScheme.surface,
                        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                        tonalElevation = 6.dp
                    ) {
                        Column(
                            modifier = Modifier.padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            SunnyMascot(mood = MascotMood.UPLOADING, size = 72.dp)
                            Text(
                                uiState.pickStatusText,
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Bold
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CloudHeroStorageCard(
    uiState: ServerGalleryUiState,
    isSyncing: Boolean
) {
    val context = LocalContext.current
    val greeting = remember(uiState.userName) {
        val first = uiState.userName.trim().split(" ").firstOrNull().orEmpty()
        if (first.isNotEmpty()) "Hi, $first" else "Your Cloud Photos"
    }
    val mood = when {
        uiState.isBatchProxying || uiState.isBatchRestoring || isSyncing || uiState.isLoading -> MascotMood.UPLOADING
        uiState.errorMessage != null -> MascotMood.ALERT
        else -> MascotMood.HAPPY
    }

    val storage = uiState.serverStorage
    val usedBytes = storage?.usedBytes ?: uiState.totalServerBytes
    val usedStr = Formatter.formatFileSize(context, maxOf(0L, usedBytes))
    val quotaBytes = storage?.quotaBytes ?: 0L
    val hasQuota = quotaBytes > 0L
    val targetFraction = when {
        hasQuota -> (usedBytes.toDouble() / quotaBytes.toDouble()).toFloat().coerceIn(0.03f, 1f)
        (storage?.diskTotalBytes ?: 0L) > 0L ->
            (usedBytes.toDouble() / storage!!.diskTotalBytes!!.toDouble()).toFloat().coerceIn(0.04f, 1f)
        usedBytes > 0L -> 0.22f
        else -> 0.04f
    }
    val animatedFill by animateFloatAsState(
        targetValue = targetFraction,
        animationSpec = spring(dampingRatio = 0.8f, stiffness = 240f),
        label = "storageBarFill"
    )
    val quotaRightLabel = when {
        hasQuota -> {
            val qStr = Formatter.formatFileSize(context, quotaBytes)
            val pct = (targetFraction * 100f).roundToInt()
            "$qStr ($pct%)"
        }
        (storage?.diskFreeBytes ?: 0L) > 0L ->
            "${Formatter.formatFileSize(context, storage!!.diskFreeBytes!!)} free"
        else -> "Unlimited"
    }
    val splitSubtitle = if (storage?.mastersBytes != null && storage.proxiesBytes != null) {
        "Originals ${Formatter.formatFileSize(context, maxOf(0L, storage.mastersBytes))} · Proxies ${Formatter.formatFileSize(context, maxOf(0L, storage.proxiesBytes))}"
    } else {
        "Originals & compressed proxies synced"
    }

    Surface(
        shape = RoundedCornerShape(22.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        shadowElevation = 2.dp,
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 4.dp)
    ) {
        Box(
            modifier = Modifier.background(
                Brush.linearGradient(
                    colors = listOf(PhotoHubOrange.copy(alpha = 0.07f), Color.Transparent)
                )
            )
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    SunnyMascot(mood = mood, size = 54.dp)
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(5.dp)
                    ) {
                        Text(
                            text = greeting,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.ExtraBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = "${uiState.photos.size} total · ${uiState.photoCount} photos · ${uiState.videoCount} videos",
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }

                // Warm Gradient Storage Meter Bar (matches webpage `.storage-meter-wrap`)
                Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = "$usedStr used",
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.Bold
                        )
                        Text(
                            text = quotaRightLabel,
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }

                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(9.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxHeight()
                                .fillMaxWidth(animatedFill)
                                .clip(CircleShape)
                                .background(
                                    Brush.horizontalGradient(
                                        listOf(PhotoHubAmber, PhotoHubOrange, PhotoHubDeepOrange)
                                    )
                                )
                        )
                    }

                    Text(
                        text = splitSubtitle,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
    }
}

@Composable
private fun CloudControlBar(
    uiState: ServerGalleryUiState,
    viewModel: ServerGalleryViewModel,
    onSelectYear: (String) -> Unit
) {
    Surface(
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 4.dp)
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            // Search Input + Compact Grouping Segmented Pill (`Day | Month | Year`)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Surface(
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.background,
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                    modifier = Modifier.weight(1f)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 11.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Icon(
                            Icons.Rounded.Search,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(16.dp)
                        )
                        Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                            if (uiState.searchQuery.isEmpty()) {
                                Text(
                                    "Search Nov 2026, video, name…",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                            BasicTextField(
                                value = uiState.searchQuery,
                                onValueChange = { viewModel.setSearchQuery(it) },
                                singleLine = true,
                                textStyle = MaterialTheme.typography.bodySmall.copy(
                                    color = MaterialTheme.colorScheme.onSurface,
                                    fontWeight = FontWeight.Medium
                                ),
                                cursorBrush = SolidColor(PhotoHubOrange),
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                        if (uiState.searchQuery.isNotEmpty()) {
                            Icon(
                                Icons.Rounded.Cancel,
                                contentDescription = "Clear search",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(16.dp)
                                    .clickable { viewModel.setSearchQuery("") }
                            )
                        }
                    }
                }

                // Segmented Grouping Pill (`Day | Month | Year`)
                Surface(
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
                ) {
                    Row(
                        modifier = Modifier.padding(3.dp),
                        horizontalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        ServerTimelineGrouping.entries.forEach { mode ->
                            val selected = uiState.timelineGrouping == mode
                            Surface(
                                onClick = { viewModel.setTimelineGrouping(mode) },
                                shape = CircleShape,
                                color = if (selected) MaterialTheme.colorScheme.surface else Color.Transparent,
                                shadowElevation = if (selected) 1.dp else 0.dp
                            ) {
                                Text(
                                    text = mode.shortLabel,
                                    style = MaterialTheme.typography.labelSmall,
                                    fontWeight = FontWeight.Bold,
                                    color = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp)
                                )
                            }
                        }
                    }
                }
            }

            // Filter Pills (`All`, `Photos`, `Videos`, `Protected`, + `Needs Proxy`)
            LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(ServerMediaTypeFilter.entries) { media ->
                    val selected = uiState.mediaTypeFilter == media && uiState.filterMode == ServerGalleryFilter.ALL
                    val label = when {
                        media == ServerMediaTypeFilter.FAVORITES && uiState.favoriteCount > 0 -> "♥ ${media.title} (${uiState.favoriteCount})"
                        media == ServerMediaTypeFilter.FAVORITES -> "♥ ${media.title}"
                        media == ServerMediaTypeFilter.PROTECTED && uiState.protectedCount > 0 -> "${media.title} (${uiState.protectedCount})"
                        media == ServerMediaTypeFilter.TRASH && uiState.trashCount > 0 -> "${media.title} (${uiState.trashCount})"
                        else -> media.title
                    }
                    Surface(
                        onClick = {
                            if (uiState.filterMode != ServerGalleryFilter.ALL) {
                                viewModel.setFilterMode(ServerGalleryFilter.ALL)
                            }
                            viewModel.setMediaTypeFilter(media)
                        },
                        shape = CircleShape,
                        color = if (selected) PhotoHubOrange else MaterialTheme.colorScheme.background,
                        border = BorderStroke(
                            1.dp,
                            if (selected) PhotoHubOrange else MaterialTheme.colorScheme.outlineVariant
                        )
                    ) {
                        Text(
                            text = label,
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.Bold,
                            color = if (selected) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = 13.dp, vertical = 6.dp)
                        )
                    }
                }

                if (uiState.unproxiedCount > 0 || uiState.filterMode == ServerGalleryFilter.NEEDS_PROXY) {
                    item {
                        val selected = uiState.filterMode == ServerGalleryFilter.NEEDS_PROXY
                        Surface(
                            onClick = {
                                viewModel.setFilterMode(
                                    if (selected) ServerGalleryFilter.ALL else ServerGalleryFilter.NEEDS_PROXY
                                )
                            },
                            shape = CircleShape,
                            color = if (selected) PhotoHubOrange else MaterialTheme.colorScheme.primaryContainer,
                            border = BorderStroke(
                                1.dp,
                                if (selected) PhotoHubOrange else PhotoHubOrange.copy(alpha = 0.35f)
                            )
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(5.dp)
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(6.dp)
                                        .clip(CircleShape)
                                        .background(if (selected) Color.White else PhotoHubOrange)
                                )
                                Text(
                                    text = "Needs Proxy (${uiState.unproxiedCount})",
                                    style = MaterialTheme.typography.labelMedium,
                                    fontWeight = FontWeight.Bold,
                                    color = if (selected) Color.White else MaterialTheme.colorScheme.onPrimaryContainer
                                )
                            }
                        }
                    }
                }
            }

            // Year Quick-Jump Pills (`2026 · 412`, `2025 · 801`, ...)
            if (uiState.timeline.years.size > 1) {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(uiState.timeline.years, key = { it.anchorId }) { yr ->
                        val selected = uiState.selectedYearAnchor == yr.anchorId
                        Surface(
                            onClick = { onSelectYear(yr.anchorId) },
                            shape = CircleShape,
                            color = if (selected) PhotoHubOrange else MaterialTheme.colorScheme.surfaceVariant,
                            border = BorderStroke(
                                1.dp,
                                if (selected) PhotoHubOrange else MaterialTheme.colorScheme.outlineVariant
                            )
                        ) {
                            Text(
                                text = "${yr.label} · ${yr.itemCount}",
                                style = MaterialTheme.typography.labelSmall,
                                fontWeight = FontWeight.Bold,
                                color = if (selected) Color.White else MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.padding(horizontal = 11.dp, vertical = 5.dp)
                            )
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
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                when {
                    uiState.isBatchProxying -> {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp,
                            color = PhotoHubOrange
                        )
                        Spacer(modifier = Modifier.width(10.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                "Creating proxies ${uiState.batchCompleted}/${uiState.batchTotal}",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.Bold
                            )
                            if (uiState.batchStatusText.isNotBlank()) {
                                Text(
                                    uiState.batchStatusText,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                        TextButton(
                            onClick = { viewModel.stopBatchProxy() },
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)
                        ) {
                            Text("Stop", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = PhotoHubDeepOrange)
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
                            PulsingStatusDot(color = PhotoHubOrange)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                text = if (uiState.filterMode == ServerGalleryFilter.NEEDS_PROXY) {
                                    "Showing ${uiState.unproxiedCount} unproxied · Tap for All"
                                } else {
                                    "${uiState.unproxiedCount} item${if (uiState.unproxiedCount == 1) "" else "s"} missing proxy"
                                },
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.Bold
                            )
                        }
                        val canProxy = !uiState.isBatchRestoring && !uiState.isBatchDeleting
                        Box(
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(
                                    Brush.horizontalGradient(
                                        listOf(Color(0xFFFF9840), PhotoHubOrange, PhotoHubDeepOrange)
                                    )
                                )
                                .clickable(enabled = canProxy) { viewModel.startBatchProxy() }
                                .padding(horizontal = 12.dp, vertical = 6.dp)
                        ) {
                            Text(
                                "Proxy All",
                                style = MaterialTheme.typography.labelSmall,
                                fontWeight = FontWeight.Bold,
                                color = Color.White
                            )
                        }
                    }
                    uiState.batchBannerMessage != null -> {
                        Icon(Icons.Rounded.CheckCircle, null, tint = PhotoHubGreen, modifier = Modifier.size(18.dp))
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            uiState.batchBannerMessage.orEmpty(),
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                        IconButton(onClick = { viewModel.dismissBatchBanner() }, modifier = Modifier.size(26.dp)) {
                            Icon(Icons.Rounded.Close, null, modifier = Modifier.size(15.dp))
                        }
                    }
                }
            }

            if (uiState.isBatchProxying && uiState.batchTotal > 0) {
                val frac = (uiState.batchCompleted.toFloat() / uiState.batchTotal.toFloat()).coerceIn(0.04f, 1f)
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(5.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxHeight()
                            .fillMaxWidth(frac)
                            .clip(CircleShape)
                            .background(Brush.horizontalGradient(listOf(PhotoHubAmber, PhotoHubOrange, PhotoHubDeepOrange)))
                    )
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
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, PhotoHubOrange.copy(alpha = 0.32f)),
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (uiState.isBatchRestoring) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        strokeWidth = 2.dp,
                        color = PhotoHubOrange
                    )
                    Spacer(modifier = Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "Restoring originals ${uiState.restoreCompleted}/${uiState.restoreTotal}",
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.Bold
                        )
                        if (uiState.restoreStatusText.isNotBlank()) {
                            Text(
                                uiState.restoreStatusText,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                    TextButton(
                        onClick = { viewModel.stopBatchRestore() },
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)
                    ) {
                        Text("Stop", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = PhotoHubDeepOrange)
                    }
                } else if (uiState.isBatchUpdatingProtection) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        strokeWidth = 2.dp,
                        color = PhotoHubMint
                    )
                    Spacer(modifier = Modifier.width(10.dp))
                    Text(
                        "Allowing re-proxy for selected items…",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.weight(1f)
                    )
                } else if (uiState.restoreBannerMessage != null) {
                    Icon(Icons.Rounded.CheckCircle, null, tint = PhotoHubGreen, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        uiState.restoreBannerMessage.orEmpty(),
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                    IconButton(onClick = { viewModel.dismissRestoreBanner() }, modifier = Modifier.size(26.dp)) {
                        Icon(Icons.Rounded.Close, null, modifier = Modifier.size(15.dp))
                    }
                }
            }

            if (uiState.isBatchRestoring && uiState.restoreTotal > 0) {
                val frac = (uiState.restoreCompleted.toFloat() / uiState.restoreTotal.toFloat()).coerceIn(0.04f, 1f)
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(5.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxHeight()
                            .fillMaxWidth(frac)
                            .clip(CircleShape)
                            .background(Brush.horizontalGradient(listOf(PhotoHubAmber, PhotoHubOrange, PhotoHubDeepOrange)))
                    )
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
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, PhotoHubRed.copy(alpha = 0.35f)),
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (uiState.isBatchDeleting) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = PhotoHubRed
                )
                Spacer(modifier = Modifier.width(10.dp))
                Text(
                    "Deleting selected photos from server…",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f)
                )
            } else if (uiState.deleteBannerMessage != null) {
                Icon(
                    Icons.Rounded.DeleteOutline,
                    null,
                    tint = PhotoHubRed,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    uiState.deleteBannerMessage.orEmpty(),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                IconButton(onClick = { viewModel.dismissDeleteBanner() }, modifier = Modifier.size(26.dp)) {
                    Icon(Icons.Rounded.Close, null, modifier = Modifier.size(15.dp))
                }
            }
        }
    }
}

@Composable
private fun SelectionRestoreBottomBar(
    uiState: ServerGalleryUiState,
    onRestoreSelected: () -> Unit,
    onAllowReproxySelected: () -> Unit,
    onDeleteSelected: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val selectedList = uiState.activeSourcePhotos.filter { it.hash.lowercase(Locale.ROOT) in uiState.selectedHashes }
    val selectedProtected = selectedList.filter { uiState.isRestoredOrProtected(it) }
    val unrestored = selectedList.filter { !uiState.isRestoredOrProtected(it) }
    val targetBytes = (if (unrestored.isNotEmpty()) unrestored else selectedList).sumOf { maxOf(0L, it.size) }
    val sizeStr = Formatter.formatFileSize(context, targetBytes)
    val isBusyBatch = uiState.isBatchRestoring || uiState.isBatchProxying || uiState.isBatchDeleting || uiState.isBatchUpdatingProtection
    val actionsEnabled = selectedList.isNotEmpty() && !isBusyBatch
    val showAllowReproxy = !uiState.isViewingTrash && (selectedProtected.isNotEmpty() || uiState.mediaTypeFilter == ServerMediaTypeFilter.PROTECTED)
    val allowReproxyEnabled = selectedProtected.isNotEmpty() && !isBusyBatch

    Surface(
        shape = if (showAllowReproxy) RoundedCornerShape(22.dp) else CircleShape,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.5.dp, PhotoHubOrange.copy(alpha = 0.8f)),
        shadowElevation = 10.dp,
        tonalElevation = 4.dp,
        modifier = modifier.fillMaxWidth()
    ) {
        if (showAllowReproxy) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(
                        text = if (selectedList.isEmpty()) "Tap protected photos to select" else "${selectedList.size} selected",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.ExtraBold
                    )
                    if (selectedList.isNotEmpty()) {
                        Text(
                            text = "· ~$sizeStr · ${selectedProtected.size} protected",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Surface(
                        onClick = onDeleteSelected,
                        enabled = actionsEnabled,
                        shape = CircleShape,
                        color = PhotoHubRed.copy(alpha = if (actionsEnabled) 0.14f else 0.06f),
                        border = BorderStroke(1.dp, PhotoHubRed.copy(alpha = if (actionsEnabled) 0.35f else 0.15f))
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 11.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(
                                Icons.Rounded.DeleteOutline,
                                contentDescription = "Move to Trash",
                                tint = PhotoHubRed.copy(alpha = if (actionsEnabled) 1f else 0.45f),
                                modifier = Modifier.size(16.dp)
                            )
                            Text(
                                "Trash",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.Bold,
                                color = PhotoHubRed.copy(alpha = if (actionsEnabled) 1f else 0.45f)
                            )
                        }
                    }

                    Surface(
                        onClick = onAllowReproxySelected,
                        enabled = allowReproxyEnabled,
                        shape = CircleShape,
                        color = PhotoHubMint.copy(alpha = if (allowReproxyEnabled) 0.15f else 0.06f),
                        border = BorderStroke(1.dp, PhotoHubMint.copy(alpha = if (allowReproxyEnabled) 0.42f else 0.18f)),
                        modifier = Modifier.weight(1f)
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.Center
                        ) {
                            Icon(
                                Icons.Rounded.LockOpen,
                                contentDescription = "Allow Re-Proxy",
                                tint = PhotoHubMint.copy(alpha = if (allowReproxyEnabled) 1f else 0.45f),
                                modifier = Modifier.size(15.dp)
                            )
                            Spacer(modifier = Modifier.width(5.dp))
                            Text(
                                text = if (selectedProtected.isNotEmpty() && selectedProtected.size < selectedList.size) {
                                    "Allow Re-Proxy (${selectedProtected.size})"
                                } else {
                                    "Allow Re-Proxy"
                                },
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.Bold,
                                color = PhotoHubMint.copy(alpha = if (allowReproxyEnabled) 1f else 0.45f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }

                    Box(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(
                                if (actionsEnabled) {
                                    Brush.horizontalGradient(listOf(Color(0xFFFF9840), PhotoHubOrange, PhotoHubDeepOrange))
                                } else {
                                    Brush.horizontalGradient(listOf(PhotoHubOrange.copy(alpha = 0.4f), PhotoHubDeepOrange.copy(alpha = 0.4f)))
                                }
                            )
                            .clickable(enabled = actionsEnabled, onClick = onRestoreSelected)
                            .padding(horizontal = 12.dp, vertical = 8.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(Icons.Rounded.CloudDownload, null, tint = Color.White, modifier = Modifier.size(15.dp))
                            Text(
                                "Restore",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.Bold,
                                color = Color.White
                            )
                        }
                    }
                }
            }
        } else {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = if (selectedList.isEmpty()) "Tap photos to select" else "${selectedList.size} selected",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.ExtraBold
                    )
                    if (selectedList.isNotEmpty()) {
                        val alreadyCount = selectedList.size - unrestored.size
                        Text(
                            text = if (alreadyCount > 0) {
                                "~$sizeStr · ${unrestored.size} new"
                            } else {
                                "~$sizeStr · ${unrestored.size} original${if (unrestored.size == 1) "" else "s"}"
                            },
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
                Spacer(modifier = Modifier.width(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Surface(
                        onClick = onDeleteSelected,
                        enabled = actionsEnabled,
                        shape = CircleShape,
                        color = PhotoHubRed.copy(alpha = if (actionsEnabled) 0.14f else 0.06f),
                        border = BorderStroke(1.dp, PhotoHubRed.copy(alpha = if (actionsEnabled) 0.35f else 0.15f))
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(
                                Icons.Rounded.DeleteOutline,
                                contentDescription = "Delete from Server",
                                tint = PhotoHubRed.copy(alpha = if (actionsEnabled) 1f else 0.45f),
                                modifier = Modifier.size(16.dp)
                            )
                            Text(
                                if (uiState.isViewingTrash) "Delete Forever" else "Trash",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.Bold,
                                color = PhotoHubRed.copy(alpha = if (actionsEnabled) 1f else 0.45f)
                            )
                        }
                    }

                    Box(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(
                                if (actionsEnabled) {
                                    Brush.horizontalGradient(listOf(Color(0xFFFF9840), PhotoHubOrange, PhotoHubDeepOrange))
                                } else {
                                    Brush.horizontalGradient(listOf(PhotoHubOrange.copy(alpha = 0.4f), PhotoHubDeepOrange.copy(alpha = 0.4f)))
                                }
                            )
                            .clickable(enabled = actionsEnabled, onClick = onRestoreSelected)
                            .padding(horizontal = 14.dp, vertical = 8.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(5.dp)
                        ) {
                            Icon(Icons.Rounded.CloudDownload, null, tint = Color.White, modifier = Modifier.size(16.dp))
                            Text(
                                "Restore",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.Bold,
                                color = Color.White
                            )
                        }
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
    isSelectionMode: Boolean,
    isSelected: Boolean,
    isRestoredOrProtected: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit
) {
    val tileShape = RoundedCornerShape(12.dp)
    val tileScale by animateFloatAsState(
        targetValue = if (isSelected) 0.95f else 1f,
        animationSpec = spring(dampingRatio = 0.72f, stiffness = 450f),
        label = "tileScale"
    )

    Box(
        modifier = Modifier
            .aspectRatio(1f)
            .scale(tileScale)
            .clip(tileShape)
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .border(
                width = if (isSelected) 2.5.dp else 0.5.dp,
                color = if (isSelected) PhotoHubOrange else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                shape = tileShape
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
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Icon(
                    imageVector = if (photo.isVideo) Icons.Rounded.Videocam else Icons.Rounded.Photo,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(22.dp)
                )
                Text(
                    text = if (photo.isVideo) "Video" else "Photo",
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        } else {
            WarmShimmerBox(modifier = Modifier.fillMaxSize(), cornerRadius = 12.dp)
        }

        if (isSelected) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(PhotoHubOrange.copy(alpha = 0.24f))
            )
        }

        // Bottom-left frosted `▶ Video` pill (matches webpage `.tile-video-pill`)
        if (photo.isVideo) {
            Row(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(6.dp)
                    .clip(CircleShape)
                    .background(Color(0xFF14100E).copy(alpha = 0.72f))
                    .padding(horizontal = 7.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(3.dp)
            ) {
                Icon(Icons.Rounded.PlayArrow, null, tint = Color.White, modifier = Modifier.size(12.dp))
                Text(
                    "Video",
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
            }
        }

        if (photo.isFavorited && !photo.isTrashed) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(6.dp)
                    .size(22.dp)
                    .clip(CircleShape)
                    .background(PhotoHubRed.copy(alpha = 0.88f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Rounded.Favorite, null, tint = Color.White, modifier = Modifier.size(13.dp))
            }
        }

        if (photo.isTrashed && photo.daysRemaining != null) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(6.dp)
                    .clip(CircleShape)
                    .background(PhotoHubRed.copy(alpha = 0.88f))
                    .padding(horizontal = 7.dp, vertical = 2.dp)
            ) {
                Text(
                    "${photo.daysRemaining}d",
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.ExtraBold,
                    color = Color.White
                )
            }
        }

        if (isSelectionMode) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(7.dp)
                    .size(22.dp)
                    .clip(CircleShape)
                    .background(
                        if (isSelected) PhotoHubOrange
                        else Color.Black.copy(alpha = 0.45f)
                    )
                    .border(
                        width = 1.8.dp,
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
                        modifier = Modifier.size(13.dp)
                    )
                }
            }
        }

        // Top-right status badges: Mint protected check + Orange needs-proxy dot (matches webpage `.tile-badges`)
        if (isRestoredOrProtected || photo.needsProxy) {
            Row(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(6.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (isRestoredOrProtected) {
                    Box(
                        modifier = Modifier
                            .size(20.dp)
                            .clip(CircleShape)
                            .background(PhotoHubMint.copy(alpha = 0.92f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.Rounded.Check,
                            contentDescription = "Protected Original",
                            tint = Color.White,
                            modifier = Modifier.size(12.dp)
                        )
                    }
                }
                if (photo.needsProxy) {
                    Box(
                        modifier = Modifier
                            .size(9.dp)
                            .clip(CircleShape)
                            .background(PhotoHubOrange)
                            .border(1.2.dp, Color.White.copy(alpha = 0.9f), CircleShape)
                    )
                }
            }
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
                    if (isScrubbing) PhotoHubOrange
                    else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f)
                )
        )

        if (isScrubbing && activeSecIndex in sections.indices) {
            val sec = sections[activeSecIndex]
            Surface(
                shape = CircleShape,
                color = Color(0xFF1A120E).copy(alpha = 0.92f),
                border = BorderStroke(1.dp, PhotoHubOrange.copy(alpha = 0.5f)),
                shadowElevation = 4.dp,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .offset { IntOffset(-130, handleOffsetY) }
            ) {
                Text(
                    text = sec.scrubLabel,
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
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
