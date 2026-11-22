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

    fun scanExistingProxyPrefixesInGallery(): Map<String, String> {
        val resolver = context.contentResolver
        val collection = MediaStore.Files.getContentUri("external")
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.DISPLAY_NAME
        )
        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?) AND ${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ?"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
            "${ProxyGenerator.PROXY_FILENAME_PREFIX}%"
        )

        val result = mutableMapOf<String, String>()
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
                    result[prefix] = contentUri.toString()
                }
            }
        }
        return result
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
        var detectedProxyCount = 0
        val maxProxyRows = maxResults ?: 300

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

                fun makeCandidate(
                    state: PhotoCompressionState,
                    masterHash: String? = null,
                    detectionSource: String? = null,
                    linkedServer: ServerPhoto? = null
                ) = PhotoCandidate(
                    id = assetId,
                    mediaStoreId = id,
                    isVideo = isVideo,
                    durationMs = durMs,
                    filename = linkedServer?.originalName ?: displayName,
                    mimeType = mime,
                    pixelWidth = w,
                    pixelHeight = h,
                    creationDateMs = dateMs,
                    estimatedBytes = sizeBytes,
                    state = state,
                    isSelected = false,
                    masterHash = masterHash,
                    detectionSource = detectionSource,
                    linkedOriginalName = linkedServer?.originalName,
                    linkedOriginalBytes = linkedServer?.size,
                    isBackedUpOnServer = linkedServer != null
                )

                // 1. Tracked proxy in LocalProxyTracker
                if (tracker.isKnownProxy(assetId)) {
                    val match = tracker.masterLookup(assetId)
                    val linkedServer = match?.masterHash?.let { hashToServer[it.lowercase()] }
                    if (detectedProxyCount < maxProxyRows) {
                        candidates.add(
                            makeCandidate(
                                state = PhotoCompressionState.AlreadyProxy,
                                masterHash = match?.masterHash,
                                detectionSource = "Tracked Proxy",
                                linkedServer = linkedServer
                            )
                        )
                        detectedProxyCount++
                    }
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
                    if (detectedProxyCount < maxProxyRows) {
                        candidates.add(
                            makeCandidate(
                                state = PhotoCompressionState.AlreadyProxy,
                                masterHash = matched?.hash,
                                detectionSource = "Filename Tag",
                                linkedServer = matched
                            )
                        )
                        detectedProxyCount++
                    }
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
                        if (detectedProxyCount < maxProxyRows) {
                            candidates.add(
                                makeCandidate(
                                    state = PhotoCompressionState.AlreadyProxy,
                                    masterHash = resolvedMaster,
                                    detectionSource = "EXIF Metadata",
                                    linkedServer = matched
                                )
                            )
                            detectedProxyCount++
                        }
                        continue
                    }
                }

                eligibleCount++
                candidates.add(makeCandidate(state = PhotoCompressionState.Pending))
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
        val prefix = ProxyGenerator.proxyPrefixTag(photo.hash).ifEmpty { photo.hash.take(12) }
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
        val ext = displayName.substringAfterLast('.', "").lowercase()
        val mime = when {
            isVideo -> "video/mp4"
            ext == "heic" || ext == "heif" -> "image/heic"
            ext == "png" -> "image/png"
            else -> "image/jpeg"
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
    }
}
