package com.photohub.compressor.sync

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.photohub.compressor.data.ServerPhoto
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import org.json.JSONArray
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class LocalProxyStore private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val lock = Any()
    private val rootDir = File(appContext.filesDir, "PhotoHubLocalProxies")
    private val previewsDir = File(rootDir, "previews")
    private val videosDir = File(rootDir, "videos")
    private val ioExecutor = Executors.newSingleThreadScheduledExecutor()

    private val indexMemoryCache = mutableMapOf<String, List<ServerPhoto>>()
    private val pendingIndexFlushes = mutableMapOf<String, ScheduledFuture<*>>()
    private var cacheWriteCounter = 0
    private var isTrimmingDiskCache = false

    private val _changes = MutableSharedFlow<Unit>(extraBufferCapacity = 16)
    val changes: SharedFlow<Unit> = _changes.asSharedFlow()

    init {
        ensureDirsLocked()
    }

    private fun ensureDirsLocked() {
        rootDir.mkdirs()
        previewsDir.mkdirs()
        videosDir.mkdirs()
    }

    private fun safeHash(hash: String): String {
        val clean = hash.lowercase().filter { it in '0'..'9' || it in 'a'..'f' || it == '-' || it == '_' }
        return clean.ifEmpty { "unknown" }
    }

    private fun indexFile(baseUrl: String?, scopeKey: String): File {
        val raw = "${baseUrl.orEmpty().ifEmpty { "none" }}|${scopeKey.trim()}"
        val digest = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray(Charsets.UTF_8))
        val hex = digest.joinToString("") { "%02x".format(it) }
        return File(rootDir, "index_${hex.take(24)}.json")
    }

    private fun previewFile(hash: String): File = File(previewsDir, "${safeHash(hash)}.dat")
    private fun videoFile(hash: String): File = File(videosDir, "${safeHash(hash)}.mp4")

    private fun loadIndexLocked(file: File): List<ServerPhoto> {
        val key = file.absolutePath
        indexMemoryCache[key]?.let { return it }
        if (!file.exists()) return emptyList()
        val parsed = try {
            ServerPhoto.listFromJsonArray(JSONArray(file.readText()))
        } catch (_: Exception) {
            emptyList()
        }
        indexMemoryCache[key] = parsed
        return parsed
    }

    private fun scheduleIndexFlushLocked(file: File, immediate: Boolean) {
        val key = file.absolutePath
        pendingIndexFlushes.remove(key)?.cancel(false)
        val task = Runnable {
            val snapshot = synchronized(lock) {
                pendingIndexFlushes.remove(key)
                ensureDirsLocked()
                indexMemoryCache[key]
            } ?: return@Runnable
            runCatching {
                val tmp = File(file.parentFile, "${file.name}.tmp")
                tmp.writeText(ServerPhoto.listToJsonArray(snapshot).toString())
                if (!tmp.renameTo(file)) {
                    file.writeText(ServerPhoto.listToJsonArray(snapshot).toString())
                    tmp.delete()
                }
            }
        }
        val delayMs = if (immediate) 0L else 350L
        pendingIndexFlushes[key] = ioExecutor.schedule(task, delayMs, TimeUnit.MILLISECONDS)
    }

    fun cachedPhotos(baseUrl: String?, scopeKey: String): List<ServerPhoto> = synchronized(lock) {
        loadIndexLocked(indexFile(baseUrl, scopeKey))
    }

    fun savePhotos(photos: List<ServerPhoto>, baseUrl: String?, scopeKey: String) {
        synchronized(lock) {
            ensureDirsLocked()
            val file = indexFile(baseUrl, scopeKey)
            indexMemoryCache[file.absolutePath] = photos
            scheduleIndexFlushLocked(file, immediate = true)
        }
    }

    fun upsertPhoto(photo: ServerPhoto, baseUrl: String?, scopeKey: String) {
        mutateIndex(baseUrl, scopeKey, notify = true) { list ->
            list.removeAll { it.hash.equals(photo.hash, ignoreCase = true) }
            list.add(0, photo)
        }
    }

    fun updatePhoto(photo: ServerPhoto, baseUrl: String?, scopeKey: String, notify: Boolean = false) {
        updatePhotos(listOf(photo), baseUrl, scopeKey, notify)
    }

    fun updatePhotos(photos: List<ServerPhoto>, baseUrl: String?, scopeKey: String, notify: Boolean = false) {
        if (photos.isEmpty()) return
        mutateIndex(baseUrl, scopeKey, notify = notify) { list ->
            val indexByHash = HashMap<String, Int>(list.size * 2)
            for (i in list.indices) {
                indexByHash[list[i].hash.lowercase()] = i
            }
            val toPrepend = mutableListOf<ServerPhoto>()
            for (photo in photos) {
                val key = photo.hash.lowercase()
                val idx = indexByHash[key]
                if (idx != null) {
                    list[idx] = photo
                } else {
                    toPrepend.add(photo)
                }
            }
            if (toPrepend.isNotEmpty()) {
                list.addAll(0, toPrepend)
            }
        }
    }

    fun removePhoto(hash: String, baseUrl: String?, scopeKey: String, notify: Boolean = true) {
        removePhotos(listOf(hash), baseUrl, scopeKey, notify)
    }

    fun removePhotos(hashes: Collection<String>, baseUrl: String?, scopeKey: String, notify: Boolean = true) {
        val targetSet = hashes
            .map { it.trim().lowercase() }
            .filter { it.isNotEmpty() }
            .toSet()
        if (targetSet.isEmpty()) return

        synchronized(lock) {
            ensureDirsLocked()
            val file = indexFile(baseUrl, scopeKey)
            val current = loadIndexLocked(file).toMutableList()
            if (current.isNotEmpty()) {
                val changed = current.removeAll { it.hash.trim().lowercase() in targetSet }
                if (changed) {
                    indexMemoryCache[file.absolutePath] = current
                    scheduleIndexFlushLocked(file, immediate = true)
                }
            }
            for (h in targetSet) {
                runCatching { previewFile(h).delete() }
                runCatching { videoFile(h).delete() }
            }
        }
        if (notify) {
            _changes.tryEmit(Unit)
        }
    }

    private fun mutateIndex(
        baseUrl: String?,
        scopeKey: String,
        notify: Boolean,
        block: (MutableList<ServerPhoto>) -> Unit
    ) {
        synchronized(lock) {
            ensureDirsLocked()
            val file = indexFile(baseUrl, scopeKey)
            val list = loadIndexLocked(file).toMutableList()
            block(list)
            indexMemoryCache[file.absolutePath] = list
            scheduleIndexFlushLocked(file, immediate = false)
        }
        if (notify) {
            _changes.tryEmit(Unit)
        }
    }

    fun previewData(hash: String): ByteArray? = synchronized(lock) {
        val file = previewFile(hash)
        if (!file.exists()) null else runCatching { file.readBytes() }.getOrNull()
    }

    /**
     * Decodes a compact downsampled RGB_565 grid thumbnail (default 320px) directly from the cached
     * preview file, using ~50% less RAM per pixel than ARGB_8888 and avoiding full-size allocations.
     */
    fun decodeGridThumbnailBitmap(hash: String, maxPixelSize: Int = 320): Bitmap? {
        val data = previewData(hash) ?: return null
        return decodeGridThumbnailFromBytes(data, maxPixelSize)
    }

    fun decodeGridThumbnailFromBytes(rawData: ByteArray, maxPixelSize: Int = 320): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(rawData, 0, rawData.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val maxDim = maxOf(bounds.outWidth, bounds.outHeight)
        var inSample = 1
        while (maxDim / inSample > maxPixelSize * 2) {
            inSample *= 2
        }
        val opts = BitmapFactory.Options().apply {
            inSampleSize = inSample
            inPreferredConfig = Bitmap.Config.RGB_565
        }
        return BitmapFactory.decodeByteArray(rawData, 0, rawData.size, opts)
    }

    fun savePreviewData(data: ByteArray, hash: String) {
        if (data.isEmpty()) return
        var shouldTrim = false
        synchronized(lock) {
            ensureDirsLocked()
            previewFile(hash).writeBytes(data)
            cacheWriteCounter++
            if (cacheWriteCounter % 32 == 0 && !isTrimmingDiskCache) {
                isTrimmingDiskCache = true
                shouldTrim = true
            }
        }
        if (shouldTrim) scheduleDiskCacheTrim()
    }

    fun copyPreviewFile(source: File, hash: String) {
        if (!source.exists()) return
        runCatching { source.readBytes() }.getOrNull()?.let { savePreviewData(it, hash) }
    }

    fun makeSmallCompressedPreview(
        rawData: ByteArray,
        maxPixelSize: Int = 800,
        quality: Int = 65
    ): Pair<Bitmap, ByteArray>? {
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(rawData, 0, rawData.size, opts)
        if (opts.outWidth <= 0 || opts.outHeight <= 0) return null

        val maxDim = maxOf(opts.outWidth, opts.outHeight)
        var inSample = 1
        while (maxDim / inSample > maxPixelSize * 2) {
            inSample *= 2
        }
        val decodeOpts = BitmapFactory.Options().apply { inSampleSize = inSample }
        val sampled = BitmapFactory.decodeByteArray(rawData, 0, rawData.size, decodeOpts) ?: return null

        val curMax = maxOf(sampled.width, sampled.height)
        val finalBmp = if (curMax > maxPixelSize) {
            val scale = maxPixelSize.toFloat() / curMax.toFloat()
            val w = (sampled.width * scale).toInt().coerceAtLeast(1)
            val h = (sampled.height * scale).toInt().coerceAtLeast(1)
            Bitmap.createScaledBitmap(sampled, w, h, true).also {
                if (it !== sampled) sampled.recycle()
            }
        } else {
            sampled
        }

        val baos = ByteArrayOutputStream()
        finalBmp.compress(Bitmap.CompressFormat.JPEG, quality, baos)
        return finalBmp to baos.toByteArray()
    }

    fun cacheDownloadedPreview(
        rawData: ByteArray,
        hash: String,
        maxPixelSize: Int = 800,
        quality: Int = 65
    ): Pair<Bitmap, ByteArray>? {
        val compressed = makeSmallCompressedPreview(rawData, maxPixelSize, quality)
        if (compressed != null) {
            savePreviewData(compressed.second, hash)
            return compressed
        }
        val direct = BitmapFactory.decodeByteArray(rawData, 0, rawData.size)
        if (direct != null) {
            savePreviewData(rawData, hash)
            return direct to rawData
        }
        return null
    }

    fun cacheDownloadedPreviewData(
        rawData: ByteArray,
        hash: String,
        maxPixelSize: Int = 800,
        quality: Int = 65
    ): ByteArray? = cacheDownloadedPreview(rawData, hash, maxPixelSize, quality)?.second

    fun videoProxyFileIfExists(hash: String): File? = synchronized(lock) {
        val f = videoFile(hash)
        if (f.exists() && f.length() > 0L) f else null
    }

    fun copyVideoProxy(source: File, hash: String): File? {
        if (!source.exists()) return null
        var shouldTrim = false
        val copied = synchronized(lock) {
            ensureDirsLocked()
            val dest = videoFile(hash)
            runCatching {
                source.copyTo(dest, overwrite = true)
                cacheWriteCounter++
                if (!isTrimmingDiskCache) {
                    isTrimmingDiskCache = true
                    shouldTrim = true
                }
                dest
            }.getOrNull()
        }
        if (shouldTrim) scheduleDiskCacheTrim()
        return copied
    }

    private fun scheduleDiskCacheTrim() {
        ioExecutor.execute {
            try {
                val files = mutableListOf<File>()
                var totalBytes = 0L
                for (dir in listOf(previewsDir, videosDir)) {
                    dir.listFiles()?.forEach { f ->
                        if (f.isFile) {
                            files.add(f)
                            totalBytes += f.length()
                        }
                    }
                }
                if (totalBytes <= MAX_DISK_CACHE_BYTES) return@execute
                files.sortBy { it.lastModified() }
                for (f in files) {
                    if (totalBytes <= TRIM_TARGET_DISK_BYTES) break
                    val len = f.length()
                    if (runCatching { f.delete() }.getOrDefault(false)) {
                        totalBytes -= len
                    }
                }
            } finally {
                synchronized(lock) { isTrimmingDiskCache = false }
            }
        }
    }

    fun totalStorageBytes(): Long = synchronized(lock) {
        var total = 0L
        listOf(previewsDir, videosDir).forEach { dir ->
            dir.listFiles()?.forEach { f ->
                if (f.isFile) total += f.length()
            }
        }
        total
    }

    fun clearAll() {
        synchronized(lock) {
            pendingIndexFlushes.values.forEach { it.cancel(false) }
            pendingIndexFlushes.clear()
            indexMemoryCache.clear()
            previewsDir.deleteRecursively()
            videosDir.deleteRecursively()
            ensureDirsLocked()
        }
        _changes.tryEmit(Unit)
    }

    fun notifyChanged() {
        _changes.tryEmit(Unit)
    }

    companion object {
        private const val MAX_DISK_CACHE_BYTES = 600L * 1024L * 1024L // 600 MB LRU cap
        private const val TRIM_TARGET_DISK_BYTES = 480L * 1024L * 1024L

        @Volatile
        private var instance: LocalProxyStore? = null

        fun getInstance(context: Context): LocalProxyStore =
            instance ?: synchronized(this) {
                instance ?: LocalProxyStore(context).also { instance = it }
            }
    }
}
