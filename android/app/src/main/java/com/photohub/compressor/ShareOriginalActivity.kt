package com.photohub.compressor

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.text.format.Formatter
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.IntentCompat
import com.photohub.compressor.data.AppSettings
import com.photohub.compressor.media.*
import com.photohub.compressor.network.ApiHttpException
import com.photohub.compressor.network.PhotoHubApiClient
import com.photohub.compressor.sync.LocalProxyTracker
import com.photohub.compressor.ui.theme.PhotoHubBlue
import com.photohub.compressor.ui.theme.PhotoHubGreen
import com.photohub.compressor.ui.theme.PhotoHubOrange
import com.photohub.compressor.ui.theme.PhotoHubRed
import com.photohub.compressor.ui.theme.PhotoHubTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

private sealed interface ShareOriginalUiState {
    data object NeedsSignIn : ShareOriginalUiState
    data class Fetching(
        val currentIndex: Int,
        val totalCount: Int,
        val stageText: String,
        val currentFilename: String?,
        val downloadedBytes: Long,
        val totalBytes: Long?
    ) : ShareOriginalUiState

    data class Ready(
        val items: List<FetchedOriginalResult>,
        val unresolvedCount: Int,
        val savedMessage: String? = null,
        val isSavingToGallery: Boolean = false
    ) : ShareOriginalUiState

    data class Failed(
        val message: String,
        val canRetry: Boolean
    ) : ShareOriginalUiState
}

/**
 * Exported Share Sheet target for Android Gallery (Google Photos, Samsung Gallery, Files, etc.).
 * Automatically matches compressed proxies to server masters, fetches full-resolution originals,
 * and opens the system share chooser with the full-resolution media.
 */
class ShareOriginalActivity : ComponentActivity() {
    private val incomingUrisState = mutableStateOf<List<Uri>>(emptyList())
    private val requestNonce = mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        updateIncomingUris(intent)

        setContent {
            PhotoHubTheme {
                val uris = incomingUrisState.value
                val nonce = requestNonce.intValue
                ShareOriginalScreen(
                    incomingUris = uris,
                    nonce = nonce,
                    onOpenMainApp = {
                        startActivity(
                            Intent(this, MainActivity::class.java).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                            }
                        )
                        finish()
                    },
                    onFinish = { finish() }
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        updateIncomingUris(intent)
    }

    private fun updateIncomingUris(intent: Intent?) {
        val extracted = extractSharedUris(intent)
        incomingUrisState.value = extracted
        requestNonce.intValue += 1
    }

    private fun extractSharedUris(intent: Intent?): List<Uri> {
        intent ?: return emptyList()
        val uris = LinkedHashSet<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.let {
                    uris.add(it)
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                    ?.forEach { uris.add(it) }
            }
        }
        val clip = intent.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) {
                clip.getItemAt(i)?.uri?.let { uris.add(it) }
            }
        }
        return uris.toList()
    }
}

