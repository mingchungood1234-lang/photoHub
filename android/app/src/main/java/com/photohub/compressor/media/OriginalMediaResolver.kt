package com.photohub.compressor.media

import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import com.photohub.compressor.data.AppSettings
import com.photohub.compressor.data.ServerPhoto
import com.photohub.compressor.network.PhotoHubApiClient
import com.photohub.compressor.sync.LocalProxyStore
import com.photohub.compressor.sync.LocalProxyTracker
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

data class ResolvedMasterMedia(
    val masterHash: String,
    val originalName: String?,
    val expectedSizeBytes: Long?,
    val sourceDisplayName: String?
)

data class FetchedOriginalResult(
    val masterHash: String,
    val file: File,
    val originalName: String,
    val mimeType: String,
    val sizeBytes: Long,
    val fromCache: Boolean
)

/**
 * Bounded LRU cache with Single-Flight request coalescing for auto-fetched originals.
 * Speculative prefetches and explicit Share/Restore taps coalesce onto the same in-flight transfer.
 */
object OriginalDownloadCache {
    private const val DIR_NAME = "photohub_originals_cache"
    private const val SHARE_DIR_PREFIX = "photohub_share_"
    private const val MAX_CACHE_BYTES = 400L * 1024L * 1024L
    private const val MAX_TEMP_AGE_MS = 24L * 60L * 60L * 1000L

    private class ActiveFetch(
        val key: String,
        val deferred: CompletableDeferred<File>,
        val listeners: CopyOnWriteArrayList<(Long, Long?) -> Unit> = CopyOnWriteArrayList(),
        val lastDownloaded: AtomicLong = AtomicLong(0L),
        val lastTotal: AtomicReference<Long?> = AtomicReference(null),
        val waiters: AtomicInteger = AtomicInteger(0),
        @Volatile var job: Job? = null
    )

    private val cacheScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val inFlight = ConcurrentHashMap<String, ActiveFetch>()

    private fun rootDir(context: Context): File =
        File(context.cacheDir, DIR_NAME).apply { mkdirs() }

    private fun hashDir(context: Context, masterHash: String): File =
        File(rootDir(context), masterHash.trim().lowercase(Locale.ROOT).take(24).ifEmpty { "unknown" })

    fun getCachedOriginal(
        context: Context,
        masterHash: String,
        preferredFilename: String? = null,
        expectedSizeBytes: Long? = null
    ): File? {
        val dir = hashDir(context, masterHash)
        if (!dir.exists() || !dir.isDirectory) return null

        val preferred = preferredFilename?.let { File(it).name }?.takeIf { it.isNotBlank() }
        val candidate = if (preferred != null) {
            File(dir, preferred).takeIf { it.isFile && it.length() > 0L }
        } else {
            null
        } ?: dir.listFiles()
            ?.firstOrNull { it.isFile && !it.name.startsWith(".part_") && it.length() > 0L }

        val valid = candidate?.takeIf { file ->
            expectedSizeBytes == null || expectedSizeBytes <= 0L || file.length() == expectedSizeBytes
        } ?: return null

        runCatching { valid.setLastModified(System.currentTimeMillis()) }
        return valid
    }

    suspend fun getOrFetchOriginal(
        context: Context,
        apiClient: PhotoHubApiClient,
        masterHash: String,
        preferredFilename: String? = null,
        expectedSizeBytes: Long? = null,
        isVideo: Boolean = false,
        onProgress: ((downloadedBytes: Long, totalBytes: Long?) -> Unit)? = null
    ): Pair<File, Boolean> {
        pruneStaleCache(context)

        getCachedOriginal(context, masterHash, preferredFilename, expectedSizeBytes)?.let { cached ->
            onProgress?.invoke(cached.length(), cached.length())
            return cached to true
        }

        val key = masterHash.trim().lowercase(Locale.ROOT)
        var created = false
        val entry = inFlight.computeIfAbsent(key) {
            created = true
            ActiveFetch(key = key, deferred = CompletableDeferred())
        }

        if (created) {
            val destDir = hashDir(context, key)
            entry.job = cacheScope.launch {
                try {
                    val result = apiClient.downloadMasterToDirectory(
                        hash = masterHash,
                        destDir = destDir,
                        preferredFilename = preferredFilename,
                        expectedSizeBytes = expectedSizeBytes,
                        isVideo = isVideo,
                        onProgress = { down, total ->
                            entry.lastDownloaded.set(down)
                            if (total != null) entry.lastTotal.set(total)
                            for (listener in entry.listeners) {
                                listener(down, total)
                            }
                        }
                    )
                    runCatching { result.file.setLastModified(System.currentTimeMillis()) }
                    enforceSizeBudget(context, protectedFile = result.file)
                    entry.deferred.complete(result.file)
                } catch (t: Throwable) {
                    entry.deferred.completeExceptionally(t)
                } finally {
                    inFlight.remove(key, entry)
                }
            }
        }

        entry.waiters.incrementAndGet()
        if (onProgress != null) {
            entry.listeners.add(onProgress)
            val prevDown = entry.lastDownloaded.get()
            val prevTotal = entry.lastTotal.get()
            if (prevDown > 0L || prevTotal != null) {
                onProgress(prevDown, prevTotal)
            }
        }

        return try {
            val file = entry.deferred.await()
            file to false
        } finally {
            if (onProgress != null) entry.listeners.remove(onProgress)
            if (entry.waiters.decrementAndGet() == 0 && !entry.deferred.isCompleted) {
                inFlight.remove(key, entry)
                entry.job?.cancel()
            }
        }
    }

