package com.photohub.compressor.ui.screens

import android.net.Uri
import android.text.format.Formatter
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
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
import com.photohub.compressor.ui.theme.PhotoHubBlue
import com.photohub.compressor.ui.theme.PhotoHubGreen
import com.photohub.compressor.ui.theme.PhotoHubOrange
import com.photohub.compressor.viewmodel.PhotoDetailUiState
import java.io.File
import java.text.DateFormat
import java.util.Date

@OptIn(ExperimentalMaterial3Api::class)
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
            title = { Text("Delete from Server?") },
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
                        containerColor = MaterialTheme.colorScheme.error,
                        contentColor = MaterialTheme.colorScheme.onError
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
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = {
                        Text(photo.originalName, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    },
                    navigationIcon = {
                        TextButton(onClick = onDismiss) { Text("Close") }
                    }
                )
            }
        ) { padding ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp),
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
                                    modifier = Modifier.fillMaxSize()
                                )
                                if (detail.isLoadingVideo) {
                                    Row(
                                        modifier = Modifier
                                            .padding(bottom = 12.dp)
                                            .clip(CircleShape)
                                            .background(Color.Black.copy(alpha = 0.72f))
                                            .padding(horizontal = 12.dp, vertical = 6.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                                    ) {
                                        CircularProgressIndicator(modifier = Modifier.size(14.dp), color = Color.White, strokeWidth = 2.dp)
                                        Text("Loading compressed video proxy…", style = MaterialTheme.typography.labelSmall, color = Color.White)
                                    }
                                }
                            }
                        }
                        photo.isVideo && photo.needsProxy -> {
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Icon(Icons.Rounded.VideoLibrary, null, modifier = Modifier.size(56.dp), tint = PhotoHubOrange)
                                Text("No compressed video proxy yet", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                                Text(
                                    "Tap Create Video Proxy below to generate a small playable MP4 & thumbnail.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    textAlign = TextAlign.Center
                                )
                            }
                        }
                        else -> {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                CircularProgressIndicator()
                                Spacer(modifier = Modifier.height(8.dp))
                                Text("Loading compressed proxy…")
                            }
                        }
                    }
                }

                detail.videoUnavailableNote?.let { note ->
                    Text(
                        text = note,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
                    )
                }

                if (detail.isBusy && detail.busyLabel.isNotEmpty()) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(4.dp),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(detail.busyLabel, style = MaterialTheme.typography.bodySmall)
                    }
                }

                detail.saveMessage?.let { msg ->
                    Text(
                        text = msg,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)
                    )
                }

                Surface(
                    shape = RoundedCornerShape(16.dp),
                    tonalElevation = 2.dp,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 10.dp)
                ) {
                    Column(
                        modifier = Modifier.padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        val previewBytes = detail.videoFile?.takeIf { it.exists() }?.length()
                            ?: photo.videoProxySize
                            ?: photo.proxySize
                        val smallStr = previewBytes?.let { Formatter.formatFileSize(context, it) }
                            ?: if (photo.needsProxy) "No Proxy" else "Proxy"
                        val masterStr = Formatter.formatFileSize(context, photo.size)

                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                val title = photo.parsedCreationDateMs?.let {
                                    DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it))
                                } ?: photo.originalName
                                Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text("$smallStr proxy · $masterStr original", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Icon(Icons.Rounded.VerifiedUser, null, tint = PhotoHubGreen, modifier = Modifier.size(14.dp))
                                    Text("SHA-256 verified (${photo.hash.take(10)}…)", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }

                            if (isOriginalProtected) {
                                Surface(shape = CircleShape, color = PhotoHubBlue.copy(alpha = 0.16f)) {
                                    Text(
                                        "Original Kept",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = PhotoHubBlue,
                                        fontWeight = FontWeight.SemiBold,
                                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                                    )
                                }
                                Spacer(modifier = Modifier.width(6.dp))
                            }

                            val badgeColor = if (photo.needsProxy) PhotoHubOrange else PhotoHubGreen
                            Surface(shape = CircleShape, color = badgeColor.copy(alpha = 0.16f)) {
                                Text(
                                    text = if (photo.needsProxy) "Needs Proxy" else "Proxy Ready",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = badgeColor,
                                    fontWeight = FontWeight.SemiBold,
                                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                                )
                            }
                        }

                        if (isOriginalProtected) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(PhotoHubBlue.copy(alpha = 0.08f))
                                    .padding(8.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(Icons.Rounded.Lock, null, tint = PhotoHubBlue, modifier = Modifier.size(18.dp))
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(
                                    "Restored original is protected from auto re-compression.",
                                    style = MaterialTheme.typography.labelSmall,
                                    modifier = Modifier.weight(1f)
                                )
                                TextButton(
                                    onClick = { onToggleProtection(false) },
                                    enabled = !detail.isBusy
                                ) {
                                    Text("Allow Re-Proxy", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold)
                                }
                            }
                        }

                        if (needsProxyAction) {
                            OutlinedButton(
                                onClick = onCreateProxy,
                                enabled = !detail.isBusy,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Icon(Icons.Rounded.AutoFixHigh, null, tint = PhotoHubOrange)
                                Spacer(modifier = Modifier.width(6.dp))
                                Text(if (photo.isVideo) "Create Video Proxy" else "Create Proxy", color = PhotoHubOrange)
                            }
                        }

                        Button(
                            onClick = onShareOriginal,
                            enabled = !detail.isBusy,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(Icons.Rounded.IosShare, null)
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("Share Original")
                        }

                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                            OutlinedButton(
                                onClick = onSaveProxy,
                                enabled = !detail.isBusy && (photo.isVideo || detail.previewBitmap != null),
                                modifier = Modifier.weight(1f)
                            ) {
                                Icon(if (photo.isVideo) Icons.Rounded.Videocam else Icons.Rounded.Photo, null, modifier = Modifier.size(18.dp))
                                Spacer(modifier = Modifier.width(6.dp))
                                Text("Save Proxy")
                            }
                            OutlinedButton(
                                onClick = onRestoreOriginal,
                                enabled = !detail.isBusy,
                                modifier = Modifier.weight(1f)
                            ) {
                                Icon(Icons.Rounded.ArrowCircleDown, null, modifier = Modifier.size(18.dp))
                                Spacer(modifier = Modifier.width(6.dp))
                                Text("Restore")
                            }
                        }

                        OutlinedButton(
                            onClick = { showDeleteConfirm = true },
                            enabled = !detail.isBusy,
                            colors = ButtonDefaults.outlinedButtonColors(
                                contentColor = MaterialTheme.colorScheme.error
                            ),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(Icons.Rounded.DeleteOutline, null, modifier = Modifier.size(18.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("Delete from Server")
                        }
                    }
                }
            }
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
            .clip(RoundedCornerShape(12.dp))
    )
}
