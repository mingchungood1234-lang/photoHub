package com.photohub.compressor.ui.screens

import android.net.Uri
import android.text.format.Formatter
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
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
    onDismiss: () -> Unit,
    onCreateProxy: () -> Unit,
    onShareOriginal: () -> Unit,
    onSaveProxy: () -> Unit,
    onRestoreOriginal: () -> Unit,
    onDeleteFromServer: () -> Unit,
    onToggleProtection: (Boolean) -> Unit,
    onShareFileConsumed: (File) -> Unit
) {
    val context = LocalContext.current
    val photo = detail.photo
    val needsProxyAction = photo.needsProxy ||
        (photo.isVideo && detail.videoFile == null && photo.hasVideoProxy != true && !detail.isLoadingVideo)
    val isOriginalProtected = photo.isProtectedOriginal || detail.isLocallyProtected
    var showDeleteConfirm by remember(photo.hash) { mutableStateOf(false) }

    LaunchedEffect(detail.shareFileReady) {
        val f = detail.shareFileReady ?: return@LaunchedEffect
        onShareFileConsumed(f)
    }

    if (showDeleteConfirm) {
        val masterStr = Formatter.formatFileSize(context, photo.size)
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            title = { Text("Delete from Server?", fontWeight = FontWeight.Bold) },
            text = {
                Text(
                    "Permanently delete ${photo.originalName} (~$masterStr) and its compressed proxies from your PhotoHub server? This cannot be undone."
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
                    Text("Delete")
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) {
                    Text("Cancel")
                }
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

        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(LightboxBg)
                .statusBarsPadding()
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            // Cinematic Lightbox Header (matches webpage `.lightbox-top`)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
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
                        text = "$dateStr · Original $masterStr",
                        style = MaterialTheme.typography.labelSmall,
                        color = LightboxMuted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
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

            // Media Stage
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center
            ) {
                val videoFile = detail.videoFile
                when {
                    videoFile != null && videoFile.exists() -> {
                        VideoProxyPlayerView(videoFile = videoFile)
                    }
                    detail.previewBitmap != null -> {
                        Box(contentAlignment = Alignment.BottomCenter) {
                            Image(
                                bitmap = detail.previewBitmap.asImageBitmap(),
                                contentDescription = photo.originalName,
                                contentScale = ContentScale.Fit,
                                modifier = Modifier
                                    .fillMaxSize()
                                    .clip(RoundedCornerShape(14.dp))
                            )
                            if (detail.isLoadingVideo) {
                                Surface(
                                    shape = CircleShape,
                                    color = LightboxCardBg.copy(alpha = 0.92f),
                                    border = BorderStroke(1.dp, LightboxBorder),
                                    modifier = Modifier.padding(bottom = 12.dp)
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
                    }
                    photo.isVideo && photo.needsProxy -> {
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

            // Frosted Dark Bottom Sheet (matches webpage `.lightbox-bottom`)
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

                    // Scrollable Pill Badges Row
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
                        if (isOriginalProtected) {
                            LightboxBadgePill(
                                text = "Protected Original",
                                color = PhotoHubMint,
                                icon = Icons.Rounded.VerifiedUser
                            )
                        }
                        LightboxBadgePill(
                            text = if (photo.needsProxy) "Needs Proxy" else (smallStr?.let { "Proxy $it" } ?: "Proxy Ready"),
                            color = if (photo.needsProxy) PhotoHubAmber else PhotoHubMint
                        )
                        Surface(
                            shape = CircleShape,
                            color = Color.White.copy(alpha = 0.08f)
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                Icon(
                                    Icons.Rounded.Verified,
                                    contentDescription = null,
                                    tint = PhotoHubMint,
                                    modifier = Modifier.size(13.dp)
                                )
                                Text(
                                    "SHA-256 ${photo.hash.take(8)}…",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = LightboxMuted
                                )
                            }
                        }
                    }

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

                    GradientPrimaryButton(
                        text = "Share Original",
                        icon = Icons.Rounded.IosShare,
                        onClick = onShareOriginal,
                        enabled = !detail.isBusy,
                        modifier = Modifier.fillMaxWidth()
                    )

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
                                    contentDescription = "Delete from Server",
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
private fun VideoProxyPlayerView(videoFile: File) {
    val context = LocalContext.current
    val player = remember(videoFile.absolutePath) {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(Uri.fromFile(videoFile)))
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
