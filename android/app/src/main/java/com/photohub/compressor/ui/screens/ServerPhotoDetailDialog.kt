package com.photohub.compressor.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.text.format.Formatter
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.photohub.compressor.data.ServerPhoto
import com.photohub.compressor.ui.components.GradientPrimaryButton
import com.photohub.compressor.ui.components.MascotMood
import com.photohub.compressor.ui.components.SunnyMascot
import com.photohub.compressor.ui.theme.PhotoHubAmber
import com.photohub.compressor.ui.theme.PhotoHubMint
import com.photohub.compressor.ui.theme.PhotoHubOrange
import com.photohub.compressor.ui.theme.PhotoHubRed
import com.photohub.compressor.viewmodel.PhotoDetailUiState
import java.io.File
import java.text.DateFormat
import java.util.Date

private val LightboxBg = Color(0xFF0E0A08)
private val LightboxCardBg = Color(0xFF201814)
private val LightboxBorder = Color(0x24FFFFFF)
private val LightboxInk = Color(0xFFFFF7F0)
private val LightboxMuted = Color(0xFFC7B2A5)

@Composable
fun ServerPhotoDetailDialog(
    detail: PhotoDetailUiState,
    allPhotos: List<ServerPhoto>,
    initialIndex: Int,
    getCachedThumbnail: (String) -> Bitmap?,
    onPageChanged: (ServerPhoto) -> Unit,
    onDismiss: () -> Unit,
    onCreateProxy: () -> Unit,
    onShareOriginal: () -> Unit,
    onSaveProxy: () -> Unit,
    onRestoreOriginal: () -> Unit,
    onDeleteFromServer: () -> Unit,
    onRestoreFromTrash: () -> Unit,
    onToggleFavorite: () -> Unit,
    onCreateShareLink: (title: String, expiresInHours: Int, passcode: String) -> Unit,
    onClearShareLink: () -> Unit,
    onToggleProtection: (Boolean) -> Unit,
    onShareFileConsumed: (File) -> Unit
) {
    val context = LocalContext.current
    val photosList = remember(allPhotos) { if (allPhotos.isNotEmpty()) allPhotos else listOf(detail.photo) }
    val safeInitial = initialIndex.coerceIn(0, (photosList.size - 1).coerceAtLeast(0))
    val pagerState = rememberPagerState(initialPage = safeInitial, pageCount = { photosList.size })

    val photo = detail.photo
    val isTrashed = photo.isTrashed
    val needsProxyAction = !isTrashed && (photo.needsProxy ||
        (photo.isVideo && detail.videoUri == null && detail.videoFile == null && photo.hasVideoProxy != true && !detail.isLoadingVideo))
    val isOriginalProtected = photo.isProtectedOriginal || detail.isLocallyProtected

    var showDeleteConfirm by remember(photo.hash) { mutableStateOf(false) }
    var showInfoDialog by remember(photo.hash) { mutableStateOf(false) }
    var showShareLinkDialog by remember(photo.hash) { mutableStateOf(false) }
    var isImmersive by remember { mutableStateOf(false) }
    var currentZoom by remember(photo.hash) { mutableFloatStateOf(1f) }

    LaunchedEffect(pagerState.settledPage, photosList) {
        val pagePhoto = photosList.getOrNull(pagerState.settledPage) ?: return@LaunchedEffect
        if (!pagePhoto.hash.equals(detail.photo.hash, ignoreCase = true)) {
            currentZoom = 1f
            onPageChanged(pagePhoto)
        }
    }

    LaunchedEffect(detail.shareFileReady) {
        val f = detail.shareFileReady ?: return@LaunchedEffect
        onShareFileConsumed(f)
    }

    if (showDeleteConfirm) {
        val masterStr = Formatter.formatFileSize(context, photo.size)
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            title = { Text(if (isTrashed) "Delete Permanently?" else "Move to Trash?", fontWeight = FontWeight.Bold) },
            text = {
                Text(
                    if (isTrashed) {
                        "Permanently delete ${photo.originalName} (~$masterStr) from your PhotoHub server? This cannot be undone."
                    } else {
                        "Move ${photo.originalName} (~$masterStr) to Trash? You can restore it anytime within 30 days."
                    }
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        showDeleteConfirm = false
                        onDeleteFromServer()
                    },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = PhotoHubRed,
                        contentColor = Color.White
                    )
                ) {
                    Text(if (isTrashed) "Delete Forever" else "Move to Trash")
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    if (showInfoDialog) {
        val dateStr = photo.parsedCreationDateMs?.let {
            DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it))
        } ?: photo.photoDate.ifBlank { "Undated" }
        val masterStr = Formatter.formatFileSize(context, photo.size)
        val proxyBytes = photo.videoProxySize ?: photo.proxySize
        val proxyStr = proxyBytes?.let { Formatter.formatFileSize(context, it) } ?: "None"

        AlertDialog(
            onDismissRequest = { showInfoDialog = false },
            title = { Text("Photo Details", fontWeight = FontWeight.ExtraBold) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    InfoDetailRow("Filename", photo.originalName)
                    InfoDetailRow("Date", dateStr)
                    InfoDetailRow("Original Size", masterStr)
                    InfoDetailRow("Proxy Size", proxyStr)
                    photo.cameraModel?.takeIf { it.isNotBlank() }?.let { cam ->
                        InfoDetailRow("Camera", cam)
                    }
                    InfoDetailRow("Integrity", "SHA-256 Verified (${photo.hash.take(12)}…)")
                    if (isTrashed && photo.daysRemaining != null) {
                        InfoDetailRow("Trash Retention", "${photo.daysRemaining} day(s) remaining")
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showInfoDialog = false }) { Text("Done", fontWeight = FontWeight.Bold) }
            }
        )
    }

    if (showShareLinkDialog || detail.createdShareLink != null) {
        ShareLinkDialog(
            defaultTitle = photo.originalName,
            createdLink = detail.createdShareLink,
            isBusy = detail.isBusy,
            onCreate = { title, hours, pass -> onCreateShareLink(title, hours, pass) },
            onCopy = { url ->
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                cm?.setPrimaryClip(ClipData.newPlainText("PhotoHub Share Link", url))
            },
            onShareSystem = { url ->
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, url)
                }
                context.startActivity(Intent.createChooser(intent, "Share Photo Link"))
            },
            onDismiss = {
                showShareLinkDialog = false
                onClearShareLink()
            }
        )
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)
    ) {
        val dateStr = photo.parsedCreationDateMs?.let {
            DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it))
        } ?: photo.photoDate.ifBlank { "Undated" }
        val masterStr = Formatter.formatFileSize(context, photo.size)

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(LightboxBg)
                .statusBarsPadding()
                .navigationBarsPadding()
        ) {
            // Swipeable HorizontalPager across all visible Cloud photos
            HorizontalPager(
                state = pagerState,
                userScrollEnabled = currentZoom <= 1.05f,
                modifier = Modifier.fillMaxSize()
            ) { page ->
                val pagePhoto = photosList[page]
                val isCurrent = pagePhoto.hash.equals(detail.photo.hash, ignoreCase = true)
                val bmp = if (isCurrent) detail.previewBitmap ?: getCachedThumbnail(pagePhoto.hash) else getCachedThumbnail(pagePhoto.hash)
                val playbackUri = if (isCurrent) {
                    detail.videoUri ?: detail.videoFile?.takeIf { it.exists() }?.let { Uri.fromFile(it) }
                } else null

                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = if (currentZoom > 1.05f) 0.dp else 8.dp),
                    contentAlignment = Alignment.Center
                ) {
                    when {
                        playbackUri != null -> {
                            VideoProxyPlayerView(videoUri = playbackUri)
                        }
                        bmp != null -> {
                            ZoomableLightboxImage(
                                bitmap = bmp,
                                contentDescription = pagePhoto.originalName,
                                isActivePage = isCurrent,
                                onZoomChanged = { z -> if (isCurrent) currentZoom = z },
                                onSingleTap = { isImmersive = !isImmersive }
                            )
                            if (isCurrent && detail.isLoadingVideo) {
                                Surface(
                                    shape = CircleShape,
                                    color = LightboxCardBg.copy(alpha = 0.92f),
                                    border = BorderStroke(1.dp, LightboxBorder),
                                    modifier = Modifier
                                        .align(Alignment.BottomCenter)
                                        .padding(bottom = 140.dp)
                                ) {
                                    Row(
                                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 7.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                                    ) {
                                        CircularProgressIndicator(
                                            modifier = Modifier.size(14.dp),
                                            color = PhotoHubOrange,
                                            strokeWidth = 2.dp
                                        )
                                        Text(
                                            "Loading video proxy…",
                                            style = MaterialTheme.typography.labelSmall,
                                            fontWeight = FontWeight.SemiBold,
                                            color = LightboxInk
                                        )
                                    }
                                }
                            }
                        }
                        pagePhoto.isVideo && pagePhoto.needsProxy -> {
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(10.dp),
                                modifier = Modifier.padding(horizontal = 24.dp)
                            ) {
                                SunnyMascot(mood = MascotMood.HAPPY, size = 78.dp)
                                Text(
                                    "No Video Proxy Yet",
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.Bold,
                                    color = LightboxInk
                                )
                                Text(
                                    "Tap Create Video Proxy below to generate a lightweight playable MP4 & thumbnail.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = LightboxMuted,
                                    textAlign = TextAlign.Center
                                )
                            }
                        }
                        else -> {
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                SunnyMascot(mood = MascotMood.UPLOADING, size = 74.dp)
                                Text(
                                    "Loading preview…",
                                    style = MaterialTheme.typography.labelMedium,
                                    fontWeight = FontWeight.Bold,
                                    color = LightboxMuted
                                )
                            }
                        }
                    }
                }
            }

            // Top Chrome (auto-hides on single tap for full immersive viewing)
            AnimatedVisibility(
                visible = !isImmersive,
                enter = fadeIn(),
                exit = fadeOut(),
                modifier = Modifier.align(Alignment.TopCenter)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(LightboxBg.copy(alpha = 0.78f))
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            text = photo.originalName,
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.ExtraBold,
                            color = LightboxInk,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = "$dateStr · $masterStr" + if (photosList.size > 1) " · ${pagerState.currentPage + 1}/${photosList.size}" else "",
                            style = MaterialTheme.typography.labelSmall,
                            color = LightboxMuted,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    if (!isTrashed) {
                        Surface(
                            onClick = onToggleFavorite,
                            shape = CircleShape,
                            color = if (photo.isFavorited) PhotoHubRed.copy(alpha = 0.25f) else Color.White.copy(alpha = 0.12f),
                            border = BorderStroke(1.dp, if (photo.isFavorited) PhotoHubRed.copy(alpha = 0.6f) else LightboxBorder),
                            modifier = Modifier.size(36.dp)
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(
                                    if (photo.isFavorited) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                                    contentDescription = "Favorite",
                                    tint = if (photo.isFavorited) PhotoHubRed else LightboxInk,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                        }
                    }
                    Surface(
                        onClick = { showInfoDialog = true },
                        shape = CircleShape,
                        color = Color.White.copy(alpha = 0.12f),
                        border = BorderStroke(1.dp, LightboxBorder),
                        modifier = Modifier.size(36.dp)
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(
                                Icons.Rounded.Info,
                                contentDescription = "Details",
                                tint = LightboxInk,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    }
                    Surface(
                        onClick = onDismiss,
                        shape = CircleShape,
                        color = Color.White.copy(alpha = 0.12f),
                        border = BorderStroke(1.dp, LightboxBorder),
                        modifier = Modifier.size(36.dp)
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(
                                Icons.Rounded.Close,
                                contentDescription = "Close",
                                tint = LightboxInk,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    }
                }
            }

            // Bottom Chrome Sheet (auto-hides in immersive mode)
            AnimatedVisibility(
                visible = !isImmersive,
                enter = fadeIn(),
                exit = fadeOut(),
                modifier = Modifier.align(Alignment.BottomCenter)
            ) {
                Column(modifier = Modifier.fillMaxWidth()) {
                    detail.videoUnavailableNote?.let { note ->
                        Text(
                            text = note,
                            style = MaterialTheme.typography.bodySmall,
                            color = PhotoHubAmber,
                            textAlign = TextAlign.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 20.dp, vertical = 4.dp)
                        )
                    }

                    if (detail.isBusy && detail.busyLabel.isNotEmpty()) {
                        Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            Surface(
                                shape = CircleShape,
                                color = LightboxCardBg,
                                border = BorderStroke(1.dp, PhotoHubOrange.copy(alpha = 0.45f)),
                                modifier = Modifier.padding(vertical = 4.dp)
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 7.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(14.dp),
                                        color = PhotoHubOrange,
                                        strokeWidth = 2.dp
                                    )
                                    Text(
                                        detail.busyLabel,
                                        style = MaterialTheme.typography.labelSmall,
                                        fontWeight = FontWeight.SemiBold,
                                        color = LightboxInk
                                    )
                                }
                            }
                        }
                    }

                    detail.saveMessage?.let { msg ->
                        Text(
                            text = msg,
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.SemiBold,
                            color = PhotoHubMint,
                            textAlign = TextAlign.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 20.dp, vertical = 4.dp)
                        )
                    }

                    Surface(
                        shape = RoundedCornerShape(22.dp),
                        color = LightboxCardBg.copy(alpha = 0.96f),
                        border = BorderStroke(1.dp, LightboxBorder),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 10.dp)
                    ) {
                        Column(
                            modifier = Modifier.padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            val previewBytes = detail.videoFile?.takeIf { it.exists() }?.length()
                                ?: photo.videoProxySize
                                ?: photo.proxySize
                            val smallStr = previewBytes?.let { Formatter.formatFileSize(context, it) }

                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                if (photo.isVideo) {
                                    LightboxBadgePill(text = "Video", color = PhotoHubOrange)
                                }
                                if (photo.isFavorited && !isTrashed) {
                                    LightboxBadgePill(text = "Favorite", color = PhotoHubRed, icon = Icons.Rounded.Favorite)
                                }
                                if (isOriginalProtected) {
                                    LightboxBadgePill(
                                        text = "Protected Original",
                                        color = PhotoHubMint,
                                        icon = Icons.Rounded.VerifiedUser
                                    )
                                }
                                if (isTrashed && photo.daysRemaining != null) {
                                    LightboxBadgePill(text = "${photo.daysRemaining}d left in Trash", color = PhotoHubRed)
                                } else {
                                    LightboxBadgePill(
                                        text = if (photo.needsProxy) "Needs Proxy" else (smallStr?.let { "Proxy $it" } ?: "Proxy Ready"),
                                        color = if (photo.needsProxy) PhotoHubAmber else PhotoHubMint
                                    )
                                }
                            }

                            if (isTrashed) {
                                Row(
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    GradientPrimaryButton(
                                        text = "Restore to Cloud",
                                        icon = Icons.Rounded.RestoreFromTrash,
                                        onClick = onRestoreFromTrash,
                                        enabled = !detail.isBusy,
                                        modifier = Modifier.weight(1f)
                                    )
                                    Surface(
                                        onClick = { showDeleteConfirm = true },
                                        enabled = !detail.isBusy,
                                        shape = CircleShape,
                                        color = PhotoHubRed.copy(alpha = 0.2f),
                                        border = BorderStroke(1.dp, PhotoHubRed.copy(alpha = 0.45f)),
                                        modifier = Modifier.height(48.dp)
                                    ) {
                                        Box(
                                            modifier = Modifier.padding(horizontal = 16.dp),
                                            contentAlignment = Alignment.Center
                                        ) {
                                            Icon(Icons.Rounded.DeleteForever, contentDescription = "Delete Forever", tint = PhotoHubRed)
                                        }
                                    }
                                }
                            } else {
                                if (isOriginalProtected) {
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clip(RoundedCornerShape(12.dp))
                                            .background(PhotoHubMint.copy(alpha = 0.12f))
                                            .padding(horizontal = 10.dp, vertical = 6.dp),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Icon(Icons.Rounded.Lock, null, tint = PhotoHubMint, modifier = Modifier.size(16.dp))
                                        Spacer(modifier = Modifier.width(8.dp))
                                        Text(
                                            "Protected from auto re-compression.",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = LightboxMuted,
                                            modifier = Modifier.weight(1f)
                                        )
                                        TextButton(
                                            onClick = { onToggleProtection(false) },
                                            enabled = !detail.isBusy,
                                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)
                                        ) {
                                            Text(
                                                "Allow Re-Proxy",
                                                style = MaterialTheme.typography.labelSmall,
                                                fontWeight = FontWeight.Bold,
                                                color = PhotoHubOrange
                                            )
                                        }
                                    }
                                }

                                if (needsProxyAction) {
                                    Surface(
                                        onClick = onCreateProxy,
                                        enabled = !detail.isBusy,
                                        shape = CircleShape,
                                        color = PhotoHubAmber.copy(alpha = 0.15f),
                                        border = BorderStroke(1.dp, PhotoHubAmber.copy(alpha = 0.42f)),
                                        modifier = Modifier.fillMaxWidth()
                                    ) {
                                        Row(
                                            modifier = Modifier.padding(vertical = 10.dp),
                                            horizontalArrangement = Arrangement.Center,
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Icon(Icons.Rounded.AutoFixHigh, null, tint = PhotoHubAmber, modifier = Modifier.size(17.dp))
                                            Spacer(modifier = Modifier.width(6.dp))
                                            Text(
                                                if (photo.isVideo) "Create Video Proxy" else "Create Proxy",
                                                style = MaterialTheme.typography.labelLarge,
                                                fontWeight = FontWeight.Bold,
                                                color = PhotoHubAmber
                                            )
                                        }
                                    }
                                }

                                Row(
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    GradientPrimaryButton(
                                        text = "Share Original",
                                        icon = Icons.Rounded.IosShare,
                                        onClick = onShareOriginal,
                                        enabled = !detail.isBusy,
                                        modifier = Modifier.weight(1f)
                                    )
                                    Surface(
                                        onClick = { showShareLinkDialog = true },
                                        enabled = !detail.isBusy,
                                        shape = CircleShape,
                                        color = Color.White.copy(alpha = 0.12f),
                                        border = BorderStroke(1.dp, LightboxBorder),
                                        modifier = Modifier.height(48.dp)
                                    ) {
                                        Row(
                                            modifier = Modifier.padding(horizontal = 14.dp),
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(5.dp)
                                        ) {
                                            Icon(Icons.Rounded.Link, null, tint = LightboxInk, modifier = Modifier.size(17.dp))
                                            Text("Link", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = LightboxInk)
                                        }
                                    }
                                }

                                Row(
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    val saveEnabled = !detail.isBusy && (photo.isVideo || detail.previewBitmap != null)
                                    Surface(
                                        onClick = onSaveProxy,
                                        enabled = saveEnabled,
                                        shape = CircleShape,
                                        color = Color.White.copy(alpha = if (saveEnabled) 0.10f else 0.05f),
                                        border = BorderStroke(1.dp, LightboxBorder),
                                        modifier = Modifier.weight(1f)
                                    ) {
                                        Row(
                                            modifier = Modifier.padding(vertical = 10.dp),
                                            horizontalArrangement = Arrangement.Center,
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Icon(
                                                if (photo.isVideo) Icons.Rounded.Videocam else Icons.Rounded.Photo,
                                                null,
                                                tint = LightboxInk.copy(alpha = if (saveEnabled) 1f else 0.45f),
                                                modifier = Modifier.size(16.dp)
                                            )
                                            Spacer(modifier = Modifier.width(5.dp))
                                            Text(
                                                "Save Proxy",
                                                style = MaterialTheme.typography.labelMedium,
                                                fontWeight = FontWeight.Bold,
                                                color = LightboxInk.copy(alpha = if (saveEnabled) 1f else 0.45f)
                                            )
                                        }
                                    }

                                    Surface(
                                        onClick = onRestoreOriginal,
                                        enabled = !detail.isBusy,
                                        shape = CircleShape,
                                        color = Color.White.copy(alpha = if (!detail.isBusy) 0.10f else 0.05f),
                                        border = BorderStroke(1.dp, LightboxBorder),
                                        modifier = Modifier.weight(1f)
                                    ) {
                                        Row(
                                            modifier = Modifier.padding(vertical = 10.dp),
                                            horizontalArrangement = Arrangement.Center,
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Icon(
                                                Icons.Rounded.ArrowCircleDown,
                                                null,
                                                tint = LightboxInk.copy(alpha = if (!detail.isBusy) 1f else 0.45f),
                                                modifier = Modifier.size(16.dp)
                                            )
                                            Spacer(modifier = Modifier.width(5.dp))
                                            Text(
                                                "Restore",
                                                style = MaterialTheme.typography.labelMedium,
                                                fontWeight = FontWeight.Bold,
                                                color = LightboxInk.copy(alpha = if (!detail.isBusy) 1f else 0.45f)
                                            )
                                        }
                                    }

                                    Surface(
                                        onClick = { showDeleteConfirm = true },
                                        enabled = !detail.isBusy,
                                        shape = CircleShape,
                                        color = PhotoHubRed.copy(alpha = 0.18f),
                                        border = BorderStroke(1.dp, PhotoHubRed.copy(alpha = 0.38f)),
                                        modifier = Modifier.size(width = 46.dp, height = 38.dp)
                                    ) {
                                        Box(contentAlignment = Alignment.Center) {
                                            Icon(
                                                Icons.Rounded.DeleteOutline,
                                                contentDescription = "Move to Trash",
                                                tint = PhotoHubRed,
                                                modifier = Modifier.size(18.dp)
                                            )
                                        }
                                    }
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
private fun ZoomableLightboxImage(
    bitmap: Bitmap,
    contentDescription: String,
    isActivePage: Boolean,
    onZoomChanged: (Float) -> Unit,
    onSingleTap: () -> Unit
) {
    var scale by remember(bitmap) { mutableFloatStateOf(1f) }
    var offset by remember(bitmap) { mutableStateOf(Offset.Zero) }

    LaunchedEffect(isActivePage) {
        if (!isActivePage) {
            scale = 1f
            offset = Offset.Zero
        }
    }

    Image(
        bitmap = bitmap.asImageBitmap(),
        contentDescription = contentDescription,
        contentScale = ContentScale.Fit,
        modifier = Modifier
            .fillMaxSize()
            .pointerInput(bitmap) {
                detectTapGestures(
                    onTap = { onSingleTap() },
                    onDoubleTap = {
                        if (scale > 1.05f) {
                            scale = 1f
                            offset = Offset.Zero
                        } else {
                            scale = 2.5f
                        }
                        onZoomChanged(scale)
                    }
                )
            }
            .pointerInput(bitmap) {
                detectTransformGestures { _, pan, zoom, _ ->
                    val nextScale = (scale * zoom).coerceIn(1f, 4.5f)
                    scale = nextScale
                    offset = if (nextScale > 1.05f) {
                        Offset(
                            (offset.x + pan.x).coerceIn(-600f * nextScale, 600f * nextScale),
                            (offset.y + pan.y).coerceIn(-600f * nextScale, 600f * nextScale)
                        )
                    } else {
                        Offset.Zero
                    }
                    onZoomChanged(scale)
                }
            }
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                translationX = offset.x
                translationY = offset.y
            }
    )
}

