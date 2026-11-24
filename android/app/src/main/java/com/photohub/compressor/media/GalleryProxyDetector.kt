package com.photohub.compressor.media

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.provider.MediaStore
import android.provider.OpenableColumns
import com.photohub.compressor.data.*
import com.photohub.compressor.network.PhotoHubApiClient
import com.photohub.compressor.sync.LocalProxyStore
import com.photohub.compressor.sync.LocalProxyTracker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

enum class GalleryMediaKind {
    PROXY,
    ORIGINAL_BACKED_UP,
    ORIGINAL_UNBACKED,
    UNKNOWN
}

data class GalleryProxyInspectionItem(
    val id: String,
    val uri: Uri,
    val displayName: String,
    val isVideo: Boolean,
    val localSizeBytes: Long,
    val thumbnail: Bitmap?,
    val kind: GalleryMediaKind,
    val signals: List<String>,
    val masterHash: String?,
    val proxySha256: String?,
    val originalName: String?,
    val originalSizeBytes: Long?,
    val isProtectedOriginal: Boolean,
    val hasServerProxy: Boolean
)

data class CandidateDeepCheckMatch(
    val isProxy: Boolean,
    val isMaster: Boolean,
    val masterHash: String?,
    val proxySha256: String?,
    val originalName: String?,
    val originalSizeBytes: Long?,
    val isProtectedOriginal: Boolean,
    val signal: String
)

/**
 * Multi-signal detector determining whether items in the native Android Gallery
 * are PhotoHub compressed proxies or full-resolution originals:
 * 1. LocalProxyTracker
 * 2. PHOTOHUB_PROXY_ filename prefix
 * 3. Embedded EXIF / MP4 container PhotoHubProxy:<masterHash> metadata
 * 4. Stream SHA-256 against cached server index and POST /api/check/batch
 */
object GalleryProxyDetector {
    private const val AUTO_DEEP_SCAN_MAX_BYTES = 5L * 1024L * 1024L
    private const val AUTO_DEEP_SCAN_LIMIT = 150