@Composable
private fun ShareOriginalScreen(
    incomingUris: List<Uri>,
    nonce: Int,
    onOpenMainApp: () -> Unit,
    onFinish: () -> Unit
) {
    val context = LocalContext.current
    val settings = remember { AppSettings.getInstance(context) }
    val scope = rememberCoroutineScope()
    val excludeSelf = remember(context) {
        arrayOf(ComponentName(context, ShareOriginalActivity::class.java))
    }

    val uiStateFlow = remember {
        MutableStateFlow<ShareOriginalUiState>(
            ShareOriginalUiState.Fetching(1, incomingUris.size.coerceAtLeast(1), "Starting…", null, 0L, null)
        )
    }
    val uiState by uiStateFlow.collectAsState()
    var retryCounter by remember { mutableIntStateOf(0) }
    var autoLaunchedChooserForNonce by remember { mutableIntStateOf(-1) }

    val chooserLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) {
        // Keep fetched card visible so user can Save Original to Gallery, Share Again, or tap Done.
    }

    LaunchedEffect(nonce, retryCounter, incomingUris) {
        val currentSettings = settings.current
        if (!currentSettings.isSignedIn || currentSettings.normalizedBaseUrl == null) {
            uiStateFlow.value = ShareOriginalUiState.NeedsSignIn
            return@LaunchedEffect
        }
        if (incomingUris.isEmpty()) {
            uiStateFlow.value = ShareOriginalUiState.Failed(
                message = "No shared photo or video was provided.",
                canRetry = false
            )
            return@LaunchedEffect
        }
        uiStateFlow.value = ShareOriginalUiState.Fetching(
            currentIndex = 1,
            totalCount = incomingUris.size,
            stageText = if (incomingUris.size > 1) "Preparing ${incomingUris.size} items in parallel…" else "Matching compressed item…",
            currentFilename = null,
            downloadedBytes = 0L,
            totalBytes = null
        )

        val resolver = OriginalMediaResolver(context, settings)
        val warmClient = PhotoHubApiClient(context, settings)
        val completedCount = AtomicInteger(0)
        val unresolvedCount = AtomicInteger(0)
        val totalDownBytes = AtomicLong(0L)
        val perUriDownloaded = java.util.concurrent.ConcurrentHashMap<Int, Long>()
        val authExpired = java.util.concurrent.atomic.AtomicBoolean(false)
        val firstErrorMessage = java.util.concurrent.atomic.AtomicReference<String?>(null)

        val semaphore = Semaphore(3)
        val orderedResults = coroutineScope {
            val warmJob = launch { warmClient.warmConnectionIfNeeded() }
            val tasks = incomingUris.mapIndexed { index, uri ->
                async {
                    semaphore.withPermit {
                        if (authExpired.get()) return@withPermit null
                        val hintName = resolver.queryDisplayName(uri)
                        try {
                            val res = resolver.resolveAndFetchOriginal(
                                uri = uri,
                                onStage = { stage ->
                                    if (incomingUris.size == 1) {
                                        uiStateFlow.update { cur ->
                                            val prev = cur as? ShareOriginalUiState.Fetching
                                            ShareOriginalUiState.Fetching(
                                                currentIndex = 1,
                                                totalCount = 1,
                                                stageText = stage,
                                                currentFilename = hintName ?: prev?.currentFilename,
                                                downloadedBytes = prev?.downloadedBytes ?: 0L,
                                                totalBytes = prev?.totalBytes
                                            )
                                        }
                                    }
                                },
                                onDownloadProgress = { down, total ->
                                    if (incomingUris.size == 1) {
                                        uiStateFlow.value = ShareOriginalUiState.Fetching(
                                            currentIndex = 1,
                                            totalCount = 1,
                                            stageText = "Auto-fetching original from server…",
                                            currentFilename = hintName,
                                            downloadedBytes = down,
                                            totalBytes = total
                                        )
                                    } else {
                                        val prevDown = perUriDownloaded.put(index, down) ?: 0L
                                        val agg = totalDownBytes.addAndGet(down - prevDown).coerceAtLeast(0L)
                                        val doneNow = completedCount.get()
                                        uiStateFlow.value = ShareOriginalUiState.Fetching(
                                            currentIndex = (doneNow + 1).coerceAtMost(incomingUris.size),
                                            totalCount = incomingUris.size,
                                            stageText = "Auto-fetching ${incomingUris.size} originals in parallel…",
                                            currentFilename = hintName,
                                            downloadedBytes = agg,
                                            totalBytes = null
                                        )
                                    }
                                }
                            )
                            val done = completedCount.incrementAndGet()
                            if (incomingUris.size > 1) {
                                uiStateFlow.value = ShareOriginalUiState.Fetching(
                                    currentIndex = done,
                                    totalCount = incomingUris.size,
                                    stageText = "Fetched $done of ${incomingUris.size} originals…",
                                    currentFilename = res.originalName,
                                    downloadedBytes = totalDownBytes.get(),
                                    totalBytes = null
                                )
                            }
                            res
                        } catch (cancel: CancellationException) {
                            throw cancel
                        } catch (http: ApiHttpException) {
                            if (http.statusCode == 401) {
                                authExpired.set(true)
                            }
                            unresolvedCount.incrementAndGet()
                            firstErrorMessage.compareAndSet(null, http.message)
                            null
                        } catch (err: Exception) {
                            unresolvedCount.incrementAndGet()
                            firstErrorMessage.compareAndSet(
                                null,
                                err.localizedMessage ?: "Failed to fetch original from server."
                            )
                            null
                        }
                    }
                }
            }
            val list = tasks.awaitAll()
            warmJob.cancel()
            list
        }

        if (authExpired.get()) {
            settings.signOut()
            uiStateFlow.value = ShareOriginalUiState.NeedsSignIn
            return@LaunchedEffect
        }

        val fetched = orderedResults.filterNotNull()
        val unresolved = unresolvedCount.get()
        val lastErrorMessage = firstErrorMessage.get()

        if (fetched.isEmpty()) {
            uiStateFlow.value = ShareOriginalUiState.Failed(
                message = lastErrorMessage
                    ?: "None of the selected gallery items are linked to a backed-up PhotoHub original.",
                canRetry = true
            )
            return@LaunchedEffect
        }

        uiStateFlow.value = ShareOriginalUiState.Ready(
            items = fetched,
            unresolvedCount = unresolved
        )

        if (autoLaunchedChooserForNonce != nonce) {
            autoLaunchedChooserForNonce = nonce
            val chooser = ShareUtils.buildShareChooserIntent(
                context = context,
                files = fetched.map { it.file },
                title = "Share Original",
                excludeComponents = excludeSelf
            )
            chooserLauncher.launch(chooser)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onFinish
            ),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(
            shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
            tonalElevation = 8.dp,
            shadowElevation = 12.dp,
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = {}
                )
        ) {
            Column(
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 18.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Surface(
                        shape = CircleShape,
                        color = PhotoHubBlue.copy(alpha = 0.14f),
                        modifier = Modifier.size(36.dp)
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(
                                imageVector = Icons.Rounded.CloudDownload,
                                contentDescription = null,
                                tint = PhotoHubBlue,
                                modifier = Modifier.size(20.dp)
                            )
                        }
                    }
                    Spacer(modifier = Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "photoHub · Full-Resolution Original",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            text = "Auto-fetch & share from server",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    IconButton(onClick = onFinish) {
                        Icon(Icons.Rounded.Close, contentDescription = "Close")
                    }
                }

                when (val state = uiState) {
                    is ShareOriginalUiState.NeedsSignIn -> {
                        Text(
                            text = "Sign in to your photoHub account before sharing full-resolution originals from Android Gallery.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                            OutlinedButton(onClick = onFinish, modifier = Modifier.weight(1f)) {
                                Text("Close")
                            }
                            Button(onClick = onOpenMainApp, modifier = Modifier.weight(1f)) {
                                Text("Open photoHub")
                            }
                        }
                    }

                    is ShareOriginalUiState.Fetching -> {
                        if (state.totalCount > 1) {
                            Text(
                                text = "Item ${state.currentIndex} of ${state.totalCount}",
                                style = MaterialTheme.typography.labelMedium,
                                color = PhotoHubBlue,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                        if (!state.currentFilename.isNullOrBlank()) {
                            Text(
                                text = state.currentFilename,
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        Text(
                            text = state.stageText,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )

                        val total = state.totalBytes
                        if (total != null && total > 0L) {
                            val fraction = (state.downloadedBytes.toFloat() / total.toFloat()).coerceIn(0f, 1f)
                            LinearProgressIndicator(
                                progress = { fraction },
                                modifier = Modifier.fillMaxWidth()
                            )
                            Text(
                                text = "${Formatter.formatFileSize(context, state.downloadedBytes)} / ${Formatter.formatFileSize(context, total)}",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        } else {
                            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                            if (state.downloadedBytes > 0L) {
                                Text(
                                    text = "${Formatter.formatFileSize(context, state.downloadedBytes)} fetched…",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        OutlinedButton(onClick = onFinish, modifier = Modifier.fillMaxWidth()) {
                            Text("Cancel")
                        }
                    }

                    is ShareOriginalUiState.Ready -> {
                        val totalSize = state.items.sumOf { it.sizeBytes }
                        val sizeText = Formatter.formatFileSize(context, totalSize)
                        val count = state.items.size
                        val summaryNames = if (count == 1) {
                            state.items.first().originalName
                        } else {
                            "$count full-resolution originals"
                        }

                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = PhotoHubGreen.copy(alpha = 0.12f),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                modifier = Modifier.padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(Icons.Rounded.VerifiedUser, null, tint = PhotoHubGreen, modifier = Modifier.size(20.dp))
                                Spacer(modifier = Modifier.width(10.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = summaryNames,
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    val cachedNote = if (state.items.all { it.fromCache }) " · Ready from cache" else " · Fetched from server"
                                    Text(
                                        text = "$sizeText original$cachedNote",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        }

                        if (state.unresolvedCount > 0) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Rounded.Warning, null, tint = PhotoHubOrange, modifier = Modifier.size(16.dp))
                                Spacer(modifier = Modifier.width(6.dp))
                                Text(
                                    text = "${state.unresolvedCount} selected item(s) had no backed-up original on the server.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        state.savedMessage?.let { msg ->
                            Text(
                                text = msg,
                                style = MaterialTheme.typography.bodySmall,
                                color = PhotoHubGreen
                            )
                        }

                        Button(
                            onClick = {
                                val chooser = ShareUtils.buildShareChooserIntent(
                                    context = context,
                                    files = state.items.map { it.file },
                                    title = "Share Original",
                                    excludeComponents = excludeSelf
                                )
                                chooserLauncher.launch(chooser)
                            },
                            enabled = !state.isSavingToGallery,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(Icons.Rounded.IosShare, null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(if (count == 1) "Share Original" else "Share $count Originals")
                        }

                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                            OutlinedButton(
                                onClick = {
                                    if (state.isSavingToGallery) return@OutlinedButton
                                    uiStateFlow.value = state.copy(isSavingToGallery = true, savedMessage = null)
                                    scope.launch {
                                        val mediaService = MediaLibraryService(context)
                                        if (!mediaService.canWriteGallery()) {
                                            uiStateFlow.value = state.copy(
                                                isSavingToGallery = false,
                                                savedMessage = "Photos & Videos permission needed in photoHub."
                                            )
                                            return@launch
                                        }
                                        val tracker = LocalProxyTracker.getInstance(context)
                                        val client = PhotoHubApiClient(context, settings)
                                        var savedCount = 0
                                        var firstError: String? = null
                                        for (item in state.items) {
                                            try {
                                                val isVideo = item.mimeType.startsWith("video/")
                                                val savedId = mediaService.saveRestoredOriginalToGallery(
                                                    file = item.file,
                                                    isVideo = isVideo,
                                                    originalFilename = item.originalName,
                                                    creationDateMs = null
                                                )
                                                tracker.markRestoredOriginal(savedId, item.masterHash)
                                                runCatching { client.setOriginalProtected(item.masterHash, true) }
                                                savedCount++
                                            } catch (err: Exception) {
                                                if (firstError == null) firstError = err.localizedMessage
                                            }
                                        }
                                        uiStateFlow.value = state.copy(
                                            isSavingToGallery = false,
                                            savedMessage = if (savedCount > 0) {
                                                "Saved $savedCount original(s) to Gallery & protected from re-proxying."
                                            } else {
                                                "Save failed: ${firstError ?: "Unknown error"}"
                                            }
                                        )
                                    }
                                },
                                enabled = !state.isSavingToGallery,
                                modifier = Modifier.weight(1f)
                            ) {
                                if (state.isSavingToGallery) {
                                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                } else {
                                    Icon(Icons.Rounded.ArrowCircleDown, null, modifier = Modifier.size(18.dp))
                                }
                                Spacer(modifier = Modifier.width(6.dp))
                                Text("Save to Gallery")
                            }

                            TextButton(
                                onClick = onFinish,
                                modifier = Modifier.weight(0.6f)
                            ) {
                                Text("Done")
                            }
                        }
                    }

                    is ShareOriginalUiState.Failed -> {
                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = PhotoHubRed.copy(alpha = 0.10f),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.Top) {
                                Icon(Icons.Rounded.ErrorOutline, null, tint = PhotoHubRed, modifier = Modifier.size(20.dp))
                                Spacer(modifier = Modifier.width(10.dp))
                                Text(
                                    text = state.message,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurface
                                )
                            }
                        }

                        if (incomingUris.isNotEmpty()) {
                            OutlinedButton(
                                onClick = {
                                    val fallbackChooser = ShareUtils.buildPassThroughShareChooserIntent(
                                        context = context,
                                        uris = incomingUris,
                                        title = "Share Gallery Copy",
                                        excludeComponents = excludeSelf
                                    )
                                    chooserLauncher.launch(fallbackChooser)
                                },
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Icon(Icons.Rounded.Share, null, modifier = Modifier.size(18.dp))
                                Spacer(modifier = Modifier.width(8.dp))
                                Text("Share Selected Gallery Copy Instead")
                            }
                        }

                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                            if (state.canRetry) {
                                Button(
                                    onClick = { retryCounter += 1 },
                                    modifier = Modifier.weight(1f)
                                ) {
                                    Text("Retry")
                                }
                            } else {
                                Button(
                                    onClick = onOpenMainApp,
                                    modifier = Modifier.weight(1f)
                                ) {
                                    Text("Open photoHub")
                                }
                            }
                            TextButton(onClick = onFinish, modifier = Modifier.weight(1f)) {
                                Text("Close")
                            }
                        }
                    }
                }
            }
        }
    }
}
