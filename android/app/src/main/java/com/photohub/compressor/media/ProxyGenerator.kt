package com.photohub.compressor.media

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.exifinterface.media.ExifInterface
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import com.photohub.compressor.data.ProxyFormat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

data class GeneratedProxy(
    val file: File,
    val sha256: String,
    val sizeBytes: Long,
    val posterFile: File? = null
)

object ProxyGenerator {
    const val PROXY_FILENAME_PREFIX = "PHOTOHUB_PROXY_"
    const val PROXY_MARKER_PREFIX = "PhotoHubProxy:"

    fun proxyPrefixTag(masterHash: String): String =
        extractLowercaseHexPrefix(masterHash, maxLength = 16)

    fun extractMasterHashPrefix(filename: String): String? {
        val base = File(filename).nameWithoutExtension
        if (!base.uppercase(Locale.ROOT).startsWith(PROXY_FILENAME_PREFIX)) return null
        val suffix = base.substring(PROXY_FILENAME_PREFIX.length)
        val hex = extractLowercaseHexPrefix(suffix, maxLength = 16)
        return hex.takeIf { it.length >= 8 }
    }

    fun makeTaggedProxyTempFile(
        context: Context,
        masterHash: String?,
        ext: String,
        fallbackPrefix: String = "proxy"
    ): File {
        val cleanMaster = masterHash?.let { proxyPrefixTag(it) }?.takeIf { it.length >= 8 }
        if (cleanMaster != null) {
            val subdir = File(context.cacheDir, "phproxy_${UUID.randomUUID()}")
            if (subdir.mkdirs() || subdir.exists()) {
                return File(subdir, "$PROXY_FILENAME_PREFIX$cleanMaster.$ext")
            }
            return File(context.cacheDir, "${PROXY_FILENAME_PREFIX}${cleanMaster}_${UUID.randomUUID().toString().take(8)}.$ext")
        }
        return File(context.cacheDir, "${fallbackPrefix}_${UUID.randomUUID()}.$ext")
    }

    fun cleanupTempFile(file: File?) {
        file ?: return
        runCatching { file.delete() }
        val parent = file.parentFile
        if (parent != null && parent.name.startsWith("phproxy_")) {
            runCatching { parent.delete() }
        }
    }

    fun isFullSha256Hex(raw: String?): Boolean {
        val trimmed = raw?.trim() ?: return false
        return trimmed.length == 64 && trimmed.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
    }

    /** Writes `PhotoHubProxy:<masterHash>` EXIF metadata into a compressed JPEG proxy for cross-app identification. */
    fun embedMasterHashExifMarker(jpegFile: File, masterHash: String?): Boolean {
        val cleanMaster = cleanMasterHashString(masterHash) ?: return false
        return runCatching {
            val exif = ExifInterface(jpegFile)
            val marker = "$PROXY_MARKER_PREFIX$cleanMaster"
            exif.setAttribute(ExifInterface.TAG_SOFTWARE, "PhotoHub Proxy")
            exif.setAttribute(ExifInterface.TAG_IMAGE_DESCRIPTION, marker)
            exif.setAttribute(ExifInterface.TAG_USER_COMMENT, marker)
            exif.saveAttributes()
            true
        }.getOrDefault(false)
    }

    /** Extracts embedded `PhotoHubProxy:<masterHash>` marker from a JPEG/image stream without needing a file path. */
    fun extractEmbeddedProxyMasterHashFromStream(inputStream: InputStream): String? {
        return try {
            val exif = ExifInterface(inputStream)
            parseExifProxyMarker(exif)
        } catch (_: Exception) {
            null
        }
    }

    private fun parseExifProxyMarker(exif: ExifInterface): String? {
        val comment = exif.getAttribute(ExifInterface.TAG_USER_COMMENT)
        val desc = exif.getAttribute(ExifInterface.TAG_IMAGE_DESCRIPTION)
        return parseMarkerHash(comment) ?: parseMarkerHash(desc)
    }

    fun extractEmbeddedProxyMasterHash(file: File, isVideo: Boolean): String? {
        if (!isVideo) {
            try {
                val exifHash = parseExifProxyMarker(ExifInterface(file))
                if (exifHash != null) return exifHash
            } catch (_: Exception) {
                // Fall back to container / filename scan below.
            }
        } else {
            // QuickTime / MP4 proxies created on iOS store `PhotoHubProxy:<masterHash>` in container atoms.
            val containerHash = runCatching { extractProxyMarkerFromVideoContainer(file) }.getOrNull()
            if (containerHash != null) return containerHash
        }
        return extractMasterHashPrefix(file.name)
    }