@Composable
private fun InfoDetailRow(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            text = label.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.SemiBold
        )
    }
}

@Composable
private fun ShareLinkDialog(
    defaultTitle: String,
    createdLink: com.photohub.compressor.data.ShareLinkResult?,
    isBusy: Boolean,
    onCreate: (title: String, expiresInHours: Int, passcode: String) -> Unit,
    onCopy: (String) -> Unit,
    onShareSystem: (String) -> Unit,
    onDismiss: () -> Unit
) {
    var title by remember(defaultTitle) { mutableStateOf(defaultTitle) }
    var passcode by remember { mutableStateOf("") }
    var expiryHours by remember { mutableIntStateOf(168) }
    var copiedNotice by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Share Public Link", fontWeight = FontWeight.ExtraBold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (createdLink != null) {
                    Text(
                        "Link ready! Anyone with this link can view & download the full-res original.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            text = createdLink.shareUrl,
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(10.dp)
                        )
                    }
                    if (copiedNotice) {
                        Text("Copied to clipboard!", style = MaterialTheme.typography.labelSmall, color = PhotoHubMint, fontWeight = FontWeight.Bold)
                    }
                } else {
                    Text(
                        "Create an expiring share link for family or friends (no PhotoHub login required).",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    OutlinedTextField(
                        value = title,
                        onValueChange = { title = it },
                        label = { Text("Title") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = passcode,
                        onValueChange = { passcode = it },
                        label = { Text("Passcode (optional)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        listOf(24 to "24h", 168 to "7 days", 720 to "30 days").forEach { (hrs, lbl) ->
                            FilterChip(
                                selected = expiryHours == hrs,
                                onClick = { expiryHours = hrs },
                                label = { Text(lbl) }
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            if (createdLink != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    TextButton(onClick = {
                        onCopy(createdLink.shareUrl)
                        copiedNotice = true
                    }) { Text("Copy") }
                    Button(
                        onClick = { onShareSystem(createdLink.shareUrl) },
                        colors = ButtonDefaults.buttonColors(containerColor = PhotoHubOrange)
                    ) { Text("Share") }
                }
            } else {
                Button(
                    onClick = { onCreate(title, expiryHours, passcode) },
                    enabled = !isBusy,
                    colors = ButtonDefaults.buttonColors(containerColor = PhotoHubOrange)
                ) {
                    Text(if (isBusy) "Creating…" else "Create Link")
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        }
    )
}

@Composable
private fun LightboxBadgePill(
    text: String,
    color: Color,
    icon: androidx.compose.ui.graphics.vector.ImageVector? = null
) {
    Surface(
        shape = CircleShape,
        color = color.copy(alpha = 0.18f)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            if (icon != null) {
                Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(12.dp))
            }
            Text(
                text = text,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
                color = color
            )
        }
    }
}

@Composable
private fun VideoProxyPlayerView(videoUri: Uri) {
    val context = LocalContext.current
    val player = remember(videoUri.toString()) {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(videoUri))
            prepare()
            playWhenReady = true
        }
    }
    DisposableEffect(player) {
        onDispose {
            player.release()
        }
    }
    AndroidView(
        factory = { ctx ->
            PlayerView(ctx).apply {
                this.player = player
                useController = true
            }
        },
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(16f / 9f)
            .clip(RoundedCornerShape(14.dp))
    )
}
