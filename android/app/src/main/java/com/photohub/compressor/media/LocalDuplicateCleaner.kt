package com.photohub.compressor.media

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import com.photohub.compressor.sync.LocalProxyTracker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest
import java.util.Locale
import kotlin.coroutines.coroutineContext
import kotlin.math.abs

enum class LocalDuplicateReason(val label: String) {
    DUPLICATE_PROXY("Duplicate Proxy"),
    REDUNDANT_PROXY("Redundant Proxy"),
    EXACT_FILE("Exact Duplicate"),
    VISUALLY_IDENTICAL("Identical Copy")
}

data class LocalDuplicateItem(
    val id: String, // MediaStore content URI string
    val filename: String,
    val sizeBytes: Long,
    val dateTakenMs: Long,
    val width: Int,
    val height: Int,
    val isVideo: Boolean,
    val isFavorite: Boolean,
    val isProxy: Boolean,
    val isKeep: Boolean
)

data class LocalDuplicateGroup(
    val id: String,
    val reason: LocalDuplicateReason,
    val items: List<LocalDuplicateItem>
) {
    val removableItems: List<LocalDuplicateItem>
        get() = items.filter { !it.isKeep }

    val reclaimableBytes: Long
        get() = removableItems.sumOf { it.sizeBytes.coerceAtLeast(0L) }
}

data class LocalDuplicateScanResult(
    val scannedCount: Int,
    val groups: List<LocalDuplicateGroup>
) {
    val totalRemovableCount: Int
        get() = groups.sumOf { it.removableItems.size }

    val totalReclaimableBytes: Long
        get() = groups.sumOf { it.reclaimableBytes }
}

/**
 * Fast, safe, 100% on-device duplicate photo & video detector for Android Gallery:
 *  1. Duplicate PhotoHub proxies & redundant proxies when the original already sits on the phone
 *  2. Exact byte-for-byte duplicate files (size-bucketed streaming SHA-256)
 *  3. Visually identical re-saved / re-encoded photo copies (64-bit perceptual dHash)
 * Always preserves the single best copy in every group.
 */
object LocalDuplicateCleaner {

    internal data class ScannedMediaMeta(
        val id: String,
        val uri: Uri?,
        val filename: String,
        val sizeBytes: Long,
        val dateTakenMs: Long,
        val width: Int,
        val height: Int,
        val isVideo: Boolean,
        val isFavorite: Boolean,
        val isProxy: Boolean,
        val proxyMasterPrefix: String?,
        val trackedMasterPrefix: String?
    )