    suspend fun enrichCandidatesWithServer(
        context: Context,
        candidates: List<PhotoCandidate>,
        tracker: LocalProxyTracker,
        client: PhotoHubApiClient,
        cachedServerPhotos: List<ServerPhoto>
    ): Map<String, CandidateDeepCheckMatch> = withContext(Dispatchers.IO) {
        val eligible = candidates.asSequence()
            .filter {
                it.state is PhotoCompressionState.Pending &&
                    !it.isVideo &&
                    it.estimatedBytes in 1L..AUTO_DEEP_SCAN_MAX_BYTES
            }
            .take(AUTO_DEEP_SCAN_LIMIT)
            .toList()
        if (eligible.isEmpty()) return@withContext emptyMap()

        val resolver = context.contentResolver
        val mediaService = MediaLibraryService(context)
        val hashByServerHash = cachedServerPhotos.associateBy { it.hash.lowercase(Locale.ROOT) }
        val hashByProxyHash = cachedServerPhotos
            .filter { !it.proxyHash.isNullOrBlank() }
            .associateBy { it.proxyHash!!.lowercase(Locale.ROOT) }

        val candidateToSha = mutableMapOf<PhotoCandidate, String>()
        for (item in eligible) {
            val sha = runCatching {
                mediaService.openOriginalStreamWithFallback(resolver, item.contentUri)?.use { stream ->
                    ProxyGenerator.computeStreamSha256(stream)
                }
            }.getOrNull()
            if (!sha.isNullOrBlank()) {
                candidateToSha[item] = sha.lowercase(Locale.ROOT)
            }
        }
        if (candidateToSha.isEmpty()) return@withContext emptyMap()

        val unknownHashes = mutableListOf<String>()
        val results = mutableMapOf<String, CandidateDeepCheckMatch>()

        for ((cand, sha) in candidateToSha) {
            val trackedMaster = tracker.masterHashForProxySha256(sha)
            val cachedByProxy = hashByProxyHash[sha]
            if (tracker.isKnownProxySha256(sha) || trackedMaster != null || cachedByProxy != null) {
                val mHash = trackedMaster ?: cachedByProxy?.hash
                val linkedServer = mHash?.let { hashByServerHash[it.lowercase(Locale.ROOT)] } ?: cachedByProxy
                tracker.markAsProxy(
                    assetId = cand.id,
                    proxySha256 = sha,
                    masterHash = mHash,
                    originalName = linkedServer?.originalName ?: cand.filename
                )
                results[cand.id] = CandidateDeepCheckMatch(
                    isProxy = true,
                    isMaster = false,
                    masterHash = mHash,
                    proxySha256 = sha,
                    originalName = linkedServer?.originalName,
                    originalSizeBytes = linkedServer?.size,
                    isProtectedOriginal = linkedServer?.isProtectedOriginal == true,
                    signal = "Local / Server Proxy Hash"
                )
            } else {
                unknownHashes.add(sha)
            }
        }

        if (unknownHashes.isNotEmpty()) {
            val batchResp = runCatching { client.checkHashesBatch(unknownHashes) }.getOrNull().orEmpty()
            for ((cand, sha) in candidateToSha) {
                if (results.containsKey(cand.id)) continue
                val check = batchResp[sha] ?: continue
                if (!check.exists) continue
                val resolvedMaster = (check.masterHash ?: sha).takeIf { it.isNotBlank() }
                val linkedServer = resolvedMaster?.let { hashByServerHash[it.lowercase(Locale.ROOT)] }
                if (check.isProxy) {
                    tracker.markAsProxy(
                        assetId = cand.id,
                        proxySha256 = sha,
                        masterHash = resolvedMaster,
                        originalName = linkedServer?.originalName ?: cand.filename
                    )
                    results[cand.id] = CandidateDeepCheckMatch(
                        isProxy = true,
                        isMaster = false,
                        masterHash = resolvedMaster,
                        proxySha256 = sha,
                        originalName = linkedServer?.originalName,
                        originalSizeBytes = linkedServer?.size,
                        isProtectedOriginal = check.keepOriginalOnDevice || check.isProtectedOriginal,
                        signal = "Server SHA-256"
                    )
                } else if (check.isMaster) {
                    val prot = check.keepOriginalOnDevice || check.isProtectedOriginal
                    if (prot && resolvedMaster != null) {
                        tracker.markRestoredOriginal(cand.id, resolvedMaster)
                    }
                    results[cand.id] = CandidateDeepCheckMatch(
                        isProxy = false,
                        isMaster = true,
                        masterHash = resolvedMaster,
                        proxySha256 = null,
                        originalName = linkedServer?.originalName ?: cand.filename,
                        originalSizeBytes = linkedServer?.size ?: cand.estimatedBytes,
                        isProtectedOriginal = prot,
                        signal = "Server SHA-256"
                    )
                }
            }
        }

        results
    }