    fun pruneStaleCache(context: Context, nowMs: Long = System.currentTimeMillis()) {
        runCatching {
            context.cacheDir.listFiles()?.forEach { child ->
                if (child.isDirectory && child.name.startsWith(SHARE_DIR_PREFIX)) {
                    if (nowMs - child.lastModified() > MAX_TEMP_AGE_MS) {
                        child.deleteRecursively()
                    }
                }
            }
        }
    }

    fun removeCachedOriginals(context: Context, hashes: Collection<String>) {
        for (raw in hashes) {
            val key = raw.trim().lowercase(Locale.ROOT)
            if (key.isEmpty()) continue
            inFlight.remove(key)?.let { entry ->
                entry.job?.cancel()
                entry.deferred.cancel()
            }
            runCatching { hashDir(context, key).deleteRecursively() }
        }
    }

    private fun enforceSizeBudget(context: Context, protectedFile: File?) {
        val root = rootDir(context)
        val files = root.walkTopDown()
            .filter { it.isFile && !it.name.startsWith(".part_") }
            .sortedBy { it.lastModified() }
            .toMutableList()
        var total = files.sumOf { it.length() }
        for (file in files) {
            if (total <= MAX_CACHE_BYTES) break
            if (protectedFile != null && file.absolutePath == protectedFile.absolutePath) continue
            val len = file.length()
            if (file.delete()) {
                total -= len
                file.parentFile?.takeIf { it.listFiles().isNullOrEmpty() }?.delete()
            }
        }
    }
}

/**
 * Resolves any Gallery / Share Sheet / Photo Picker URI to its PhotoHub server master hash
 * across all local & server signals and auto-fetches the full-resolution original.
 */