    suspend fun scanForDuplicates(
        context: Context,
        tracker: LocalProxyTracker = LocalProxyTracker.getInstance(context),
        onProgress: (current: Int, total: Int, label: String) -> Unit
    ): LocalDuplicateScanResult = withContext(Dispatchers.IO) {
        val mediaService = MediaLibraryService(context)
        if (mediaService.currentAccessLevel() == MediaAccessLevel.DENIED) {
            return@withContext LocalDuplicateScanResult(0, emptyList())
        }

        onProgress(0, 1, "Reading gallery metadata…")
        val allMetas = queryAllGalleryMedia(context, tracker)
        val total = allMetas.size
        if (total <= 1) {
            onProgress(total, total.coerceAtLeast(1), "Scan complete")
            return@withContext LocalDuplicateScanResult(total, emptyList())
        }

        val groups = mutableListOf<LocalDuplicateGroup>()
        val assignedIds = HashSet<String>()

        // Pass 1: Duplicate PhotoHub proxies & redundant proxy + original pairs
        val proxiesByPrefix = linkedMapOf<String, MutableList<ScannedMediaMeta>>()
        val originalsByPrefix = linkedMapOf<String, MutableList<ScannedMediaMeta>>()
        for (meta in allMetas) {
            if (meta.isProxy && !meta.proxyMasterPrefix.isNullOrBlank() && meta.proxyMasterPrefix.length >= 8) {
                proxiesByPrefix.getOrPut(meta.proxyMasterPrefix) { mutableListOf() }.add(meta)
            } else if (!meta.isProxy && !meta.trackedMasterPrefix.isNullOrBlank() && meta.trackedMasterPrefix.length >= 8) {
                originalsByPrefix.getOrPut(meta.trackedMasterPrefix) { mutableListOf() }.add(meta)
            }
        }

        for ((prefix, proxies) in proxiesByPrefix) {
            coroutineContext.ensureActive()
            val liveOriginals = originalsByPrefix[prefix]
            val bestOriginal = liveOriginals?.let { pickBestOriginal(it) }
            if (bestOriginal != null) {
                val combined = listOf(bestOriginal) + proxies
                groups.add(
                    buildGroup(
                        id = "redundant_proxy_$prefix",
                        reason = LocalDuplicateReason.REDUNDANT_PROXY,
                        members = combined,
                        preferredKeepId = bestOriginal.id
                    )
                )
                combined.forEach { assignedIds.add(it.id) }
            } else if (proxies.size >= 2) {
                groups.add(
                    buildGroup(
                        id = "dup_proxy_$prefix",
                        reason = LocalDuplicateReason.DUPLICATE_PROXY,
                        members = proxies,
                        preferredKeepId = null
                    )
                )
                proxies.forEach { assignedIds.add(it.id) }
            }
        }

        // Pass 2: Exact byte-for-byte duplicates (size-bucketed streaming SHA-256)
        val sizeBuckets = linkedMapOf<Pair<Boolean, Long>, MutableList<ScannedMediaMeta>>()
        for (meta in allMetas) {
            if (meta.id in assignedIds || meta.sizeBytes <= 0L) continue
            sizeBuckets.getOrPut(meta.isVideo to meta.sizeBytes) { mutableListOf() }.add(meta)
        }

        val candidateBuckets = sizeBuckets.values.filter { it.size >= 2 }
        val totalToHash = candidateBuckets.sumOf { it.size }
        var hashedSoFar = 0

        for (bucket in candidateBuckets) {
            coroutineContext.ensureActive()
            val bySha = linkedMapOf<String, MutableList<ScannedMediaMeta>>()
            for (meta in bucket) {
                coroutineContext.ensureActive()
                hashedSoFar++
                if (hashedSoFar == 1 || hashedSoFar % 10 == 0 || hashedSoFar == totalToHash) {
                    onProgress(hashedSoFar, totalToHash.coerceAtLeast(1), "Verifying exact duplicates ($hashedSoFar/$totalToHash)…")
                }
                val sha = meta.uri?.let { computeUriSha256(context, it) }
                if (sha != null) {
                    bySha.getOrPut(sha) { mutableListOf() }.add(meta)
                }
            }
            for ((sha, matches) in bySha) {
                if (matches.size >= 2) {
                    groups.add(
                        buildGroup(
                            id = "exact_${sha.take(16)}",
                            reason = LocalDuplicateReason.EXACT_FILE,
                            members = matches,
                            preferredKeepId = null
                        )
                    )
                    matches.forEach { assignedIds.add(it.id) }
                }
            }
        }

        // Pass 3: Visually identical re-saved / re-encoded photo copies (64-bit perceptual dHash)
        val imageCandidates = allMetas
            .filter { it.id !in assignedIds && !it.isVideo && !it.isProxy }
            .take(900)

        data class VisualEntry(
            val meta: ScannedMediaMeta,
            val dHash: Long,
            val aspectRatio: Double
        )

        val visualEntries = ArrayList<VisualEntry>(imageCandidates.size)
        val visualTotal = imageCandidates.size
        imageCandidates.forEachIndexed { idx, meta ->
            coroutineContext.ensureActive()
            val step = idx + 1
            if (step == 1 || step % 40 == 0 || step == visualTotal) {
                onProgress(step, visualTotal.coerceAtLeast(1), "Checking identical copies ($step/$visualTotal)…")
            }
            val thumb = meta.uri?.let { loadTinyBitmap(context, it) }
            if (thumb != null) {
                val hash = computeDHash64(thumb)
                thumb.recycle()
                val ar = if (meta.height > 0) meta.width.toDouble() / meta.height.toDouble() else 1.0
                visualEntries.add(VisualEntry(meta, hash, ar))
            }
        }

        val vn = visualEntries.size
        if (vn >= 2) {
            val parent = IntArray(vn) { it }
            fun find(x: Int): Int {
                var cur = x
                while (parent[cur] != cur) {
                    parent[cur] = parent[parent[cur]]
                    cur = parent[cur]
                }
                return cur
            }
            fun unite(a: Int, b: Int) {
                val ra = find(a)
                val rb = find(b)
                if (ra != rb) parent[rb] = ra
            }

            // O(n) exact 64-bit dHash match
            val exactHashBuckets = hashMapOf<Long, MutableList<Int>>()
            for (i in 0 until vn) {
                exactHashBuckets.getOrPut(visualEntries[i].dHash) { mutableListOf() }.add(i)
            }
            for (indices in exactHashBuckets.values) {
                if (indices.size < 2) continue
                val first = indices[0]
                for (k in 1 until indices.size) {
                    val other = indices[k]
                    if (abs(visualEntries[first].aspectRatio - visualEntries[other].aspectRatio) < 0.08) {
                        unite(first, other)
                    }
                }
            }

            // Adjacent chronological near-identical copies (hamming <= 2 within 5s)
            for (i in 0 until vn) {
                val a = visualEntries[i]
                val upper = minOf(vn, i + 12)
                for (j in (i + 1) until upper) {
                    val b = visualEntries[j]
                    if (abs(a.aspectRatio - b.aspectRatio) >= 0.05) continue
                    if (a.meta.dateTakenMs > 0L && b.meta.dateTakenMs > 0L &&
                        abs(a.meta.dateTakenMs - b.meta.dateTakenMs) <= 5_000L
                    ) {
                        if (hammingDistance64(a.dHash, b.dHash) <= 2) {
                            unite(i, j)
                        }
                    }
                }
            }

            val groupedVisual = linkedMapOf<Int, MutableList<ScannedMediaMeta>>()
            for (i in 0 until vn) {
                groupedVisual.getOrPut(find(i)) { mutableListOf() }.add(visualEntries[i].meta)
            }
            for ((_, members) in groupedVisual) {
                if (members.size >= 2) {
                    groups.add(
                        buildGroup(
                            id = "visual_${members[0].id.hashCode()}",
                            reason = LocalDuplicateReason.VISUALLY_IDENTICAL,
                            members = members,
                            preferredKeepId = null
                        )
                    )
                }
            }
        }

        groups.sortByDescending { it.reclaimableBytes }
        onProgress(total, total.coerceAtLeast(1), "Scan complete")
        LocalDuplicateScanResult(scannedCount = total, groups = groups)
    }

