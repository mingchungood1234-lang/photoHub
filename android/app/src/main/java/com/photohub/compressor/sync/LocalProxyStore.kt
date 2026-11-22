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

class LocalProxyStore private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val lock = Any()
    private val rootDir = File(appContext.filesDir, "PhotoHubLocalProxies")
    private val previewsDir = File(rootDir, "previews")
    private val videosDir = File(rootDir, "videos")

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

    fun cachedPhotos(baseUrl: String?, scopeKey: String): List<ServerPhoto> = synchronized(lock) {
        val file = indexFile(baseUrl, scopeKey)
        if (!file.exists()) return emptyList()
        return try {
            ServerPhoto.listFromJsonArray(JSONArray(file.readText()))
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun savePhotos(photos: List<ServerPhoto>, baseUrl: String?, scopeKey: String) {
        synchronized(lock) {
            ensureDirsLocked()
            val file = indexFile(baseUrl, scopeKey)
            file.writeText(ServerPhoto.listToJsonArray(photos).toString())
        }
    }

    fun upsertPhoto(photo: ServerPhoto, baseUrl: String?, scopeKey: String) {
        mutateIndex(baseUrl, scopeKey, notify = true) { list ->
            list.removeAll { it.hash.equals(photo.hash, ignoreCase = true) }
            list.add(0, photo)
        }
    }

    fun updatePhoto(photo: ServerPhoto, baseUrl: String?, scopeKey: String, notify: Boolean = false) {
        mutateIndex(baseUrl, scopeKey, notify = notify) { list ->
            val idx = list.indexOfFirst { it.hash.equals(photo.hash, ignoreCase = true) }
            if (idx >= 0) {
                list[idx] = photo
            } else {
                list.add(0, photo)
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
            if (file.exists()) {
                val list = try {
                    ServerPhoto.listFromJsonArray(JSONArray(file.readText())).toMutableList()
                } catch (_: Exception) {
                    mutableListOf()
                }
                val changed = list.removeAll { it.hash.trim().lowercase() in targetSet }
                if (changed) {
                    file.writeText(ServerPhoto.listToJsonArray(list).toString())
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
            val list = if (file.exists()) {
                try {
                    ServerPhoto.listFromJsonArray(JSONArray(file.readText())).toMutableList()
                } catch (_: Exception) {
                    mutableListOf()
                }
            } else {
                mutableListOf()
            }
            block(list)
            file.writeText(ServerPhoto.listToJsonArray(list).toString())
        }
        if (notify) {
            _changes.tryEmit(Unit)
        }
    }

    fun previewData(hash: String): ByteArray? = synchronized(lock) {
        val file = previewFile(hash)
        if (!file.exists()) null else runCatching { file.readBytes() }.getOrNull()
    }

    fun savePreviewData(data: ByteArray, hash: String) {
        if (data.isEmpty()) return
        synchronized(lock) {
            ensureDirsLocked()
            previewFile(hash).writeBytes(data)
        }
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
        return synchronized(lock) {
            ensureDirsLocked()
            val dest = videoFile(hash)
            runCatching {
                source.copyTo(dest, overwrite = true)
                dest
            }.getOrNull()
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
        @Volatile
        private var instance: LocalProxyStore? = null

        fun getInstance(context: Context): LocalProxyStore =
            instance ?: synchronized(this) {
                instance ?: LocalProxyStore(context).also { instance = it }
            }
    }
}