    /**
     * Scans the leading & trailing container metadata chunks (up to 256 KB each) of an MP4/MOV
     * file for an embedded UTF-8 `PhotoHubProxy:<masterHash>` marker without external muxer deps.
     */
    fun extractProxyMarkerFromVideoContainer(file: File): String? {
        val len = file.length()
        if (len <= 0L) return null
        val chunkLimit = 256 * 1024
        java.io.RandomAccessFile(file, "r").use { raf ->
            val headSize = minOf(len, chunkLimit.toLong()).toInt()
            val headBuf = ByteArray(headSize)
            raf.readFully(headBuf)
            findProxyMarkerInByteArray(headBuf)?.let { return it }

            if (len > chunkLimit.toLong()) {
                val tailOffset = (len - chunkLimit.toLong()).coerceAtLeast(0L)
                raf.seek(tailOffset)
                val tailSize = (len - tailOffset).toInt()
                val tailBuf = ByteArray(tailSize)
                raf.readFully(tailBuf)
                findProxyMarkerInByteArray(tailBuf)?.let { return it }
            }
        }
        return null
    }

    fun findProxyMarkerInByteArray(bytes: ByteArray): String? {
        if (bytes.size < PROXY_MARKER_PREFIX.length + 8) return null
        val text = String(bytes, Charsets.ISO_8859_1)
        return parseMarkerHash(text)
    }

    fun computeStreamSha256(input: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(1024 * 1024)
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) break
            digest.update(buffer, 0, read)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    suspend fun createImageProxy(
        context: Context,
        masterFile: File,
        format: ProxyFormat,
        maxPixelSize: Int,
        quality: Float,
        masterHash: String? = null
    ): GeneratedProxy = withContext(Dispatchers.Default) {
        val boundsOpts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(masterFile.absolutePath, boundsOpts)
        val srcWidth = boundsOpts.outWidth
        val srcHeight = boundsOpts.outHeight
        if (srcWidth <= 0 || srcHeight <= 0) {
            throw IOException("Could not open original photo for proxy generation.")
        }

        val longestEdge = maxOf(srcWidth, srcHeight)
        val targetMaxPx = if (maxPixelSize <= 0) {
            when {
                longestEdge > 4096 -> 1920
                longestEdge > 2048 -> 1440
                longestEdge > 1280 -> 1024
                longestEdge > 0 -> maxOf(640, (longestEdge * 0.75).toInt())
                else -> 1440
            }
        } else {
            minOf(longestEdge, maxPixelSize)
        }

        val oriRotation = readExifRotationDegrees(masterFile)
        val masterSize = masterFile.length().takeIf { it > 0L } ?: Long.MAX_VALUE

        val firstPass = runCatching {
            encodeDownsampledJpeg(
                context = context,
                masterFile = masterFile,
                maxPixelSize = targetMaxPx,
                qualityPercent = (quality * 100f).toInt().coerceIn(35, 95),
                rotationDegrees = oriRotation,
                masterHash = masterHash
            )
        }.getOrNull()

        if (firstPass != null && firstPass.sizeBytes < masterSize) {
            return@withContext firstPass
        }
        firstPass?.let { cleanupTempFile(it.file) }

        val fallbackPx = maxOf(512, (targetMaxPx * 0.7).toInt())
        val fallbackPct = minOf(50, (quality * 100f).toInt().coerceIn(30, 80))
        encodeDownsampledJpeg(
            context = context,
            masterFile = masterFile,
            maxPixelSize = fallbackPx,
            qualityPercent = fallbackPct,
            rotationDegrees = oriRotation,
            masterHash = masterHash
        )
    }

    private fun readExifRotationDegrees(file: File): Int = try {
        val exif = ExifInterface(file)
        when (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90
            ExifInterface.ORIENTATION_ROTATE_180 -> 180
            ExifInterface.ORIENTATION_ROTATE_270 -> 270
            else -> 0
        }
    } catch (_: Exception) {
        0
    }