    fun loadThumbnailBitmap(context: Context, uriString: String, sizePx: Int = 192): Bitmap? {
        val uri = runCatching { Uri.parse(uriString) }.getOrNull() ?: return null
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                context.contentResolver.loadThumbnail(uri, Size(sizePx, sizePx), null)
            } else {
                loadTinyBitmap(context, uri, targetPx = sizePx)
            }
        }.getOrNull()
    }

    private fun queryAllGalleryMedia(
        context: Context,
        tracker: LocalProxyTracker
    ): List<ScannedMediaMeta> {
        val resolver = context.contentResolver
        val collection = MediaStore.Files.getContentUri("external")
        val cols = mutableListOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            cols.add(MediaStore.MediaColumns.IS_FAVORITE)
        }
        val trashClause = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            " AND COALESCE(${MediaStore.MediaColumns.IS_TRASHED}, 0) = 0 AND COALESCE(${MediaStore.MediaColumns.IS_PENDING}, 0) = 0"
        } else {
            ""
        }
        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)$trashClause"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()
        )
        val sortOrder = "${MediaStore.MediaColumns.DATE_TAKEN} DESC, ${MediaStore.MediaColumns.DATE_ADDED} DESC"
        val results = ArrayList<ScannedMediaMeta>(512)

        runCatching {
            resolver.query(collection, cols.toTypedArray(), selection, args, sortOrder)?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val typeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
                val nameCol = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                val sizeCol = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
                val takenCol = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_TAKEN)
                val addedCol = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_ADDED)
                val widthCol = cursor.getColumnIndex(MediaStore.MediaColumns.WIDTH)
                val heightCol = cursor.getColumnIndex(MediaStore.MediaColumns.HEIGHT)
                val favCol = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    cursor.getColumnIndex(MediaStore.MediaColumns.IS_FAVORITE)
                } else {
                    -1
                }

                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idCol)
                    val mediaType = cursor.getInt(typeCol)
                    val isVideo = mediaType == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                    val contentUri = ContentUris.withAppendedId(
                        if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                        else MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        id
                    )
                    val uriStr = contentUri.toString()
                    val displayName = (if (nameCol >= 0) cursor.getString(nameCol) else null)?.trim().orEmpty()
                        .ifEmpty { if (isVideo) "Video" else "Photo" }
                    val sizeBytes = if (sizeCol >= 0) cursor.getLong(sizeCol) else 0L
                    val takenMs = if (takenCol >= 0) cursor.getLong(takenCol) else 0L
                    val addedSec = if (addedCol >= 0) cursor.getLong(addedCol) else 0L
                    val effectiveDateMs = when {
                        takenMs > 0L -> takenMs
                        addedSec > 0L -> addedSec * 1000L
                        else -> 0L
                    }
                    val width = if (widthCol >= 0) cursor.getInt(widthCol) else 0
                    val height = if (heightCol >= 0) cursor.getInt(heightCol) else 0
                    val isFav = favCol >= 0 && cursor.getInt(favCol) != 0

                    val proxyPrefixFromName = ProxyGenerator.extractMasterHashPrefix(File(displayName).name)?.lowercase(Locale.ROOT)
                    val isTrackedProxy = tracker.isKnownProxy(uriStr)
                    val trackedMaster = tracker.anyMasterHash(uriStr)?.lowercase(Locale.ROOT)
                    val isProxy = (proxyPrefixFromName != null) || isTrackedProxy
                    val proxyPrefix = proxyPrefixFromName ?: if (isTrackedProxy) trackedMaster?.take(16) else null
                    val origPrefix = if (!isProxy) trackedMaster?.take(16) else null

                    results.add(
                        ScannedMediaMeta(
                            id = uriStr,
                            uri = contentUri,
                            filename = displayName,
                            sizeBytes = sizeBytes,
                            dateTakenMs = effectiveDateMs,
                            width = width,
                            height = height,
                            isVideo = isVideo,
                            isFavorite = isFav,
                            isProxy = isProxy,
                            proxyMasterPrefix = proxyPrefix,
                            trackedMasterPrefix = origPrefix
                        )
                    )
                }
            }
        }
        return results
    }

    private fun computeUriSha256(context: Context, uri: Uri): String? {
        return runCatching {
            val md = MessageDigest.getInstance("SHA-256")
            val buf = ByteArray(64 * 1024)
            var total = 0L
            context.contentResolver.openInputStream(uri)?.use { input ->
                while (true) {
                    val read = input.read(buf)
                    if (read <= 0) break
                    md.update(buf, 0, read)
                    total += read
                }
            } ?: return null
            if (total <= 0L) return null
            md.digest().joinToString("") { "%02x".format(it) }
        }.getOrNull()
    }

    private fun loadTinyBitmap(context: Context, uri: Uri, targetPx: Int = 64): Bitmap? {
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                context.contentResolver.loadThumbnail(uri, Size(targetPx, targetPx), null)
            } else {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                context.contentResolver.openInputStream(uri)?.use {
                    BitmapFactory.decodeStream(it, null, bounds)
                }
                var sample = 1
                val maxDim = maxOf(bounds.outWidth, bounds.outHeight)
                while (maxDim / sample > targetPx * 2) sample *= 2
                val opts = BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.RGB_565
                }
                context.contentResolver.openInputStream(uri)?.use {
                    BitmapFactory.decodeStream(it, null, opts)
                }
            }
        }.getOrNull()
    }

    internal fun computeDHash64(bitmap: Bitmap): Long {
        val scaled = Bitmap.createScaledBitmap(bitmap, 9, 8, true)
        val pixels = IntArray(9 * 8)
        scaled.getPixels(pixels, 0, 9, 0, 0, 9, 8)
        if (scaled !== bitmap) scaled.recycle()

        var hash = 0L
        var bit = 0
        for (row in 0 until 8) {
            val rowOff = row * 9
            for (col in 0 until 8) {
                val left = luma(pixels[rowOff + col])
                val right = luma(pixels[rowOff + col + 1])
                if (left > right) {
                    hash = hash or (1L shl bit)
                }
                bit++
            }
        }
        return hash
    }

    private fun luma(pixel: Int): Int {
        val r = (pixel shr 16) and 0xFF
        val g = (pixel shr 8) and 0xFF
        val b = pixel and 0xFF
        return (r * 77 + g * 150 + b * 29) shr 8
    }

    internal fun hammingDistance64(a: Long, b: Long): Int = java.lang.Long.bitCount(a xor b)

    internal fun bestScore(meta: ScannedMediaMeta): Double {
        var score = 0.0
        if (!meta.isProxy) score += 1_000_000.0
        if (meta.isFavorite) score += 500_000.0
        score += minOf(300_000.0, (meta.width.toDouble() * meta.height.toDouble()) / 100.0)
        score += minOf(100_000.0, meta.sizeBytes.toDouble() / 1024.0)
        val lower = meta.filename.lowercase(Locale.ROOT)
        if (!lower.contains("copy") && !lower.contains("(1)") && !lower.contains("(2)")) {
            score += 5_000.0
        }
        if (meta.dateTakenMs > 0L) {
            score -= meta.dateTakenMs.toDouble() / 1_000_000_000_000.0
        }
        return score
    }

    internal fun pickBestOriginal(members: List<ScannedMediaMeta>): ScannedMediaMeta? =
        members.maxByOrNull { bestScore(it) }

    internal fun buildGroup(
        id: String,
        reason: LocalDuplicateReason,
        members: List<ScannedMediaMeta>,
        preferredKeepId: String?
    ): LocalDuplicateGroup {
        val keepId = preferredKeepId ?: pickBestOriginal(members)?.id ?: members.first().id
        val sorted = members.sortedWith(
            compareByDescending<ScannedMediaMeta> { it.id == keepId }
                .thenByDescending { bestScore(it) }
        )
        return LocalDuplicateGroup(
            id = id,
            reason = reason,
            items = sorted.map { m ->
                LocalDuplicateItem(
                    id = m.id,
                    filename = m.filename,
                    sizeBytes = m.sizeBytes,
                    dateTakenMs = m.dateTakenMs,
                    width = m.width,
                    height = m.height,
                    isVideo = m.isVideo,
                    isFavorite = m.isFavorite,
                    isProxy = m.isProxy,
                    isKeep = m.id == keepId
                )
            }
        )
    }
}
