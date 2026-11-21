package com.photohub.compressor.network

import android.content.Context
import android.util.Base64
import com.photohub.compressor.data.*
import com.photohub.compressor.media.ProxyGenerator
import com.photohub.compressor.sync.LocalProxyStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.CertificatePinner
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink
import okio.source
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID
import java.util.concurrent.TimeUnit

class ApiHttpException(val statusCode: Int, override val message: String) : Exception(message)

private class StreamingFileRequestBody(
    private val file: File,
    private val mediaType: okhttp3.MediaType?,
    private val onProgress: ((Double) -> Unit)?
) : RequestBody() {
    override fun contentType(): okhttp3.MediaType? = mediaType
    override fun contentLength(): Long = file.length()

    override fun writeTo(sink: BufferedSink) {
        val total = contentLength().coerceAtLeast(1L)
        var uploaded = 0L
        var lastReportedPercent = -1
        file.source().use { source ->
            val buffer = okio.Buffer()
            while (true) {
                val read = source.read(buffer, 64 * 1024L)
                if (read == -1L) break
                sink.write(buffer, read)
                uploaded += read
                val pct = ((uploaded.toDouble() / total.toDouble()) * 100.0).toInt()
                if (pct != lastReportedPercent) {
                    lastReportedPercent = pct
                    onProgress?.invoke((uploaded.toDouble() / total.toDouble()).coerceIn(0.0, 1.0))
                }
            }
        }
    }
}