    private fun encodeDownsampledJpeg(
        context: Context,
        masterFile: File,
        maxPixelSize: Int,
        qualityPercent: Int,
        rotationDegrees: Int,
        masterHash: String?
    ): GeneratedProxy {
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(masterFile.absolutePath, opts)
        val maxDim = maxOf(opts.outWidth, opts.outHeight)
        var inSample = 1
        while (maxDim / inSample > maxPixelSize * 2) {
            inSample *= 2
        }

        val decodeOpts = BitmapFactory.Options().apply { inSampleSize = inSample }
        val decoded = BitmapFactory.decodeFile(masterFile.absolutePath, decodeOpts)
            ?: throw IOException("Could not downsample original photo container.")

        val rotated = if (rotationDegrees != 0) {
            val matrix = Matrix().apply { postRotate(rotationDegrees.toFloat()) }
            Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true).also {
                if (it !== decoded) decoded.recycle()
            }
        } else {
            decoded
        }

        val curMax = maxOf(rotated.width, rotated.height)
        val scaled = if (curMax > maxPixelSize) {
            val scale = maxPixelSize.toFloat() / curMax.toFloat()
            val w = (rotated.width * scale).toInt().coerceAtLeast(1)
            val h = (rotated.height * scale).toInt().coerceAtLeast(1)
            Bitmap.createScaledBitmap(rotated, w, h, true).also {
                if (it !== rotated) rotated.recycle()
            }
        } else {
            rotated
        }

        val outFile = makeTaggedProxyTempFile(context, masterHash, "jpg", "proxy")
        try {
            outFile.outputStream().use { out ->
                if (!scaled.compress(Bitmap.CompressFormat.JPEG, qualityPercent, out)) {
                    throw IOException("Could not write compressed JPEG proxy.")
                }
            }
        } finally {
            scaled.recycle()
        }

        embedMasterHashExifMarker(outFile, masterHash)