    suspend fun inspectPickedUris(
        context: Context,
        settings: AppSettings,
        uris: List<Uri>
    ): List<GalleryProxyInspectionItem> = withContext(Dispatchers.IO) {
        if (uris.isEmpty()) return@withContext emptyList()
        val tracker = LocalProxyTracker.getInstance(context)
        val store = LocalProxyStore.getInstance(context)
        val cur = settings.current
        val cachedPhotos = store.cachedPhotos(cur.normalizedBaseUrl, cur.apiKeyCacheScope)
        val hashByServer = cachedPhotos.associateBy { it.hash.lowercase(Locale.ROOT) }
        val prefixByServer = cachedPhotos
            .mapNotNull { p ->
                val tag = ProxyGenerator.proxyPrefixTag(p.hash)
                if (tag.length >= 8) tag to p else null
            }
            .toMap()
        val proxyHashByServer = cachedPhotos
            .filter { !it.proxyHash.isNullOrBlank() }
            .associateBy { it.proxyHash!!.lowercase(Locale.ROOT) }

        val resolver = context.contentResolver
        val mediaResolver = OriginalMediaResolver(context, settings)
        val mediaService = MediaLibraryService(context)
        val apiClient = PhotoHubApiClient(context, settings)

        data class Draft(
            val uri: Uri,
            val displayName: String,
            val isVideo: Boolean,
            val localSize: Long,
            val thumbnail: Bitmap?,
            val signals: MutableList<String>,
            var masterHash: String?,
            var proxySha: String?,
            var prefixHint: String?,
            var isTrackedProxy: Boolean,
            var isTrackedRestored: Boolean
        )

        val drafts = uris.map { uri ->
            val displayName = mediaResolver.queryDisplayName(uri) ?: uri.lastPathSegment ?: "Media Item"
            val mimeHint = resolver.getType(uri)?.lowercase(Locale.ROOT).orEmpty()
            val isVideo = mimeHint.startsWith("video/") ||
                (displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
                    in setOf("mp4", "mov", "m4v", "mkv", "webm", "3gp", "avi"))
            val localSize = querySizeBytes(context, uri)
            val thumb = mediaService.loadThumbnail(uri, sizePx = 180)
            val signals = mutableListOf<String>()

            var masterHash: String? = null
            var isTrackedProxy = false
            var isTrackedRestored = false
            var prefixHint: String? = null

            val candidateKeys = buildList {
                add(uri.toString())
                extractCanonicalMediaStoreUri(uri, isVideo)?.let { add(it) }
            }.distinct()

            for (key in candidateKeys) {
                if (tracker.isRestoredOriginal(key)) {
                    isTrackedRestored = true
                }
                val match = tracker.masterLookup(key)
                if (match != null) {
                    isTrackedProxy = true
                    masterHash = match.masterHash
                    if ("Local Tracker" !in signals) signals.add("Local Tracker")
                } else if (tracker.isKnownProxy(key)) {
                    isTrackedProxy = true
                    if ("Local Tracker" !in signals) signals.add("Local Tracker")
                }
            }

            val fnPrefix = ProxyGenerator.extractMasterHashPrefix(displayName)
            if (fnPrefix != null) {
                prefixHint = fnPrefix
                signals.add("Filename Tag")
                if (masterHash == null) {
                    masterHash = prefixByServer[fnPrefix]?.hash
                }
            }

            val embeddedMarker = runCatching {
                if (!isVideo) {
                    resolver.openInputStream(uri)?.use { stream ->
                        ProxyGenerator.extractEmbeddedProxyMasterHashFromStream(stream)
                    }
                } else {
                    extractVideoMarkerFromUri(context, uri)
                }
            }.getOrNull()

            if (embeddedMarker != null) {
                signals.add(if (isVideo) "Video Metadata" else "EXIF Metadata")
                if (ProxyGenerator.isFullSha256Hex(embeddedMarker)) {
                    masterHash = embeddedMarker.lowercase(Locale.ROOT)
                } else {
                    if (prefixHint == null) prefixHint = embeddedMarker
                    if (masterHash == null) masterHash = prefixByServer[embeddedMarker]?.hash
                }
            }

            val sha = runCatching {
                mediaService.openOriginalStreamWithFallback(resolver, uri)?.use { stream ->
                    ProxyGenerator.computeStreamSha256(stream)
                }
            }.getOrNull()?.lowercase(Locale.ROOT)

            if (sha != null) {
                val trackedBySha = tracker.masterHashForProxySha256(sha)
                val cachedBySha = proxyHashByServer[sha]
                if (tracker.isKnownProxySha256(sha) || trackedBySha != null || cachedBySha != null) {
                    isTrackedProxy = true
                    if ("Local Proxy Hash" !in signals) signals.add("Local Proxy Hash")
                    masterHash = masterHash ?: trackedBySha ?: cachedBySha?.hash
                }
            }

            Draft(
                uri = uri,
                displayName = displayName,
                isVideo = isVideo,
                localSize = localSize,
                thumbnail = thumb,
                signals = signals,
                masterHash = masterHash,
                proxySha = sha,
                prefixHint = prefixHint,
                isTrackedProxy = isTrackedProxy,
                isTrackedRestored = isTrackedRestored
            )
        }

        val allShas = drafts.mapNotNull { it.proxySha }
        val serverOnline: Boolean
        val batchResults: Map<String, CheckResponse>
        if (cur.isSignedIn && allShas.isNotEmpty()) {
            val fetched = runCatching { apiClient.checkHashesBatch(allShas) }
            serverOnline = fetched.isSuccess
            batchResults = fetched.getOrNull().orEmpty()
        } else {
            serverOnline = false
            batchResults = emptyMap()
        }

        drafts.map { d ->
            val check = d.proxySha?.let { batchResults[it] }
            val hasLocalProxySignal = d.isTrackedProxy || d.signals.any {
                it in setOf("Local Tracker", "Filename Tag", "EXIF Metadata", "Video Metadata", "Local Proxy Hash")
            }
            val serverSaysProxy = check?.isProxy == true
            val resolvedMaster = (d.masterHash ?: check?.masterHash)?.lowercase(Locale.ROOT)
            val linkedServer = resolvedMaster?.let { hashByServer[it] }
                ?: d.prefixHint?.let { prefixByServer[it] }
                ?: d.proxySha?.let { proxyHashByServer[it] }

            val kind: GalleryMediaKind
            var isProtected = check?.keepOriginalOnDevice == true || check?.isProtectedOriginal == true || d.isTrackedRestored
            var hasServerProxy = check?.hasProxy == true || (linkedServer?.hasProxy == true)

            if (serverSaysProxy || hasLocalProxySignal) {
                if (serverSaysProxy && "Server SHA-256" !in d.signals) {
                    d.signals.add("Server SHA-256")
                }
                kind = GalleryMediaKind.PROXY
                tracker.markAsProxy(
                    assetId = d.uri.toString(),
                    proxySha256 = d.proxySha.orEmpty(),
                    masterHash = resolvedMaster ?: linkedServer?.hash,
                    originalName = linkedServer?.originalName ?: d.displayName
                )
            } else if (check?.isMaster == true || d.isTrackedRestored) {
                if (check?.isMaster == true && "Server SHA-256" !in d.signals) {
                    d.signals.add("Server SHA-256")
                }
                if (d.isTrackedRestored && "Restored Original" !in d.signals) {
                    d.signals.add("Restored Original")
                }
                kind = GalleryMediaKind.ORIGINAL_BACKED_UP
            } else if (serverOnline) {
                kind = GalleryMediaKind.ORIGINAL_UNBACKED
            } else {
                kind = GalleryMediaKind.UNKNOWN
            }

            val finalMaster = resolvedMaster ?: linkedServer?.hash ?: if (kind == GalleryMediaKind.ORIGINAL_BACKED_UP) d.proxySha else null
            GalleryProxyInspectionItem(
                id = d.uri.toString(),
                uri = d.uri,
                displayName = d.displayName,
                isVideo = d.isVideo,
                localSizeBytes = d.localSize,
                thumbnail = d.thumbnail,
                kind = kind,
                signals = d.signals,
                masterHash = finalMaster,
                proxySha256 = d.proxySha,
                originalName = linkedServer?.originalName ?: d.displayName,
                originalSizeBytes = linkedServer?.size,
                isProtectedOriginal = isProtected,
                hasServerProxy = hasServerProxy
            )
        }
    }