class PhotoHubApiClient(
    private val context: Context,
    private val settings: AppSettings
) {
    private val client: OkHttpClient by lazy {
        val builder = OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(180, TimeUnit.SECONDS)
            .writeTimeout(600, TimeUnit.SECONDS)

        val pins = settings.pinnedCertHashes
        val baseHost = settings.current.normalizedBaseUrl?.let { safeHost(it) }
        val gatewayHost = settings.current.gatewayUrl?.let { safeHost(it) }
        val hosts = listOfNotNull(baseHost, gatewayHost).distinct()
        if (pins.isNotEmpty() && hosts.isNotEmpty()) {
            val pinner = CertificatePinner.Builder()
            for (h in hosts) {
                for (pin in pins) {
                    val formatted = if (pin.startsWith("sha256/")) pin else "sha256/$pin"
                    pinner.add(h, formatted)
                }
            }
            builder.certificatePinner(pinner.build())
        }
        builder.build()
    }

    private fun safeHost(url: String): String? = try {
        URI(url).host
    } catch (_: Exception) {
        null
    }

    private fun makeUrl(path: String): String {
        val base = settings.current.normalizedBaseUrl
            ?: throw IOException("Server gateway URL is not configured.")
        val cleanPath = path.trimStart('/')
        return "${base.trimEnd('/')}/$cleanPath"
    }

    private fun Request.Builder.applyAuth(): Request.Builder {
        val token = settings.current.authToken.trim()
        if (token.isNotEmpty()) {
            header("Authorization", "Bearer $token")
        }
        return this
    }

    private fun parseErrorMessage(code: Int, rawBody: String): String {
        return try {
            val obj = JSONObject(rawBody)
            obj.optString("error").takeIf { it.isNotBlank() }
                ?: obj.optString("message").takeIf { it.isNotBlank() }
                ?: "HTTP $code"
        } catch (_: Exception) {
            rawBody.ifBlank { "HTTP $code" }
        }
    }

    suspend fun exchangeGoogleAuthCode(
        code: String,
        codeVerifier: String,
        gatewayUrl: String
    ): GoogleExchangeResponse = withContext(Dispatchers.IO) {
        val payload = JSONObject().apply {
            put("code", code)
            put("codeVerifier", codeVerifier)
        }.toString()
        val req = Request.Builder()
            .url("${gatewayUrl.trimEnd('/')}/api/auth/exchange")
            .post(payload.toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
            .build()

        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
            val json = JSONObject(text)
            val userObj = json.getJSONObject("user")
            GoogleExchangeResponse(
                success = json.optBoolean("success", false),
                token = json.getString("token"),
                serverUrl = json.getString("serverUrl"),
                nodeId = json.optString("nodeId", "primary"),
                user = GoogleUserProfile(
                    email = userObj.optString("email", ""),
                    name = userObj.optString("name", ""),
                    folderName = userObj.optString("folderName", "")
                )
            )
        }
    }

    suspend fun resolveAssignedNode(gatewayUrl: String): AuthResolveResponse = withContext(Dispatchers.IO) {
        val req = Request.Builder()
            .url("${gatewayUrl.trimEnd('/')}/api/auth/resolve")
            .post("{}".toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
            .applyAuth()
            .build()

        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
            val json = JSONObject(text)
            val userObj = json.optJSONObject("user")
            AuthResolveResponse(
                success = json.optBoolean("success", false),
                serverUrl = json.getString("serverUrl"),
                nodeId = json.optString("nodeId", "").takeIf { it.isNotBlank() },
                user = userObj?.let {
                    GoogleUserProfile(
                        email = it.optString("email", ""),
                        name = it.optString("name", ""),
                        folderName = it.optString("folderName", "")
                    )
                }
            )
        }
    }

    suspend fun whoami(): WhoAmIResponse = withContext(Dispatchers.IO) {
        val req = Request.Builder()
            .url(makeUrl("/api/whoami"))
            .get()
            .applyAuth()
            .build()
        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
            val json = JSONObject(text)
            WhoAmIResponse(
                success = json.optBoolean("success", true),
                authMode = json.optString("authMode").takeIf { it.isNotBlank() },
                userFolder = if (json.isNull("userFolder")) null else json.optString("userFolder").takeIf { it.isNotBlank() },
                email = json.optString("email").takeIf { it.isNotBlank() },
                name = json.optString("name").takeIf { it.isNotBlank() },
                nodeId = json.optString("nodeId").takeIf { it.isNotBlank() },
                indexedPhotos = json.optInt("indexedPhotos", 0),
                s3Enabled = if (json.has("s3Enabled") && !json.isNull("s3Enabled")) json.optBoolean("s3Enabled") else null,
                storage = ServerStorageInfo.fromJson(json.optJSONObject("storage"))
            )
        }
    }

    suspend fun fetchAllServerPhotos(sync: Boolean = true): List<ServerPhoto> = withContext(Dispatchers.IO) {
        val collected = mutableListOf<ServerPhoto>()
        val seenHashes = hashSetOf<String>()
        var offset = 0
        val pageSize = 500

        while (true) {
            val syncParam = if (sync && offset == 0) "&sync=1" else ""
            val url = makeUrl("/api/photos?limit=$pageSize&offset=$offset$syncParam")
            val req = Request.Builder().url(url).get().applyAuth().build()
            var pageCount = 0
            var total = 0
            var serverHasMore: Boolean? = null

            client.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
                val json = JSONObject(text)
                total = json.optInt("total", 0)
                serverHasMore = if (json.has("hasMore") && !json.isNull("hasMore")) json.optBoolean("hasMore") else null
                val pagePhotos = ServerPhoto.listFromJsonArray(json.optJSONArray("photos"))
                pageCount = pagePhotos.size
                for (item in pagePhotos) {
                    if (seenHashes.add(item.hash.lowercase())) {
                        collected.add(item)
                    }
                }
            }

            if (pageCount == 0) break
            offset += pageCount
            val hasMore = serverHasMore ?: (offset < total)
            if (!hasMore || offset >= total) break
        }
        collected
    }

    suspend fun checkHash(sha256: String): CheckResponse = withContext(Dispatchers.IO) {
        val req = Request.Builder()
            .url(makeUrl("/api/check/$sha256"))
            .get()
            .applyAuth()
            .build()
        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
            val json = JSONObject(text)
            CheckResponse(
                success = json.optBoolean("success", false),
                exists = json.optBoolean("exists", false),
                isMaster = json.optBoolean("isMaster", false),
                isProxy = json.optBoolean("isProxy", false),
                hasProxy = json.optBoolean("hasProxy", false),
                proxySize = if (json.has("proxySize") && !json.isNull("proxySize")) json.optLong("proxySize") else null,
                isProtectedOriginal = json.optBoolean("isProtectedOriginal", false),
                keepOriginalOnDevice = json.optBoolean("keepOriginalOnDevice", false),
                canReplaceWithProxy = json.optBoolean("canReplaceWithProxy", false),
                masterHash = json.optString("masterHash").takeIf { it.isNotBlank() },
                savedPath = json.optString("savedPath").takeIf { it.isNotBlank() }
            )
        }
    }

    suspend fun uploadMasterDirect(
        file: File,
        filename: String,
        mimeType: String,
        createdAtMs: Long?,
        expectedSha256: String,
        onProgress: ((Double) -> Unit)? = null
    ): UploadConfirmResponse = withContext(Dispatchers.IO) {
        val encodedName = URLEncoder.encode(filename, "UTF-8").replace("+", "%20")
        val builder = Request.Builder()
            .url(makeUrl("/api/upload"))
            .applyAuth()
            .header("Content-Type", mimeType)
            .header("X-File-Name", encodedName)
            .header("X-File-Sha256", expectedSha256)
            .header("X-Verify-Checksum", "strict")

        if (createdAtMs != null && createdAtMs > 0L) {
            val iso = DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(createdAtMs))
            builder.header("X-Photo-Date", iso)
        }

        val body = StreamingFileRequestBody(file, mimeType.toMediaTypeOrNull(), onProgress)
        builder.post(body)

        client.newCall(builder.build()).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
            val parsed = parseUploadConfirm(JSONObject(text))
            ensureChecksumConfirmed(parsed, expectedSha256)
            parsed
        }
    }

    suspend fun uploadMasterPresigned(
        file: File,
        filename: String,
        mimeType: String,
        createdAtMs: Long?,
        expectedSha256: String,
        onProgress: ((Double) -> Unit)? = null
    ): UploadConfirmResponse = withContext(Dispatchers.IO) {
        val dateStr = if (createdAtMs != null && createdAtMs > 0L) {
            DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(createdAtMs))
        } else {
            ""
        }
        val presignPayload = JSONObject().apply {
            put("fileName", filename)
            put("mimeType", mimeType)
            put("createdAt", dateStr)
            put("expectedHash", expectedSha256)
            put("fileSize", file.length())
        }.toString()

        val presignReq = Request.Builder()
            .url(makeUrl("/api/upload/presign"))
            .applyAuth()
            .post(presignPayload.toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
            .build()

        val presignJson: JSONObject = client.newCall(presignReq).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
            JSONObject(text)
        }

        if (presignJson.optBoolean("alreadyExists", false)) {
            val existing = UploadConfirmResponse(
                success = true,
                canDelete = true,
                checksumVerified = presignJson.optBoolean("checksumVerified", true),
                canReplaceWithProxy = presignJson.optBoolean("canReplaceWithProxy", true),
                serverSha256 = presignJson.optString("serverSha256").takeIf { it.isNotBlank() },
                hash = presignJson.optString("serverSha256").takeIf { it.isNotBlank() },
                savedPath = null,
                error = null
            )
            ensureChecksumConfirmed(existing, expectedSha256)
            return@withContext existing
        }

        val uploadUrl = presignJson.optString("uploadUrl").takeIf { it.isNotBlank() }
            ?: throw IOException("Missing S3 presign uploadUrl")
        val objectKey = presignJson.optString("objectKey").takeIf { it.isNotBlank() }
            ?: throw IOException("Missing S3 presign objectKey")

        val putReq = Request.Builder()
            .url(uploadUrl)
            .put(StreamingFileRequestBody(file, mimeType.toMediaTypeOrNull(), onProgress))
            .build()
        client.newCall(putReq).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
        }

        val confirmPayload = JSONObject().apply {
            put("objectKey", objectKey)
            put("expectedHash", expectedSha256)
            put("fileName", filename)
            put("createdAt", dateStr)
        }.toString()

        val confirmReq = Request.Builder()
            .url(makeUrl("/api/upload/confirm"))
            .applyAuth()
            .post(confirmPayload.toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
            .build()

        client.newCall(confirmReq).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
            val parsed = parseUploadConfirm(JSONObject(text))
            ensureChecksumConfirmed(parsed, expectedSha256)
            parsed
        }
    }

    suspend fun registerProxy(
        masterHash: String,
        proxyHash: String,
        assetId: String,
        proxyFile: File? = null,
        proxyFormat: String = "jpeg",
        videoProxyFile: File? = null
    ) = withContext(Dispatchers.IO) {
        val payload = JSONObject().apply {
            put("masterHash", masterHash)
            put("proxyHash", proxyHash)
            put("assetId", assetId)
            put("proxyFormat", proxyFormat)
            if (proxyFile != null && proxyFile.exists()) {
                put("proxyBase64", Base64.encodeToString(proxyFile.readBytes(), Base64.NO_WRAP))
            }
        }

        val req = Request.Builder()
            .url(makeUrl("/api/proxy/register"))
            .applyAuth()
            .post(payload.toString().toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
            .build()

        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
        }

        if (videoProxyFile != null && videoProxyFile.exists()) {
            try {
                uploadVideoProxyBinary(masterHash, proxyHash, assetId, videoProxyFile)
            } catch (err: ApiHttpException) {
                if (err.statusCode == 404 && videoProxyFile.length() in 1L..(25L * 1024L * 1024L)) {
                    payload.put(
                        "videoProxyBase64",
                        Base64.encodeToString(videoProxyFile.readBytes(), Base64.NO_WRAP)
                    )
                    val fallbackReq = Request.Builder()
                        .url(makeUrl("/api/proxy/register"))
                        .applyAuth()
                        .post(payload.toString().toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
                        .build()
                    client.newCall(fallbackReq).execute().use { resp ->
                        val text = resp.body?.string().orEmpty()
                        if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
                    }
                } else {
                    throw err
                }
            }
        }
    }

    private fun uploadVideoProxyBinary(
        masterHash: String,
        proxyHash: String,
        assetId: String,
        videoProxyFile: File
    ) {
        val builder = Request.Builder()
            .url(makeUrl("/api/proxy/$masterHash/video"))
            .applyAuth()
            .header("Content-Type", "video/mp4")
            .header("X-Proxy-Hash", proxyHash)
        if (assetId.isNotBlank()) {
            builder.header("X-Asset-Id", assetId)
        }
        builder.post(StreamingFileRequestBody(videoProxyFile, "video/mp4".toMediaTypeOrNull(), null))
        client.newCall(builder.build()).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
        }
    }

    suspend fun createAndRegisterProxy(photo: ServerPhoto): ServerPhoto {
        val current = settings.current
        val serverUpdated = runCatching { generateProxyOnServer(photo) }.getOrNull()
        if (serverUpdated != null) {
            runCatching {
                val previewBytes = downloadPhotoPreviewData(serverUpdated.hash)
                if (previewBytes.isNotEmpty()) {
                    LocalProxyStore.getInstance(context).cacheDownloadedPreviewData(previewBytes, serverUpdated.hash)
                }
            }
            if (current.autoDownloadLocalVideos &&
                serverUpdated.isVideo &&
                serverUpdated.hasVideoProxy == true &&
                LocalProxyStore.getInstance(context).videoProxyFileIfExists(serverUpdated.hash) == null
            ) {
                runCatching {
                    val tempVideo = downloadVideoProxyToTempFile(serverUpdated.hash)
                    try {
                        LocalProxyStore.getInstance(context).copyVideoProxy(tempVideo, serverUpdated.hash)
                    } finally {
                        tempVideo.delete()
                    }
                }
            }
            LocalProxyStore.getInstance(context).updatePhoto(
                serverUpdated,
                current.normalizedBaseUrl,
                current.apiKeyCacheScope,
                notify = false
            )
            return serverUpdated
        }

        val masterFile = downloadMasterToTempFile(photo.hash, photo.originalName)
        var proxyFile: File? = null
        var posterFile: File? = null
        try {
            val generated = if (photo.isVideo) {
                ProxyGenerator.createVideoProxy(context, masterFile, photo.hash)
            } else {
                ProxyGenerator.createImageProxy(
                    context = context,
                    masterFile = masterFile,
                    format = current.proxyFormat,
                    maxPixelSize = current.proxyMaxPixelSize,
                    quality = current.proxyQuality,
                    masterHash = photo.hash
                )
            }
            proxyFile = generated.file
            posterFile = generated.posterFile

            val previewFile = if (photo.isVideo) generated.posterFile else generated.file
            val previewFmt = if (photo.isVideo) "jpeg" else "jpeg"
            val videoProxy = if (photo.isVideo) generated.file else null

            registerProxy(
                masterHash = photo.hash,
                proxyHash = generated.sha256,
                assetId = "",
                proxyFile = previewFile,
                proxyFormat = previewFmt,
                videoProxyFile = videoProxy
            )

            val store = LocalProxyStore.getInstance(context)
            if (previewFile != null) store.copyPreviewFile(previewFile, photo.hash)
            if (photo.isVideo) store.copyVideoProxy(generated.file, photo.hash)

            val posterBytes = previewFile?.takeIf { it.exists() }?.length()
            val updated = photo.copy(
                hasProxy = true,
                hasPreview = previewFile != null,
                proxyHash = generated.sha256,
                proxySize = if (photo.isVideo) posterBytes else generated.sizeBytes,
                hasVideoProxy = if (photo.isVideo) true else photo.hasVideoProxy,
                videoProxySize = if (photo.isVideo) generated.sizeBytes else photo.videoProxySize
            )
            store.updatePhoto(updated, current.normalizedBaseUrl, current.apiKeyCacheScope, notify = false)
            return updated
        } finally {
            masterFile.delete()
            ProxyGenerator.cleanupTempFile(proxyFile)
            ProxyGenerator.cleanupTempFile(posterFile)
        }
    }

    private suspend fun generateProxyOnServer(photo: ServerPhoto): ServerPhoto = withContext(Dispatchers.IO) {
        val current = settings.current
        val body = JSONObject().apply {
            put("masterHash", photo.hash)
            put("maxPixelSize", current.proxyMaxPixelSize)
            put("quality", current.proxyQuality.toDouble())
        }.toString()

        val req = Request.Builder()
            .url(makeUrl("/api/proxy/generate"))
            .applyAuth()
            .post(body.toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
            .build()

        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
            val json = JSONObject(text)
            val photoJson = json.optJSONObject("photo")
            if (!json.optBoolean("success", false) || photoJson == null) {
                throw IOException("Invalid proxy generate response")
            }
            ServerPhoto.fromJson(photoJson)
        }
    }

    suspend fun downloadPhotoPreviewData(hash: String): ByteArray = withContext(Dispatchers.IO) {
        val req = Request.Builder()
            .url(makeUrl("/api/photo/$hash/preview"))
            .get()
            .applyAuth()
            .build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                val errText = resp.body?.string().orEmpty()
                throw ApiHttpException(resp.code, parseErrorMessage(resp.code, errText))
            }
            resp.body?.bytes() ?: ByteArray(0)
        }
    }

    data class DownloadedFileResult(
        val file: File,
        val suggestedFilename: String,
        val bytesWritten: Long
    )

    suspend fun lookupPhotoByHashPrefix(rawPrefix: String): ServerPhoto? = withContext(Dispatchers.IO) {
        val cleanPrefix = rawPrefix.trim().lowercase().filter { it in '0'..'9' || it in 'a'..'f' }
        if (cleanPrefix.length < 8) return@withContext null

        val url = makeUrl("/api/photos?prefix=$cleanPrefix&limit=50&offset=0")
        val req = Request.Builder().url(url).get().applyAuth().build()
        var pagePhotos: List<ServerPhoto> = emptyList()
        var hasMore = false

        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
            val json = JSONObject(text)
            pagePhotos = ServerPhoto.listFromJsonArray(json.optJSONArray("photos"))
            val total = json.optInt("total", pagePhotos.size)
            hasMore = if (json.has("hasMore") && !json.isNull("hasMore")) {
                json.optBoolean("hasMore")
            } else {
                pagePhotos.size < total
            }
        }

        val directMatch = pagePhotos.firstOrNull { it.hash.startsWith(cleanPrefix, ignoreCase = true) }
        if (directMatch != null || !hasMore) {
            return@withContext directMatch
        }

        // Fallback for older server instances that ignore ?prefix=.
        fetchAllServerPhotos(sync = true).firstOrNull { it.hash.startsWith(cleanPrefix, ignoreCase = true) }
    }

    suspend fun downloadMasterToTempFile(
        hash: String,
        preferredFilename: String? = null,
        onProgress: ((downloadedBytes: Long, totalBytes: Long?) -> Unit)? = null
    ): File {
        val shareDir = File(context.cacheDir, "photohub_share_${UUID.randomUUID().toString().take(8)}")
        return downloadMasterToDirectory(hash, shareDir, preferredFilename, onProgress).file
    }

    suspend fun downloadMasterToDirectory(
        hash: String,
        destDir: File,
        preferredFilename: String? = null,
        onProgress: ((downloadedBytes: Long, totalBytes: Long?) -> Unit)? = null
    ): DownloadedFileResult = streamDownloadToDirectory(
        path = "/api/photo/$hash",
        destDir = destDir,
        preferredFilename = preferredFilename,
        fallbackFilename = "photo_${hash.take(8)}.jpg",
        onProgress = onProgress
    )

    suspend fun downloadVideoProxyToTempFile(hash: String): File {
        val shareDir = File(context.cacheDir, "photohub_share_${UUID.randomUUID().toString().take(8)}")
        return streamDownloadToDirectory(
            path = "/api/photo/$hash/video-proxy",
            destDir = shareDir,
            preferredFilename = "${hash.take(16)}.mp4",
            fallbackFilename = "${hash.take(16)}.mp4",
            onProgress = null
        ).file
    }

    private suspend fun streamDownloadToDirectory(
        path: String,
        destDir: File,
        preferredFilename: String?,
        fallbackFilename: String,
        onProgress: ((downloadedBytes: Long, totalBytes: Long?) -> Unit)?
    ): DownloadedFileResult = withContext(Dispatchers.IO) {
        val req = Request.Builder()
            .url(makeUrl(path))
            .get()
            .applyAuth()
            .build()

        destDir.mkdirs()
        val partFile = File(destDir, ".part_${UUID.randomUUID().toString().take(8)}")

        try {
            var suggestedName = fallbackFilename
            var downloaded = 0L

            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) {
                    val errText = resp.body?.string().orEmpty()
                    throw ApiHttpException(resp.code, parseErrorMessage(resp.code, errText))
                }
                val dispositionName = extractDispositionFilename(resp.header("Content-Disposition"))
                val rawName = preferredFilename?.trim()?.takeIf { it.isNotEmpty() }
                    ?: dispositionName
                    ?: fallbackFilename
                suggestedName = File(rawName).name.ifBlank { fallbackFilename }

                val body = resp.body ?: throw IOException("Empty download response")
                val totalLen = body.contentLength().takeIf { it > 0L }
                onProgress?.invoke(0L, totalLen)

                val coroutineCtx = currentCoroutineContext()
                body.byteStream().use { input ->
                    partFile.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var lastNotifyBytes = 0L
                        while (true) {
                            coroutineCtx.ensureActive()
                            val read = input.read(buffer)
                            if (read <= 0) break
                            output.write(buffer, 0, read)
                            downloaded += read
                            if (onProgress != null && (downloaded - lastNotifyBytes >= 64 * 1024L || (totalLen != null && downloaded >= totalLen))) {
                                lastNotifyBytes = downloaded
                                onProgress.invoke(downloaded, totalLen)
                            }
                        }
                    }
                }
                onProgress?.invoke(downloaded, totalLen)
            }

            if (!partFile.exists() || partFile.length() <= 0L) {
                throw IOException("Downloaded file was empty.")
            }

            val finalFile = File(destDir, suggestedName)
            if (finalFile.exists()) finalFile.delete()
            if (!partFile.renameTo(finalFile)) {
                partFile.copyTo(finalFile, overwrite = true)
                partFile.delete()
            }
            DownloadedFileResult(file = finalFile, suggestedFilename = suggestedName, bytesWritten = downloaded)
        } catch (err: Exception) {
            partFile.delete()
            throw err
        }
    }

    suspend fun setOriginalProtected(masterHash: String, protected: Boolean): ServerPhoto = withContext(Dispatchers.IO) {
        val body = JSONObject().apply { put("keepOriginalOnDevice", protected) }.toString()
        val req = Request.Builder()
            .url(makeUrl("/api/photo/$masterHash/protect-original"))
            .applyAuth()
            .post(body.toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
            .build()

        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
            val json = JSONObject(text)
            val photoObj = json.optJSONObject("photo")
            if (!json.optBoolean("success", false) || photoObj == null) {
                throw IOException("Invalid protect-original response")
            }
            val updated = ServerPhoto.fromJson(photoObj)
            val cur = settings.current
            LocalProxyStore.getInstance(context).updatePhoto(
                updated,
                cur.normalizedBaseUrl,
                cur.apiKeyCacheScope,
                notify = true
            )
            updated
        }
    }

    private fun extractDispositionFilename(header: String?): String? {
        header ?: return null
        val idx = header.indexOf("filename=")
        if (idx < 0) return null
        var value = header.substring(idx + 9)
        val semi = value.indexOf(';')
        if (semi >= 0) value = value.substring(0, semi)
        value = value.trim().trim('"', '\'')
        return try {
            URLDecoder.decode(value, StandardCharsets.UTF_8.name())
        } catch (_: Exception) {
            value
        }
    }

    private fun parseUploadConfirm(json: JSONObject): UploadConfirmResponse = UploadConfirmResponse(
        success = json.optBoolean("success", false),
        canDelete = if (json.has("canDelete") && !json.isNull("canDelete")) json.optBoolean("canDelete") else false,
        checksumVerified = if (json.has("checksumVerified") && !json.isNull("checksumVerified")) json.optBoolean("checksumVerified") else false,
        canReplaceWithProxy = if (json.has("canReplaceWithProxy") && !json.isNull("canReplaceWithProxy")) json.optBoolean("canReplaceWithProxy") else false,
        serverSha256 = json.optString("serverSha256").takeIf { it.isNotBlank() },
        hash = json.optString("hash").takeIf { it.isNotBlank() },
        savedPath = json.optString("savedPath").takeIf { it.isNotBlank() },
        error = json.optString("error").takeIf { it.isNotBlank() }
    )

    private fun ensureChecksumConfirmed(result: UploadConfirmResponse, expectedSha256: String) {
        val serverHash = (result.serverSha256 ?: result.hash)?.lowercase()
        val verified = result.checksumVerified || result.canDelete
        if (!result.success || !verified || serverHash != expectedSha256.lowercase()) {
            val detail = result.error
                ?: "Server hash (${serverHash ?: "null"}) did not match local master (${expectedSha256.take(12)}…)"
            throw IOException(detail)
        }
    }
}