class OriginalMediaResolver(
    private val context: Context,
    private val settings: AppSettings = AppSettings.getInstance(context)
) {
    private val tracker = LocalProxyTracker.getInstance(context)
    private val store = LocalProxyStore.getInstance(context)

    fun queryDisplayName(uri: Uri): String? {
        runCatching {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) {
                        val name = cursor.getString(idx)?.trim()
                        if (!name.isNullOrEmpty()) return name
                    }
                }
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
    }

    suspend fun resolveUriToMaster(
        uri: Uri,
        onStage: ((String) -> Unit)? = null
    ): ResolvedMasterMedia? = withContext(Dispatchers.IO) {
        val cur = settings.current
        val client = PhotoHubApiClient(context, settings)
        val cachedPhotos = store.cachedPhotos(cur.normalizedBaseUrl, cur.apiKeyCacheScope)
        val displayName = queryDisplayName(uri)
        val mimeHint = context.contentResolver.getType(uri)?.lowercase(Locale.ROOT).orEmpty()

        onStage?.invoke("Matching compressed item…")

        // 1. Direct tracker lookup by shared URI and canonical MediaStore URI (handles Picker & Gallery aliases).
        val trackerMatch = lookupTrackerWithMediaStoreAlias(uri)
        if (trackerMatch != null) {
            val cachedMatch = cachedPhotos.firstOrNull {
                it.hash.equals(trackerMatch.masterHash, ignoreCase = true)
            }
            return@withContext ResolvedMasterMedia(
                masterHash = trackerMatch.masterHash,
                originalName = trackerMatch.originalName ?: cachedMatch?.originalName ?: displayName,
                expectedSizeBytes = cachedMatch?.size,
                sourceDisplayName = displayName
            )
        }

        // 2. Embedded EXIF (images) or QuickTime/MP4 container marker (videos): PhotoHubProxy:<masterHash>
        var shortPrefix = displayName?.let { ProxyGenerator.extractMasterHashPrefix(it) }
        val isLikelyVideo = mimeHint.startsWith("video/") ||
            (displayName?.substringAfterLast('.', "")?.lowercase(Locale.ROOT)
                in setOf("mp4", "mov", "m4v", "mkv", "webm", "3gp", "avi"))

        val embeddedMarker = if (!isLikelyVideo) {
            runCatching {
                context.contentResolver.openInputStream(uri)?.use { stream ->
                    ProxyGenerator.extractEmbeddedProxyMasterHashFromStream(stream)
                }
            }.getOrNull()
        } else {
            GalleryProxyDetector.extractVideoMarkerFromUri(context, uri)
        }

        if (embeddedMarker != null) {
            if (ProxyGenerator.isFullSha256Hex(embeddedMarker)) {
                val norm = embeddedMarker.lowercase(Locale.ROOT)
                val cached = cachedPhotos.firstOrNull { it.hash.equals(norm, ignoreCase = true) }
                return@withContext ResolvedMasterMedia(
                    masterHash = cached?.hash ?: norm,
                    originalName = cached?.originalName,
                    expectedSizeBytes = cached?.size,
                    sourceDisplayName = displayName
                )
            } else if (shortPrefix == null) {
                shortPrefix = embeddedMarker
            }
        }

        // 3. Filename prefix PHOTOHUB_PROXY_<prefix16> -> resolve full 64-char masterHash via cache or server.
        if (shortPrefix != null) {
            val resolvedFromPrefix = resolveMasterByPrefix(shortPrefix, cachedPhotos, client)
            if (resolvedFromPrefix != null) {
                return@withContext ResolvedMasterMedia(
                    masterHash = resolvedFromPrefix.hash,
                    originalName = resolvedFromPrefix.originalName,
                    expectedSizeBytes = resolvedFromPrefix.size,
                    sourceDisplayName = displayName
                )
            }
        }

        // 4. Stream SHA-256 -> local proxy hash tracker -> server /api/check/:sha (matches originals & proxies).
        onStage?.invoke("Checking server backup index…")
        val streamSha = computeUriSha256(uri)
        val trackedMaster = tracker.masterHashForProxySha256(streamSha)
        if (trackedMaster != null) {
            val cached = cachedPhotos.firstOrNull { it.hash.equals(trackedMaster, ignoreCase = true) }
            return@withContext ResolvedMasterMedia(
                masterHash = trackedMaster,
                originalName = cached?.originalName ?: displayName,
                expectedSizeBytes = cached?.size,
                sourceDisplayName = displayName
            )
        }

        val check = client.checkHash(streamSha)
        if (check.exists) {
            val resolvedHash = check.masterHash ?: streamSha
            val cached = cachedPhotos.firstOrNull { it.hash.equals(resolvedHash, ignoreCase = true) }
            val resolvedName = check.originalName
                ?: cached?.originalName
                ?: resolveMasterByPrefix(resolvedHash.take(16), cachedPhotos, client)?.originalName
            return@withContext ResolvedMasterMedia(
                masterHash = resolvedHash,
                originalName = resolvedName,
                expectedSizeBytes = check.size ?: cached?.size,
                sourceDisplayName = displayName
            )
        }

        null
    }

    suspend fun resolveAndFetchOriginal(
        uri: Uri,
        onStage: ((String) -> Unit)? = null,
        onDownloadProgress: ((Long, Long?) -> Unit)? = null
    ): FetchedOriginalResult {
        val resolved = resolveUriToMaster(uri, onStage)
            ?: throw IOException(
                "This item is not linked to an uploaded PhotoHub master on the server. " +
                    "Back it up on the Compress tab or open it in the Server tab."
            )

        val mimeHint = context.contentResolver.getType(uri)?.lowercase(Locale.ROOT).orEmpty()
        val guessedIsVideo = mimeHint.startsWith("video/") ||
            ShareUtils.inferMimeType(
                File(resolved.originalName ?: resolved.sourceDisplayName ?: "file.jpg")
            ).startsWith("video/")

        onStage?.invoke("Auto-fetching original from server…")
        val client = PhotoHubApiClient(context, settings)
        val (file, fromCache) = OriginalDownloadCache.getOrFetchOriginal(
            context = context,
            apiClient = client,
            masterHash = resolved.masterHash,
            preferredFilename = resolved.originalName,
            expectedSizeBytes = resolved.expectedSizeBytes,
            isVideo = guessedIsVideo,
            onProgress = onDownloadProgress
        )

        val finalName = resolved.originalName?.takeIf { it.isNotBlank() } ?: file.name
        val mime = ShareUtils.inferMimeType(file, fallbackName = finalName)
        return FetchedOriginalResult(
            masterHash = resolved.masterHash,
            file = file,
            originalName = finalName,
            mimeType = mime,
            sizeBytes = file.length(),
            fromCache = fromCache
        )
    }

    private fun lookupTrackerWithMediaStoreAlias(uri: Uri) =
        tracker.masterLookup(uri.toString()) ?: run {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val canonical = runCatching { MediaStore.getMediaUri(context, uri) }.getOrNull()
                canonical?.let { tracker.masterLookup(it.toString()) }
            } else {
                null
            }
        }

    private suspend fun resolveMasterByPrefix(
        prefix: String,
        cachedPhotos: List<ServerPhoto>,
        client: PhotoHubApiClient
    ): ServerPhoto? {
        val cachedMatch = cachedPhotos.firstOrNull { it.hash.startsWith(prefix, ignoreCase = true) }
        if (cachedMatch != null) return cachedMatch
        return runCatching { client.lookupPhotoByHashPrefix(prefix) }.getOrNull()
    }

    private suspend fun computeUriSha256(uri: Uri): String = withContext(Dispatchers.IO) {
        val digest = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(1024 * 1024)
        val stream = context.contentResolver.openInputStream(uri)
            ?: throw IOException("Cannot read selected gallery item.")
        val coroutineCtx = currentCoroutineContext()
        stream.use { input ->
            while (true) {
                coroutineCtx.ensureActive()
                val r = input.read(buf)
                if (r <= 0) break
                digest.update(buf, 0, r)
            }
        }
        digest.digest().joinToString("") { "%02x".format(it) }
    }
}