    internal fun extractVideoMarkerFromUri(context: Context, uri: Uri): String? {
        val tmp = File(context.cacheDir, "probe_vid_${System.nanoTime()}.mp4")
        return try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                val headBuf = ByteArray(256 * 1024)
                val n = input.read(headBuf)
                if (n > 0) {
                    ProxyGenerator.findProxyMarkerInByteArray(headBuf.copyOf(n))?.let { return it }
                }
            }
            context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { afd ->
                val len = afd.length
                if (len > 256 * 1024L) {
                    afd.createInputStream().use { stream ->
                        tmp.outputStream().use { out -> stream.copyTo(out) }
                    }
                    return ProxyGenerator.extractProxyMarkerFromVideoContainer(tmp)
                }
            }
            null
        } catch (_: Exception) {
            null
        } finally {
            tmp.delete()
        }
    }

    private fun extractCanonicalMediaStoreUri(uri: Uri, isVideo: Boolean): String? {
        val last = uri.lastPathSegment ?: return null
        val idNum = last.substringAfterLast(':').toLongOrNull() ?: return null
        val base = if (isVideo) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        return Uri.withAppendedPath(base, idNum.toString()).toString()
    }

    private fun querySizeBytes(context: Context, uri: Uri): Long {
        runCatching {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.SIZE),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (idx >= 0 && !cursor.isNull(idx)) {
                        return cursor.getLong(idx).coerceAtLeast(0L)
                    }
                }
            }
        }
        return runCatching {
            context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { afd ->
                afd.length.coerceAtLeast(0L)
            } ?: 0L
        }.getOrDefault(0L)
    }
}