        val sizeBytes = outFile.length()
        val sha = computeFileSha256(outFile)
        return GeneratedProxy(file = outFile, sha256 = sha, sizeBytes = sizeBytes)
    }

    @androidx.annotation.OptIn(UnstableApi::class)
    suspend fun createVideoProxy(
        context: Context,
        masterFile: File,
        masterHash: String? = null,
        maxPixelSize: Int = 0,
        quality: Float = 0.72f
    ): GeneratedProxy {
        val masterSize = masterFile.length().takeIf { it > 0L } ?: Long.MAX_VALUE
        val targetShortSide = when {
            maxPixelSize in 1..960 -> 480
            maxPixelSize <= 0 -> if (quality < 0.59f) 540 else 720
            maxPixelSize <= 1440 -> 720
            maxPixelSize <= 2100 -> 1080
            else -> 1440
        }

        // Compute display height corresponding to target short side so portrait videos stay sharp at chosen tier (720x1280 vs 405x720) and never upscale
        val targetDisplayHeight = withContext(Dispatchers.IO) {
            resolveTargetVideoHeight(masterFile, targetShortSide)
        }

        suspend fun runTransform(heightPx: Int): File {
            val outFile = makeTaggedProxyTempFile(context, masterHash, "mp4", "video_proxy")
            if (outFile.exists()) outFile.delete()
            val mainHandler = Handler(Looper.getMainLooper())
            try {
                suspendCancellableCoroutine<Unit> { cont ->
                    mainHandler.post {
                        if (!cont.isActive) return@post
                        val mediaItem = MediaItem.fromUri(Uri.fromFile(masterFile))
                        val effects = Effects(
                            emptyList(),
                            listOf(Presentation.createForHeight(heightPx))
                        )
                        val editedMediaItem = EditedMediaItem.Builder(mediaItem)
                            .setEffects(effects)
                            .build()

                        val transformer = Transformer.Builder(context)
                            .addListener(object : Transformer.Listener {
                                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                                    if (cont.isActive) cont.resume(Unit)
                                }

                                override fun onError(
                                    composition: Composition,
                                    exportResult: ExportResult,
                                    exportException: ExportException
                                ) {
                                    if (cont.isActive) cont.resumeWithException(exportException)
                                }
                            })
                            .build()

                        transformer.start(editedMediaItem, outFile.absolutePath)
                        cont.invokeOnCancellation {
                            mainHandler.post { runCatching { transformer.cancel() } }
                        }
                    }
                }
            } catch (err: Exception) {
                cleanupTempFile(outFile)
                throw err
            }
            if (!outFile.exists() || outFile.length() == 0L) {
                cleanupTempFile(outFile)
                throw IOException("Video proxy export produced an empty file.")
            }
            return outFile
        }

        var proxyFile = runTransform(targetDisplayHeight)
        if (proxyFile.length() >= masterSize && targetShortSide > 480) {
            val smallerHeight = withContext(Dispatchers.IO) { resolveTargetVideoHeight(masterFile, 480) }
            if (smallerHeight < targetDisplayHeight) {
                val smallerFile = runCatching { runTransform(smallerHeight) }.getOrNull()
                if (smallerFile != null && smallerFile.length() < proxyFile.length()) {
                    cleanupTempFile(proxyFile)
                    proxyFile = smallerFile
                } else {
                    cleanupTempFile(smallerFile)
                }
            }
        }

        var posterFile: File? = null
        withContext(Dispatchers.IO) {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(masterFile.absolutePath)
                val frame = retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                if (frame != null) {
                    val curMax = maxOf(frame.width, frame.height).coerceAtLeast(1)
                    val targetBmp = if (curMax > 800) {
                        val scale = 800f / curMax.toFloat()
                        Bitmap.createScaledBitmap(
                            frame,
                            (frame.width * scale).toInt().coerceAtLeast(1),
                            (frame.height * scale).toInt().coerceAtLeast(1),
                            true
                        ).also { if (it !== frame) frame.recycle() }
                    } else {
                        frame
                    }
                    val pFile = File(context.cacheDir, "video_poster_${UUID.randomUUID()}.jpg")
                    pFile.outputStream().use { out ->
                        if (targetBmp.compress(Bitmap.CompressFormat.JPEG, 65, out)) {
                            posterFile = pFile
                        } else {
                            pFile.delete()
                        }
                    }
                    targetBmp.recycle()
                }
            } catch (_: Exception) {
                posterFile = null
            } finally {
                runCatching { retriever.release() }
            }
        }

        val sha = withContext(Dispatchers.IO) { computeFileSha256(proxyFile) }
        return GeneratedProxy(
            file = proxyFile,
            sha256 = sha,
            sizeBytes = proxyFile.length(),
            posterFile = posterFile
        )
    }

    private fun resolveTargetVideoHeight(masterFile: File, desiredShortSide: Int): Int {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(masterFile.absolutePath)
            val rawW = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            val rawH = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val rot = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            if (rawW <= 0 || rawH <= 0) return desiredShortSide

            val dispW = if (rot == 90 || rot == 270) rawH else rawW
            val dispH = if (rot == 90 || rot == 270) rawW else rawH
            val shortSide = minOf(dispW, dispH).coerceAtLeast(1)
            val scale = minOf(1.0f, desiredShortSide.toFloat() / shortSide.toFloat())
            val evenHeight = (((dispH * scale).toInt() + 1) / 2) * 2
            evenHeight.coerceAtLeast(240)
        } catch (_: Exception) {
            desiredShortSide
        } finally {
            runCatching { retriever.release() }
        }
    }

    fun computeFileSha256(file: File): String =
        FileInputStream(file).use { input -> computeStreamSha256(input) }

    private fun cleanMasterHashString(raw: String?): String? {
        raw ?: return null
        val hex = extractLowercaseHexPrefix(raw, maxLength = 64)
        return hex.takeIf { it.length >= 8 }
    }

    private fun parseMarkerHash(raw: String?): String? {
        raw ?: return null
        val idx = raw.indexOf(PROXY_MARKER_PREFIX, ignoreCase = true)
        if (idx < 0) return null
        val remainder = raw.substring(idx + PROXY_MARKER_PREFIX.length)
        val hex = extractLowercaseHexPrefix(remainder, maxLength = 64)
        return hex.takeIf { it.length >= 8 }
    }

    private fun extractLowercaseHexPrefix(raw: String, maxLength: Int): String {
        val sb = StringBuilder(minOf(raw.length, maxLength))
        for (ch in raw.trim().lowercase(Locale.ROOT)) {
            val isHex = (ch in '0'..'9') || (ch in 'a'..'f')
            if (!isHex) {
                if (sb.isNotEmpty()) break else continue
            }
            sb.append(ch)
            if (sb.length >= maxLength) break
        }
        return sb.toString()
    }
}
