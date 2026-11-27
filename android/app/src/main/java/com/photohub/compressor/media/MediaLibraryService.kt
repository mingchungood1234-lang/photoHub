package com.photohub.compressor.media

import android.Manifest
import android.app.PendingIntent
import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.IntentSender
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Size
import androidx.core.content.ContextCompat
import com.photohub.compressor.data.PhotoCandidate
import com.photohub.compressor.data.PhotoCompressionState
import com.photohub.compressor.data.ServerPhoto
import com.photohub.compressor.sync.LocalProxyTracker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

data class ExportedMaster(
    val file: File,
    val sha256: String,
    val sizeBytes: Long,
    val filename: String,
    val mimeType: String
)

enum class MediaAccessLevel {
    FULL_ACCESS,
    LIMITED_ACCESS,
    DENIED
}

sealed class TrashOrDeleteRequestResult {
    data class DeletedImmediately(val deletedIds: List<String>) : TrashOrDeleteRequestResult()
    data class NeedsSystemConfirmation(
        val intentSender: IntentSender,
        val targetIds: List<String>
    ) : TrashOrDeleteRequestResult()
}

class MediaLibraryService(private val context: Context) {

    fun currentAccessLevel(): MediaAccessLevel {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val img = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
            val vid = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED
            if (img && vid) return MediaAccessLevel.FULL_ACCESS
            val selectedOnly = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED
            if (img || vid || selectedOnly) return MediaAccessLevel.LIMITED_ACCESS
            return MediaAccessLevel.DENIED
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val img = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
            val vid = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED
            if (img && vid) return MediaAccessLevel.FULL_ACCESS
            if (img || vid) return MediaAccessLevel.LIMITED_ACCESS
            return MediaAccessLevel.DENIED
        }
        val read = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        return if (read) MediaAccessLevel.FULL_ACCESS else MediaAccessLevel.DENIED
    }

    fun hasMediaLocationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_MEDIA_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun hasAllFilesAccess(): Boolean = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> Environment.isExternalStorageManager()
        Build.VERSION.SDK_INT <= Build.VERSION_CODES.P ->
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        else -> false
    }

    fun canSilentlyDeleteOriginals(): Boolean =
        hasAllFilesAccess() && currentAccessLevel() != MediaAccessLevel.DENIED

    fun canWriteGallery(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return currentAccessLevel() != MediaAccessLevel.DENIED
        }
        val write = ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        return write && currentAccessLevel() != MediaAccessLevel.DENIED
    }

    fun permissionLabel(): String = when (currentAccessLevel()) {
        MediaAccessLevel.FULL_ACCESS -> "Full Access"
        MediaAccessLevel.LIMITED_ACCESS -> "Limited Access"
        MediaAccessLevel.DENIED -> "Denied"
    }

    fun scanExistingProxyPrefixesInGalleryAll(): Map<String, List<String>> {
        if (currentAccessLevel() == MediaAccessLevel.DENIED) return emptyMap()
        val resolver = context.contentResolver
        val collection = MediaStore.Files.getContentUri("external")
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.DISPLAY_NAME
        )
        val trashClause = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            " AND COALESCE(${MediaStore.MediaColumns.IS_TRASHED}, 0) = 0"
        } else {
            ""
        }
        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?) AND ${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ?$trashClause"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
            "${ProxyGenerator.PROXY_FILENAME_PREFIX}%"
        )

        val result = linkedMapOf<String, MutableList<String>>()
        runCatching {
            resolver.query(collection, projection, selection, args, null)?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val typeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idCol)
                    val mediaType = cursor.getInt(typeCol)
                    val displayName = cursor.getString(nameCol) ?: continue
                    val prefix = ProxyGenerator.extractMasterHashPrefix(displayName) ?: continue
                    val contentUri = ContentUris.withAppendedId(
                        if (mediaType == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) {
                            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                        } else {
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                        },
                        id
                    )
                    result.getOrPut(prefix) { mutableListOf() }.add(contentUri.toString())
                }
            }
        }
        return result
    }

    fun scanExistingProxyPrefixesInGallery(): Map<String, String> =
        scanExistingProxyPrefixesInGalleryAll()
            .mapNotNull { (prefix, ids) -> ids.firstOrNull()?.let { prefix to it } }
            .toMap()

    private fun formatUtcDay(ms: Long): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
        return fmt.format(Date(ms))
    }

    /**
     * Builds normalized match keys (`filename|size`, `filename|yyyy-MM-dd` with +-1 day timezone tolerance, or `filename`)
     * to detect originals already sitting in Android MediaStore without hashing gigabytes of files.
     */
    fun originalMatchKeys(filename: String, creationDateMs: Long?, sizeBytes: Long? = null): List<String> {
        val base = File(filename).name.trim().lowercase(Locale.ROOT)
        if (base.isEmpty() || base.startsWith(ProxyGenerator.PROXY_FILENAME_PREFIX.lowercase(Locale.ROOT))) {
            return emptyList()
        }
        val keys = mutableListOf<String>()
        if (sizeBytes != null && sizeBytes > 0L) {
            keys.add("sz:$base|$sizeBytes")
        }
        if (creationDateMs != null && creationDateMs > 0L) {
            val dayMs = 86_400_000L
            keys.add("dt:$base|${formatUtcDay(creationDateMs)}")
            keys.add("dt:$base|${formatUtcDay(creationDateMs - dayMs)}")
            keys.add("dt:$base|${formatUtcDay(creationDateMs + dayMs)}")
        } else {
            keys.add("nm:$base")
        }
        return keys
    }

    /**
     * Scans native Android MediaStore metadata for existing non-proxy originals so Cloud can load
     * straight from Gallery and sync/Save Proxy never creates duplicate media on the phone.
     */
    fun scanExistingOriginalMapInGallery(): Map<String, String> {
        if (currentAccessLevel() == MediaAccessLevel.DENIED) return emptyMap()
        val resolver = context.contentResolver
        val collection = MediaStore.Files.getContentUri("external")
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_ADDED
        )
        val trashClause = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            " AND COALESCE(${MediaStore.MediaColumns.IS_TRASHED}, 0) = 0"
        } else {
            ""
        }
        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)$trashClause"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()
        )
        val proxyPrefixLower = ProxyGenerator.PROXY_FILENAME_PREFIX.lowercase(Locale.ROOT)
        val map = HashMap<String, String>(512)

        runCatching {
            resolver.query(collection, projection, selection, args, null)?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val typeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val takenCol = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_TAKEN)
                val addedCol = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_ADDED)
                while (cursor.moveToNext()) {
                    val displayName = cursor.getString(nameCol)?.trim() ?: continue
                    val base = File(displayName).name.lowercase(Locale.ROOT)
                    if (base.isEmpty() || base.startsWith(proxyPrefixLower)) continue
                    val id = cursor.getLong(idCol)
                    val mediaType = cursor.getInt(typeCol)
                    val size = cursor.getLong(sizeCol)
                    val takenMs = if (takenCol >= 0) cursor.getLong(takenCol) else 0L
                    val addedSec = if (addedCol >= 0) cursor.getLong(addedCol) else 0L
                    val effectiveMs = when {
                        takenMs > 0L -> takenMs
                        addedSec > 0L -> addedSec * 1000L
                        else -> 0L
                    }
                    val uriStr = ContentUris.withAppendedId(
                        if (mediaType == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) {
                            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                        } else {
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                        },
                        id
                    ).toString()
                    if (size > 0L) {
                        map.putIfAbsent("sz:$base|$size", uriStr)
                    }
                    if (effectiveMs > 0L) {
                        map.putIfAbsent("dt:$base|${formatUtcDay(effectiveMs)}", uriStr)
                    }
                    map.putIfAbsent("nm:$base", uriStr)
                }
            }
        }
        return map
    }

    fun findMatchingOriginalAssetIdInGallery(photo: ServerPhoto): String? {
        val keys = originalMatchKeys(photo.originalName, photo.parsedCreationDateMs, photo.size)
        if (keys.isEmpty()) return null
        val existing = scanExistingOriginalMapInGallery()
        for (key in keys) {
            val found = existing[key]
            if (found != null) return found
        }
        return null
    }

    /**
     * Reconciles server photos against native Android Gallery metadata (zero network I/O)
     * so already-present originals & proxies immediately link to LocalProxyTracker.
     */
    fun reconcileExistingNativeGalleryAssets(photos: List<ServerPhoto>) {
        if (currentAccessLevel() == MediaAccessLevel.DENIED || photos.isEmpty()) return
        val tracker = LocalProxyTracker.getInstance(context)
        val unresolved = photos.filter { !tracker.hasAnyLiveGalleryAsset(it.hash) }
        if (unresolved.isEmpty()) return

        val proxyPrefixes = scanExistingProxyPrefixesInGallery()
        val originalsMap = scanExistingOriginalMapInGallery()

        for (photo in unresolved) {
            val prefix = ProxyGenerator.proxyPrefixTag(photo.hash)
            val proxyUri = if (prefix.isNotEmpty()) proxyPrefixes[prefix] else null
            if (proxyUri != null) {
                tracker.markAsProxy(
                    assetId = proxyUri,
                    proxySha256 = photo.proxyHash.orEmpty(),
                    masterHash = photo.hash,
                    originalName = photo.originalName
                )
                continue
            }
            val keys = originalMatchKeys(photo.originalName, photo.parsedCreationDateMs, photo.size)
            for (key in keys) {
                val origUri = originalsMap[key]
                if (origUri != null) {
                    tracker.markUploadedOriginal(origUri, photo.hash)
                    break
                }
            }
        }
    }

    /**
     * Loads a fast local thumbnail directly from native Android Gallery (zero network, zero app cache duplication)
     * when a live copy (restored original, uploaded original, or saved proxy) already exists on this phone.
     */
    fun loadNativeGalleryThumbnail(masterHash: String, isVideo: Boolean, maxPixelSize: Int = 320): Bitmap? {
        if (currentAccessLevel() == MediaAccessLevel.DENIED) return null
        val uri = LocalProxyTracker.getInstance(context).liveGalleryAssetUri(masterHash) ?: return null
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                context.contentResolver.loadThumbnail(uri, Size(maxPixelSize, maxPixelSize), null)
            } else if (isVideo) {
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(context, uri)
                    retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                } finally {
                    runCatching { retriever.release() }
                }
            } else {
                decodeSampledBitmapFromUri(uri, maxPixelSize, preferRgb565 = true)
            }
        }.getOrNull()
    }

    /**
     * Loads a crisp preview directly from native Android Gallery for the Cloud Lightbox with zero server download.
     */
    fun loadNativeGalleryPreviewBitmap(masterHash: String, isVideo: Boolean, maxPixelSize: Int = 1600): Bitmap? {
        if (currentAccessLevel() == MediaAccessLevel.DENIED) return null
        val uri = LocalProxyTracker.getInstance(context).liveGalleryAssetUri(masterHash) ?: return null
        return runCatching {
            if (isVideo) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    context.contentResolver.loadThumbnail(uri, Size(960, 960), null)
                } else {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(context, uri)
                        retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    } finally {
                        runCatching { retriever.release() }
                    }
                }
            } else {
                decodeSampledBitmapFromUri(uri, maxPixelSize, preferRgb565 = false)
            }
        }.getOrNull()
    }

    /**
     * Returns a live MediaStore video content URI if this video already exists in the phone's Gallery,
     * allowing ExoPlayer to play it immediately with zero server video-proxy download.
     */
    fun findLiveNativeVideoUri(masterHash: String): Uri? {
        if (currentAccessLevel() == MediaAccessLevel.DENIED) return null
        return LocalProxyTracker.getInstance(context).liveGalleryAssetUri(masterHash)
    }

    private fun decodeSampledBitmapFromUri(uri: Uri, maxPixelSize: Int, preferRgb565: Boolean): Bitmap? {
        val resolver = context.contentResolver
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= maxPixelSize && bounds.outHeight / (sample * 2) >= maxPixelSize) {
            sample *= 2
        }
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = if (preferRgb565) Bitmap.Config.RGB_565 else Bitmap.Config.ARGB_8888
        }
        return resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) }
    }

    fun scanCandidates(
        tracker: LocalProxyTracker,
        knownServerPhotos: List<ServerPhoto> = emptyList(),
        maxResults: Int? = null,
        maxInspect: Int? = null
    ): List<PhotoCandidate> {
        if (currentAccessLevel() == MediaAccessLevel.DENIED) return emptyList()

        val resolver = context.contentResolver
        val collection = MediaStore.Files.getContentUri("external")
        val projection = mutableListOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DURATION
        )

        val trashClause = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            " AND COALESCE(${MediaStore.MediaColumns.IS_TRASHED}, 0) = 0 AND COALESCE(${MediaStore.MediaColumns.IS_PENDING}, 0) = 0"
        } else {
            ""
        }
        val selection = "(${MediaStore.Files.FileColumns.MEDIA_TYPE} = ? OR ${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?)$trashClause"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()
        )
        val sortOrder = "${MediaStore.MediaColumns.DATE_ADDED} DESC"

        val prefixToServer = mutableMapOf<String, ServerPhoto>()
        val hashToServer = mutableMapOf<String, ServerPhoto>()
        for (photo in knownServerPhotos) {
            hashToServer[photo.hash.lowercase()] = photo
            val tag = ProxyGenerator.proxyPrefixTag(photo.hash)
            if (tag.length >= 8) prefixToServer[tag] = photo
        }

        val candidates = mutableListOf<PhotoCandidate>()
        var inspected = 0
        var eligibleCount = 0

        resolver.query(collection, projection.toTypedArray(), selection, args, sortOrder)?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val typeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
            val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val mimeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val wCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.WIDTH)
            val hCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.HEIGHT)
            val addedCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val takenCol = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_TAKEN)
            val durCol = cursor.getColumnIndex(MediaStore.MediaColumns.DURATION)

            while (cursor.moveToNext()) {
                if (maxInspect != null && inspected >= maxInspect) break
                if (maxResults != null && eligibleCount >= maxResults) break
                inspected++

                val id = cursor.getLong(idCol)
                val mediaType = cursor.getInt(typeCol)
                val isVideo = (mediaType == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO)
                val contentUri = ContentUris.withAppendedId(
                    if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    id
                )
                val assetId = contentUri.toString()
                if (tracker.isRestoredOriginal(assetId)) {
                    continue
                }

                val displayName = cursor.getString(nameCol)
                    ?: if (isVideo) "Video_$id.mp4" else "Photo_$id.jpg"
                val sizeBytes = cursor.getLong(sizeCol)
                if (sizeBytes <= 0L) continue

                val mime = cursor.getString(mimeCol) ?: if (isVideo) "video/mp4" else "image/jpeg"
                val w = cursor.getInt(wCol)
                val h = cursor.getInt(hCol)
                val takenMs = if (takenCol >= 0 && !cursor.isNull(takenCol)) cursor.getLong(takenCol) else 0L
                val addedMs = cursor.getLong(addedCol) * 1000L
                val dateMs = (takenMs.takeIf { it > 0L } ?: addedMs).takeIf { it > 0L }
                val durMs = if (isVideo && durCol >= 0 && !cursor.isNull(durCol)) cursor.getLong(durCol) else 0L

                // 1. Tracked proxy in LocalProxyTracker (auto-detected & skipped cleanly)
                if (tracker.isKnownProxy(assetId)) {
                    continue
                }

                // 2. Filename prefix PHOTOHUB_PROXY_<prefix16>
                val proxyMatch = ProxyGenerator.extractMasterHashPrefix(displayName)
                if (proxyMatch != null) {
                    val matched = prefixToServer[proxyMatch]
                    tracker.markAsProxy(
                        assetId = assetId,
                        proxySha256 = matched?.proxyHash.orEmpty(),
                        masterHash = matched?.hash,
                        originalName = matched?.originalName ?: displayName
                    )
                    continue
                }

                // 3. Fast EXIF marker inspection on compact local images (handles renamed proxies)
                if (!isVideo && sizeBytes <= 4_000_000L && maxOf(w, h) <= 2400) {
                    val embeddedMaster = runCatching {
                        resolver.openInputStream(contentUri)?.use { stream ->
                            ProxyGenerator.extractEmbeddedProxyMasterHashFromStream(stream)
                        }
                    }.getOrNull()
                    if (embeddedMaster != null) {
                        val prefix = ProxyGenerator.proxyPrefixTag(embeddedMaster)
                        val matched = hashToServer[embeddedMaster.lowercase()] ?: prefixToServer[prefix]
                        val resolvedMaster = matched?.hash ?: embeddedMaster
                        tracker.markAsProxy(
                            assetId = assetId,
                            proxySha256 = matched?.proxyHash.orEmpty(),
                            masterHash = resolvedMaster,
                            originalName = matched?.originalName ?: displayName
                        )
                        continue
                    }
                }

                eligibleCount++
                candidates.add(
                    PhotoCandidate(
                        id = assetId,
                        mediaStoreId = id,
                        isVideo = isVideo,
                        durationMs = durMs,
                        filename = displayName,
                        mimeType = mime,
                        pixelWidth = w,
                        pixelHeight = h,
                        creationDateMs = dateMs,
                        estimatedBytes = sizeBytes,
                        state = PhotoCompressionState.Pending,
                        isSelected = false
                    )
                )
            }
        }

        return candidates
    }

    fun fetchLiveAssetIds(assetIds: List<String>): List<Uri> {
        val live = mutableListOf<Uri>()
        for (raw in assetIds) {
            val uri = Uri.parse(raw)
            val exists = runCatching {
                context.contentResolver.query(
                    uri,
                    arrayOf(MediaStore.MediaColumns._ID),
                    null,
                    null,
                    null
                )?.use { it.moveToFirst() } ?: false
            }.getOrDefault(false)
            if (exists) live.add(uri)
        }
        return live
    }

    suspend fun loadThumbnail(uri: Uri, sizePx: Int = 200): Bitmap? = withContext(Dispatchers.IO) {
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                context.contentResolver.loadThumbnail(uri, Size(sizePx, sizePx), null)
            } else {
                val id = ContentUris.parseId(uri)
                @Suppress("DEPRECATION")
                MediaStore.Images.Thumbnails.getThumbnail(
                    context.contentResolver,
                    id,
                    MediaStore.Images.Thumbnails.MINI_KIND,
                    null
                )
            }
        }.getOrNull()
    }

    suspend fun exportOriginalMaster(candidate: PhotoCandidate): ExportedMaster = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val ext = candidate.filename.substringAfterLast('.', "").ifBlank {
            if (candidate.isVideo) "mp4" else "jpg"
        }
        val tempFile = File(context.cacheDir, "master_${UUID.randomUUID()}.$ext")
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(1024 * 1024)
        var total = 0L

        try {
            val input = openOriginalStreamWithFallback(resolver, candidate.contentUri)
                ?: throw IOException("Could not open original media stream.")

            input.use { stream ->
                tempFile.outputStream().use { out ->
                    while (true) {
                        val read = stream.read(buffer)
                        if (read <= 0) break
                        digest.update(buffer, 0, read)
                        out.write(buffer, 0, read)
                        total += read
                    }
                }
            }

            if (total <= 0L) throw IOException("Original media file was empty.")
            val shaHex = digest.digest().joinToString("") { "%02x".format(it) }
            ExportedMaster(
                file = tempFile,
                sha256 = shaHex,
                sizeBytes = total,
                filename = candidate.filename,
                mimeType = candidate.mimeType
            )
        } catch (err: Exception) {
            tempFile.delete()
            throw err
        }
    }

    fun openOriginalStreamWithFallback(
        resolver: android.content.ContentResolver,
        uri: Uri
    ) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && hasMediaLocationPermission()) {
        val originalUri = runCatching { MediaStore.setRequireOriginal(uri) }.getOrNull()
        val openedOriginal = if (originalUri != null) {
            try {
                resolver.openInputStream(originalUri)
            } catch (_: SecurityException) {
                null
            } catch (_: UnsupportedOperationException) {
                null
            }
        } else {
            null
        }
        openedOriginal ?: resolver.openInputStream(uri)
    } else {
        resolver.openInputStream(uri)
    }

    suspend fun saveCompressedProxyToGallery(
        originalCandidate: PhotoCandidate,
        proxyFile: File
    ): String = saveFileToGallery(
        file = proxyFile,
        isVideo = originalCandidate.isVideo,
        displayName = proxyFile.name,
        creationDateMs = originalCandidate.creationDateMs
    )

    suspend fun saveServerProxyToGallery(
        photo: ServerPhoto,
        imageData: ByteArray?,
        videoFile: File?
    ): String {
        // Strict duplicate guard: never insert a second copy into phone Gallery if ANY live copy
        // (restored original, uploaded original, synced proxy, or matching original) already exists.
        val tracker = LocalProxyTracker.getInstance(context)
        val existingTrackedUri = tracker.liveGalleryAssetUri(photo.hash)
        if (existingTrackedUri != null) {
            tracker.markMasterHandledForPhotos(photo.hash)
            return existingTrackedUri.toString()
        }
        val prefix = ProxyGenerator.proxyPrefixTag(photo.hash).ifEmpty { photo.hash.take(12) }
        val existingPrefixUri = scanExistingProxyPrefixesInGallery()[prefix]
        if (existingPrefixUri != null) {
            tracker.markAsProxy(
                assetId = existingPrefixUri,
                proxySha256 = photo.proxyHash.orEmpty(),
                masterHash = photo.hash,
                originalName = photo.originalName
            )
            return existingPrefixUri
        }
        val existingOrigUri = findMatchingOriginalAssetIdInGallery(photo)
        if (existingOrigUri != null) {
            tracker.markUploadedOriginal(existingOrigUri, photo.hash)
            tracker.markMasterHandledForPhotos(photo.hash)
            return existingOrigUri
        }

        val dateMs = photo.parsedCreationDateMs
        return if (photo.isVideo) {
            val vid = videoFile ?: throw IOException("Missing video proxy file to save.")
            val name = "${ProxyGenerator.PROXY_FILENAME_PREFIX}$prefix.mp4"
            val actualSha = runCatching { ProxyGenerator.computeFileSha256(vid) }.getOrNull().orEmpty()
            val savedId = saveFileToGallery(vid, isVideo = true, displayName = name, creationDateMs = dateMs)
            LocalProxyTracker.getInstance(context).markAsProxy(
                assetId = savedId,
                proxySha256 = actualSha.ifBlank { photo.proxyHash.orEmpty() },
                masterHash = photo.hash,
                originalName = photo.originalName,
                additionalProxyHashes = listOfNotNull(photo.proxyHash)
            )
            savedId
        } else {
            val bytes = imageData ?: throw IOException("Missing image proxy bytes to save.")
            val name = "${ProxyGenerator.PROXY_FILENAME_PREFIX}$prefix.jpg"
            val tmp = File(context.cacheDir, name)
            try {
                tmp.writeBytes(bytes)
                ProxyGenerator.embedMasterHashExifMarker(tmp, photo.hash)
                val actualSha = runCatching { ProxyGenerator.computeFileSha256(tmp) }.getOrNull().orEmpty()
                val savedId = saveFileToGallery(tmp, isVideo = false, displayName = name, creationDateMs = dateMs)
                LocalProxyTracker.getInstance(context).markAsProxy(
                    assetId = savedId,
                    proxySha256 = actualSha.ifBlank { photo.proxyHash.orEmpty() },
                    masterHash = photo.hash,
                    originalName = photo.originalName,
                    additionalProxyHashes = listOfNotNull(photo.proxyHash)
                )
                savedId
            } finally {
                tmp.delete()
            }
        }
    }

    suspend fun saveRestoredOriginalToGallery(
        file: File,
        isVideo: Boolean,
        originalFilename: String,
        creationDateMs: Long?
    ): String = saveFileToGallery(
        file = file,
        isVideo = isVideo,
        displayName = originalFilename,
        creationDateMs = creationDateMs
    )

    private suspend fun saveFileToGallery(
        file: File,
        isVideo: Boolean,
        displayName: String,
        creationDateMs: Long?
    ): String = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val inferred = ShareUtils.inferMimeType(file, fallbackName = displayName)
        val mime = if (isVideo) {
            if (inferred.startsWith("video/")) inferred else "video/mp4"
        } else {
            if (inferred.startsWith("image/")) inferred else "image/jpeg"
        }
        val collection = if (isVideo) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            if (creationDateMs != null && creationDateMs > 0L) {
                put(MediaStore.MediaColumns.DATE_TAKEN, creationDateMs)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val relDir = if (isVideo) {
                    "${Environment.DIRECTORY_MOVIES}/PhotoHub"
                } else {
                    "${Environment.DIRECTORY_PICTURES}/PhotoHub"
                }
                put(MediaStore.MediaColumns.RELATIVE_PATH, relDir)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val insertedUri = resolver.insert(collection, values)
            ?: throw IOException("Could not create MediaStore entry in Gallery.")

        try {
            val out = resolver.openOutputStream(insertedUri)
                ?: throw IOException("Could not open MediaStore output stream.")
            out.use { output ->
                file.inputStream().use { input ->
                    input.copyTo(output, bufferSize = 64 * 1024)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val doneValues = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                resolver.update(insertedUri, doneValues, null, null)
            }
            insertedUri.toString()
        } catch (err: Exception) {
            runCatching { resolver.delete(insertedUri, null, null) }
            throw err
        }
    }

    /**
     * Requests native Android Trash confirmation on Android 11+ (move to Trash for 30 days,
     * mirroring Apple Photos Recently Deleted), or handles deletion cleanly on older Android versions.
     */
    fun prepareTrashOrDeleteOriginals(assetIds: List<String>): TrashOrDeleteRequestResult {
        val uris = fetchLiveAssetIds(assetIds.distinct())
        if (uris.isEmpty()) {
            return TrashOrDeleteRequestResult.DeletedImmediately(assetIds)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val pi: PendingIntent = MediaStore.createTrashRequest(context.contentResolver, uris, true)
            return TrashOrDeleteRequestResult.NeedsSystemConfirmation(
                intentSender = pi.intentSender,
                targetIds = uris.map { it.toString() }
            )
        }

        val deletedIds = mutableListOf<String>()
        for (uri in uris) {
            try {
                val count = context.contentResolver.delete(uri, null, null)
                if (count > 0) deletedIds.add(uri.toString())
            } catch (sec: SecurityException) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && sec is RecoverableSecurityException) {
                    return TrashOrDeleteRequestResult.NeedsSystemConfirmation(
                        intentSender = sec.userAction.actionIntent.intentSender,
                        targetIds = listOf(uri.toString())
                    )
                }
                throw sec
            }
        }
        return TrashOrDeleteRequestResult.DeletedImmediately(deletedIds)
    }

    /**
     * Finds live compressed proxy URIs in Gallery matching `masterHashes`,
     * strictly excluding any restored full-resolution original URIs.
     */
    suspend fun findCompressedProxyAssetIds(
        tracker: LocalProxyTracker,
        masterHashes: Set<String>
    ): List<String> = withContext(Dispatchers.IO) {
        if (currentAccessLevel() == MediaAccessLevel.DENIED) return@withContext emptyList()
        val normHashes = masterHashes
            .map { it.trim().lowercase() }
            .filter { it.isNotEmpty() }
            .toSet()
        if (normHashes.isEmpty()) return@withContext emptyList()

        val candidates = linkedSetOf<String>()
        candidates.addAll(tracker.trackedProxyAssetIds(normHashes))

        val targetPrefixes = normHashes
            .map { ProxyGenerator.proxyPrefixTag(it) }
            .filter { it.length >= 8 }
            .toSet()
        if (targetPrefixes.isNotEmpty()) {
            val prefixMap = scanExistingProxyPrefixesInGalleryAll()
            for (prefix in targetPrefixes) {
                prefixMap[prefix]?.let { candidates.addAll(it) }
            }
        }

        val filtered = candidates.filterNot { tracker.isRestoredOriginal(it) }
        if (filtered.isEmpty()) return@withContext emptyList()

        val verified = mutableListOf<String>()
        for (uri in fetchLiveAssetIds(filtered)) {
            val uriStr = uri.toString()
            if (tracker.isRestoredOriginal(uriStr)) continue
            val (displayName, diskPath) = queryMediaFileInfo(uri)
            val candidateName = displayName ?: diskPath?.let { File(it).name }
            val isProxyByName = candidateName?.let { ProxyGenerator.extractMasterHashPrefix(it) != null } == true
            if (tracker.isKnownProxy(uriStr) || isProxyByName) {
                verified.add(uriStr)
            }
        }
        verified
    }

    /**
     * Deletes verified compressed proxy copies from Gallery after originals have been restored.
     * App-owned proxies (and devices with All Files Access) are removed silently; any remaining
     * system-protected URIs are batched into a single MediaStore delete confirmation request on API 30+.
     */
    suspend fun deleteCompressedProxiesAfterRestore(
        tracker: LocalProxyTracker,
        assetIds: List<String>
    ): CompressedProxyDeleteResult = withContext(Dispatchers.IO) {
        val liveUris = fetchLiveAssetIds(assetIds.distinct())
        if (liveUris.isEmpty()) {
            return@withContext CompressedProxyDeleteResult.Deleted(emptyList())
        }

        val resolver = context.contentResolver
        val deletedIds = mutableListOf<String>()
        val batchPromptUris = mutableListOf<Uri>()
        val recoverableItems = mutableListOf<Pair<String, IntentSender>>()

        for (uri in liveUris) {
            val uriStr = uri.toString()
            if (tracker.isRestoredOriginal(uriStr)) continue
            val (displayName, diskPath) = queryMediaFileInfo(uri)
            val candidateName = displayName ?: diskPath?.let { File(it).name }
            val isProxyByName = candidateName?.let { ProxyGenerator.extractMasterHashPrefix(it) != null } == true
            if (!tracker.isKnownProxy(uriStr) && !isProxyByName) continue

            var deleted = false
            var recoverableSender: IntentSender? = null

            try {
                val count = resolver.delete(uri, null, null)
                if (count > 0 || fetchLiveAssetIds(listOf(uriStr)).isEmpty()) {
                    deleted = true
                }
            } catch (sec: SecurityException) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.R &&
                    sec is RecoverableSecurityException
                ) {
                    recoverableSender = sec.userAction.actionIntent.intentSender
                }
            }

            if (!deleted && diskPath != null && hasAllFilesAccess()) {
                val file = File(diskPath)
                val removedFile = !file.exists() || runCatching { file.delete() }.getOrDefault(false) || !file.exists()
                if (removedFile) {
                    runCatching { resolver.delete(uri, null, null) }
                    MediaScannerConnection.scanFile(context, arrayOf(diskPath), null, null)
                    deleted = !File(diskPath).exists()
                }
            }

            if (deleted) {
                deletedIds.add(uriStr)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                batchPromptUris.add(uri)
            } else if (recoverableSender != null) {
                recoverableItems.add(uriStr to recoverableSender)
            }
        }

        if (deletedIds.isNotEmpty()) {
            tracker.clearProxyMappings(deletedIds)
        }

        if (batchPromptUris.isNotEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val pi: PendingIntent = MediaStore.createDeleteRequest(resolver, batchPromptUris)
            return@withContext CompressedProxyDeleteResult.NeedsSystemConfirmation(
                intentSender = pi.intentSender,
                targetIds = batchPromptUris.map { it.toString() },
                alreadyDeletedIds = deletedIds,
                remainingIds = emptyList()
            )
        }

        if (recoverableItems.isNotEmpty()) {
            return@withContext CompressedProxyDeleteResult.NeedsSystemConfirmation(
                intentSender = recoverableItems.first().second,
                targetIds = listOf(recoverableItems.first().first),
                alreadyDeletedIds = deletedIds,
                remainingIds = recoverableItems.drop(1).map { it.first }
            )
        }

        CompressedProxyDeleteResult.Deleted(deletedIds)
    }

    /**
     * Silently deletes a verified original without a system confirmation dialog when
     * All Files Access (`MANAGE_EXTERNAL_STORAGE` on Android 11+, or legacy storage write on <= 9) is active.
     * Refuses to delete any PhotoHub compressed proxy filename or restored-protected asset.
     */
    suspend fun trySilentDeleteOriginal(assetId: String): Boolean = withContext(Dispatchers.IO) {
        if (!canSilentlyDeleteOriginals()) return@withContext false
        val tracker = LocalProxyTracker.getInstance(context)
        if (tracker.isKnownProxy(assetId) || tracker.isRestoredOriginal(assetId)) {
            return@withContext false
        }

        val uri = Uri.parse(assetId)
        val (displayName, diskPath) = queryMediaFileInfo(uri)
        val candidateName = displayName ?: diskPath?.let { File(it).name }
        if (candidateName != null && !isSafeSilentDeleteFilename(candidateName)) {
            return@withContext false
        }

        val resolverDeleted = runCatching {
            context.contentResolver.delete(uri, null, null) > 0
        }.getOrDefault(false)

        if (diskPath != null && hasAllFilesAccess()) {
            val file = File(diskPath)
            if (file.exists()) {
                val fileDeleted = runCatching { file.delete() }.getOrDefault(false)
                if (fileDeleted || !file.exists()) {
                    runCatching { context.contentResolver.delete(uri, null, null) }
                    MediaScannerConnection.scanFile(context, arrayOf(diskPath), null, null)
                }
            }
            return@withContext !File(diskPath).exists()
        }

        resolverDeleted || fetchLiveAssetIds(listOf(assetId)).isEmpty()
    }

    private fun queryMediaFileInfo(uri: Uri): Pair<String?, String?> {
        val projection = arrayOf(
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.DATA
        )
        return runCatching {
            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                    val dataIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                    val name = if (nameIdx >= 0) cursor.getString(nameIdx) else null
                    val path = if (dataIdx >= 0) cursor.getString(dataIdx) else null
                    name to path
                } else {
                    null to null
                }
            } ?: (null to null)
        }.getOrDefault(null to null)
    }

    suspend fun findLatestImageCandidate(tracker: LocalProxyTracker): PhotoCandidate? = withContext(Dispatchers.IO) {
        scanCandidates(tracker = tracker, maxResults = 1, maxInspect = 30).firstOrNull()
    }

    companion object {
        fun isSafeSilentDeleteFilename(filenameOrPath: String): Boolean {
            val trimmed = filenameOrPath.trim()
            if (trimmed.isEmpty()) return false
            return ProxyGenerator.extractMasterHashPrefix(File(trimmed).name) == null
        }

        fun galleryReadWritePermissions(): Array<String> = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VIDEO,
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
            )
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VIDEO
            )
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> arrayOf(
                Manifest.permission.READ_EXTERNAL_STORAGE
            )
            else -> arrayOf(
                Manifest.permission.READ_EXTERNAL_STORAGE,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            )
        }
    }
}

sealed class CompressedProxyDeleteResult {
    data class Deleted(val deletedIds: List<String>) : CompressedProxyDeleteResult()
    data class NeedsSystemConfirmation(
        val intentSender: IntentSender,
        val targetIds: List<String>,
        val alreadyDeletedIds: List<String>,
        val remainingIds: List<String>
    ) : CompressedProxyDeleteResult()
}