object ShareUtils {
    fun inferMimeType(file: File, fallbackName: String? = null): String {
        val ext = (fallbackName ?: file.name)
            .substringAfterLast('.', "")
            .lowercase(Locale.ROOT)
        return when (ext) {
            "mp4", "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "3gp" -> "video/3gpp"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "avi" -> "video/x-msvideo"
            "png" -> "image/png"
            "heic", "heif" -> "image/heic"
            "webp" -> "image/webp"
            "dng", "cr2", "nef", "arw" -> "image/*"
            else -> "image/jpeg"
        }
    }

    fun computeCombinedShareMimeType(mimeTypes: List<String>): String {
        if (mimeTypes.isEmpty()) return "*/*"
        val allImages = mimeTypes.all { it.startsWith("image/", ignoreCase = true) }
        val allVideos = mimeTypes.all { it.startsWith("video/", ignoreCase = true) }
        return when {
            mimeTypes.size == 1 -> mimeTypes.first()
            allImages -> "image/*"
            allVideos -> "video/*"
            else -> "*/*"
        }
    }

    fun buildShareChooserIntent(
        context: Context,
        files: List<File>,
        title: String = "Share Original",
        excludeComponents: Array<ComponentName> = emptyArray()
    ): Intent {
        require(files.isNotEmpty()) { "At least one file is required to share." }
        val authority = "${context.packageName}.fileprovider"
        val uris = ArrayList<Uri>(files.size)
        val mimeTypes = ArrayList<String>(files.size)

        for (file in files) {
            uris.add(FileProvider.getUriForFile(context, authority, file))
            mimeTypes.add(inferMimeType(file))
        }

        val combinedMime = computeCombinedShareMimeType(mimeTypes)
        val shareIntent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).apply {
                type = combinedMime
                putExtra(Intent.EXTRA_STREAM, uris.first())
                clipData = ClipData.newRawUri("Original Media", uris.first())
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                type = combinedMime
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                val clip = ClipData.newRawUri("Original Media", uris.first())
                for (i in 1 until uris.size) {
                    clip.addItem(ClipData.Item(uris[i]))
                }
                clipData = clip
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }

        return Intent.createChooser(shareIntent, title).apply {
            if (excludeComponents.isNotEmpty()) {
                putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, excludeComponents)
            }
        }
    }

    fun buildPassThroughShareChooserIntent(
        context: Context,
        uris: List<Uri>,
        title: String = "Share Selected Item",
        excludeComponents: Array<ComponentName> = emptyArray()
    ): Intent {
        require(uris.isNotEmpty()) { "At least one URI is required." }
        val resolvedMimes = uris.map { uri ->
            context.contentResolver.getType(uri) ?: "image/*"
        }
        val combinedMime = computeCombinedShareMimeType(resolvedMimes)
        val shareIntent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).apply {
                type = combinedMime
                putExtra(Intent.EXTRA_STREAM, uris.first())
                clipData = ClipData.newRawUri("Media", uris.first())
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                type = combinedMime
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
                val clip = ClipData.newRawUri("Media", uris.first())
                for (i in 1 until uris.size) {
                    clip.addItem(ClipData.Item(uris[i]))
                }
                clipData = clip
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }
        return Intent.createChooser(shareIntent, title).apply {
            if (excludeComponents.isNotEmpty()) {
                putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, excludeComponents)
            }
        }
    }
}
