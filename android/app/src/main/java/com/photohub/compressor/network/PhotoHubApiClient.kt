package com.photohub.compressor.network

import android.content.Context
import android.util.Base64
import com.photohub.compressor.data.*
import com.photohub.compressor.media.OriginalDownloadCache
import com.photohub.compressor.media.ProxyGenerator
import com.photohub.compressor.sync.LocalProxyStore
import com.photohub.compressor.sync.LocalProxyTracker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.CertificatePinner
import okhttp3.ConnectionPool
import okhttp3.Dispatcher
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.ResponseBody
import okio.BufferedSink
import okio.source
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

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

/**
 * Process-wide OkHttp connection & HTTP/2 socket pool shared across all PhotoHub API clients,
 * matching iOS URLSession pooling so TLS handshakes and connections stay warm.
 */
private object SharedHttpClientPool {
    private val sharedConnectionPool = ConnectionPool(12, 5, TimeUnit.MINUTES)
    private val sharedDispatcher = Dispatcher().apply {
        maxRequests = 40
        maxRequestsPerHost = 12
    }

    private val baseClient: OkHttpClient = OkHttpClient.Builder()
        .connectionPool(sharedConnectionPool)
        .dispatcher(sharedDispatcher)
        .protocols(listOf(Protocol.HTTP_2, Protocol.HTTP_1_1))
        .retryOnConnectionFailure(true)
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(600, TimeUnit.SECONDS)
        .writeTimeout(1800, TimeUnit.SECONDS)
        .build()

    private val pinnedClients = ConcurrentHashMap<String, OkHttpClient>()
    private val lastWarmAtMs = ConcurrentHashMap<String, Long>()

    fun clientFor(hosts: List<String>, pins: List<String>): OkHttpClient {
        if (pins.isEmpty() || hosts.isEmpty()) return baseClient
        val key = "${hosts.sorted().joinToString(",")}|${pins.sorted().joinToString(",")}"
        return pinnedClients.getOrPut(key) {
            val pinner = CertificatePinner.Builder()
            for (h in hosts) {
                for (pin in pins) {
                    val formatted = if (pin.startsWith("sha256/")) pin else "sha256/$pin"
                    pinner.add(h, formatted)
                }
            }
            baseClient.newBuilder()
                .certificatePinner(pinner.build())
                .build()
        }
    }

    fun shouldWarm(baseUrl: String, nowMs: Long = System.currentTimeMillis()): Boolean {
        val prev = lastWarmAtMs[baseUrl] ?: 0L
        if (nowMs - prev < 30_000L) return false
        lastWarmAtMs[baseUrl] = nowMs
        return true
    }
}

data class ContentRangeInfo(
    val start: Long,
    val end: Long,
    val total: Long
)

object DownloadRangePlanner {
    private val CONTENT_RANGE_REGEX = Regex("""bytes\s+(\d+)-(\d+)/(\d+)""", RegexOption.IGNORE_CASE)
    private const val MIN_SEGMENT_BYTES = 1024L * 1024L

    fun parseContentRangeInfo(header: String?): ContentRangeInfo? {
        header ?: return null
        val match = CONTENT_RANGE_REGEX.find(header.trim()) ?: return null
        val start = match.groupValues[1].toLongOrNull() ?: return null
        val end = match.groupValues[2].toLongOrNull() ?: return null
        val total = match.groupValues[3].toLongOrNull() ?: return null
        if (start < 0L || end < start || total <= end) return null
        return ContentRangeInfo(start, end, total)
    }

    fun buildRemainingByteRanges(
        startOffset: Long,
        totalSize: Long,
        maxSegments: Int = 3
    ): List<LongRange> {
        val remaining = totalSize - startOffset
        if (remaining <= 0L || maxSegments <= 0) return emptyList()
        val count = minOf(
            maxSegments,
            maxOf(1, (remaining / MIN_SEGMENT_BYTES).toInt())
        )
        if (count <= 1) {
            return listOf(startOffset until totalSize)
        }
        val step = (remaining + count - 1L) / count
        val ranges = ArrayList<LongRange>(count)
        var cursor = startOffset
        while (cursor < totalSize) {
            val end = minOf(totalSize - 1L, cursor + step - 1L)
            ranges.add(cursor..end)
            cursor = end + 1L
        }
        return ranges
    }
}

data class DeletePhotosResult(
    val success: Boolean,
    val deleted: List<String>,
    val missing: List<String>,
    val freedBytes: Long
)

class PhotoHubApiClient(
    private val context: Context,
    private val settings: AppSettings
) {
    private val client: OkHttpClient
        get() {
            val pins = settings.pinnedCertHashes
            val baseHost = settings.current.normalizedBaseUrl?.let { safeHost(it) }
            val gatewayHost = settings.current.gatewayUrl?.let { safeHost(it) }
            val hosts = listOfNotNull(baseHost, gatewayHost).distinct()
            return SharedHttpClientPool.clientFor(hosts, pins)
        }

    /** Pre-establishes TLS / HTTP/2 socket cleanly before the user triggers an original download. */
    suspend fun warmConnectionIfNeeded() = withContext(Dispatchers.IO) {
        val base = settings.current.normalizedBaseUrl ?: return@withContext
        if (!SharedHttpClientPool.shouldWarm(base)) return@withContext
        runCatching {
            val req = Request.Builder()
                .url("${base.trimEnd('/')}/api/health")
                .get()
                .build()
            client.newCall(req).execute().use { it.body?.close() }
        }
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

    private fun parseCheckResponse(json: JSONObject): CheckResponse = CheckResponse(
        success = json.optBoolean("success", true),
        exists = json.optBoolean("exists", false),
        isMaster = json.optBoolean("isMaster", false),
        isProxy = json.optBoolean("isProxy", false),
        hasProxy = json.optBoolean("hasProxy", false),
        proxySize = if (json.has("proxySize") && !json.isNull("proxySize")) json.optLong("proxySize") else null,
        isProtectedOriginal = json.optBoolean("isProtectedOriginal", false),
        keepOriginalOnDevice = json.optBoolean("keepOriginalOnDevice", false),
        canReplaceWithProxy = json.optBoolean("canReplaceWithProxy", false),
        masterHash = json.optString("masterHash").takeIf { it.isNotBlank() && !json.isNull("masterHash") },
        savedPath = json.optString("savedPath").takeIf { it.isNotBlank() && !json.isNull("savedPath") },
        originalName = json.optString("originalName").takeIf { it.isNotBlank() && !json.isNull("originalName") },
        size = if (json.has("size") && !json.isNull("size")) json.optLong("size") else null
    )

    suspend fun checkHash(sha256: String): CheckResponse = withContext(Dispatchers.IO) {
        val req = Request.Builder()
            .url(makeUrl("/api/check/$sha256"))
            .get()
            .applyAuth()
            .build()
        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
            parseCheckResponse(JSONObject(text))
        }
    }

    suspend fun checkHashesBatch(hashes: List<String>): Map<String, CheckResponse> = withContext(Dispatchers.IO) {
        val cleaned = hashes
            .map { it.trim().lowercase() }
            .filter { it.isNotEmpty() }
            .distinct()
        if (cleaned.isEmpty()) return@withContext emptyMap()

        val merged = mutableMapOf<String, CheckResponse>()
        for (chunk in cleaned.chunked(500)) {
            val payload = JSONObject().apply {
                val arr = org.json.JSONArray()
                chunk.forEach { arr.put(it) }
                put("hashes", arr)
            }.toString()
            val req = Request.Builder()
                .url(makeUrl("/api/check/batch"))
                .post(payload.toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
                .applyAuth()
                .build()
            client.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
                val json = JSONObject(text)
                val resultsObj = json.optJSONObject("results") ?: continue
                val keys = resultsObj.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val itemObj = resultsObj.optJSONObject(key) ?: continue
                    merged[key.lowercase()] = parseCheckResponse(itemObj)
                }
            }
        }
        merged
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
                ProxyGenerator.createVideoProxy(
                    context = context,
                    masterFile = masterFile,
                    maxPixelSize = current.proxyMaxPixelSize,
                    quality = current.proxyQuality,
                    masterHash = photo.hash
                )
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

    private class SegmentedFallbackException : Exception()

    suspend fun downloadMasterToTempFile(
        hash: String,
        preferredFilename: String? = null,
        expectedSizeBytes: Long? = null,
        isVideo: Boolean = false,
        onProgress: ((downloadedBytes: Long, totalBytes: Long?) -> Unit)? = null
    ): File {
        val shareDir = File(context.cacheDir, "photohub_share_${UUID.randomUUID().toString().take(8)}")
        return downloadMasterToDirectory(hash, shareDir, preferredFilename, expectedSizeBytes, isVideo, onProgress).file
    }

    suspend fun downloadMasterToDirectory(
        hash: String,
        destDir: File,
        preferredFilename: String? = null,
        expectedSizeBytes: Long? = null,
        isVideo: Boolean = false,
        onProgress: ((downloadedBytes: Long, totalBytes: Long?) -> Unit)? = null
    ): DownloadedFileResult {
        val path = "/api/photo/$hash"
        val fallback = if (isVideo) "video_${hash.take(8)}.mp4" else "photo_${hash.take(8)}.jpg"
        // Small files finish faster in a single keep-alive HTTP request; larger or unknown files
        // try 2 MB ranged fetch + up to 3 parallel segments immediately (zero extra HEAD RTT).
        if (expectedSizeBytes != null && expectedSizeBytes in 1L until SMALL_SINGLE_STREAM_THRESHOLD_BYTES) {
            return streamDownloadToDirectory(path, destDir, preferredFilename, fallback, onProgress)
        }
        return try {
            downloadWithParallelRanges(path, destDir, preferredFilename, fallback, onProgress)
        } catch (_: SegmentedFallbackException) {
            streamDownloadToDirectory(path, destDir, preferredFilename, fallback, onProgress)
        }
    }

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

    private suspend fun downloadWithParallelRanges(
        path: String,
        destDir: File,
        preferredFilename: String?,
        fallbackFilename: String,
        onProgress: ((downloadedBytes: Long, totalBytes: Long?) -> Unit)?
    ): DownloadedFileResult = withContext(Dispatchers.IO) {
        val origUrl = makeUrl(path)
        val req = Request.Builder()
            .url(origUrl)
            .get()
            .applyAuth()
            .header("Range", "bytes=0-${INITIAL_RANGE_BYTES - 1L}")
            .build()

        destDir.mkdirs()
        val partFile = File(destDir, ".part_${UUID.randomUUID().toString().take(8)}")
        val origHost = safeHost(origUrl)

        try {
            var suggestedName = fallbackFilename
            var finalBytes = 0L

            client.newCall(req).execute().use { resp ->
                if (resp.code == 416) {
                    throw SegmentedFallbackException()
                }
                if (!resp.isSuccessful) {
                    val errText = resp.body?.string().orEmpty()
                    throw ApiHttpException(resp.code, parseErrorMessage(resp.code, errText))
                }

                suggestedName = resolveDownloadFilename(
                    preferredFilename = preferredFilename,
                    contentDisposition = resp.header("Content-Disposition"),
                    fallbackFilename = fallbackFilename
                )

                val body = resp.body ?: throw IOException("Empty download response")
                val rangeInfo = if (resp.code == 206) {
                    DownloadRangePlanner.parseContentRangeInfo(resp.header("Content-Range"))
                } else {
                    null
                }

                // If server sent full 200 OK or full file fit inside the initial 2 MB window, stream linearly.
                if (rangeInfo == null || rangeInfo.start != 0L || rangeInfo.end + 1L >= rangeInfo.total) {
                    val totalLen = rangeInfo?.total ?: body.contentLength().takeIf { it > 0L }
                    finalBytes = streamBodyToPartFile(body, partFile, totalLen, onProgress)
                } else {
                    val totalSize = rangeInfo.total
                    val remainingRanges = DownloadRangePlanner.buildRemainingByteRanges(
                        startOffset = rangeInfo.end + 1L,
                        totalSize = totalSize,
                        maxSegments = MAX_EXTRA_PARALLEL_SEGMENTS
                    )
                    val resolvedUrl = resp.request.url
                    val sameHost = origHost != null && resolvedUrl.host.equals(origHost, ignoreCase = true)

                    onProgress?.invoke(0L, totalSize)
                    val downloaded = AtomicLong(0L)
                    val lastNotify = AtomicLong(0L)
                    fun reportChunkBytes(added: Long) {
                        val curTotal = downloaded.addAndGet(added)
                        if (onProgress != null) {
                            val prev = lastNotify.get()
                            if (curTotal - prev >= PROGRESS_STEP_BYTES || curTotal >= totalSize) {
                                if (lastNotify.compareAndSet(prev, curTotal)) {
                                    onProgress.invoke(curTotal, totalSize)
                                }
                            }
                        }
                    }

                    RandomAccessFile(partFile, "rw").use { raf ->
                        raf.setLength(totalSize)
                        val channel = raf.channel
                        coroutineScope {
                            val firstJob = async {
                                streamBodyToChannel(body, channel, 0L, ::reportChunkBytes)
                            }
                            val extraJobs = remainingRanges.map { range ->
                                async {
                                    downloadRangeSegment(
                                        targetUrl = resolvedUrl,
                                        applyAuthHeader = sameHost,
                                        range = range,
                                        channel = channel,
                                        onBytes = ::reportChunkBytes
                                    )
                                }
                            }
                            firstJob.await()
                            extraJobs.awaitAll()
                        }
                    }

                    if (partFile.length() != totalSize) {
                        throw SegmentedFallbackException()
                    }
                    finalBytes = totalSize
                    onProgress?.invoke(finalBytes, totalSize)
                }
            }

            promotePartFile(partFile, destDir, suggestedName, finalBytes)
        } catch (err: Exception) {
            partFile.delete()
            throw err
        }
    }

    private suspend fun downloadRangeSegment(
        targetUrl: HttpUrl,
        applyAuthHeader: Boolean,
        range: LongRange,
        channel: FileChannel,
        onBytes: (Long) -> Unit
    ) {
        val builder = Request.Builder()
            .url(targetUrl)
            .get()
            .header("Range", "bytes=${range.first}-${range.last}")
        if (applyAuthHeader) builder.applyAuth()

        client.newCall(builder.build()).execute().use { resp ->
            if (!resp.isSuccessful) {
                val errText = resp.body?.string().orEmpty()
                throw ApiHttpException(resp.code, parseErrorMessage(resp.code, errText))
            }
            if (resp.code != 206) {
                throw SegmentedFallbackException()
            }
            val body = resp.body ?: throw SegmentedFallbackException()
            val expectedLen = (range.last - range.first) + 1L
            val written = streamBodyToChannel(body, channel, range.first, onBytes)
            if (written != expectedLen) {
                throw SegmentedFallbackException()
            }
        }
    }

    private suspend fun streamBodyToChannel(
        body: ResponseBody,
        channel: FileChannel,
        startPos: Long,
        onBytes: (Long) -> Unit
    ): Long {
        val coroutineCtx = currentCoroutineContext()
        val buffer = ByteArray(256 * 1024)
        var pos = startPos
        var total = 0L
        body.byteStream().use { input ->
            while (true) {
                coroutineCtx.ensureActive()
                val read = input.read(buffer)
                if (read <= 0) break
                pos = writeFullyAtPosition(channel, buffer, read, pos)
                total += read
                onBytes(read.toLong())
            }
        }
        return total
    }

    private fun writeFullyAtPosition(channel: FileChannel, bytes: ByteArray, length: Int, startPos: Long): Long {
        val buf = ByteBuffer.wrap(bytes, 0, length)
        var pos = startPos
        while (buf.hasRemaining()) {
            pos += channel.write(buf, pos)
        }
        return pos
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
                suggestedName = resolveDownloadFilename(
                    preferredFilename = preferredFilename,
                    contentDisposition = resp.header("Content-Disposition"),
                    fallbackFilename = fallbackFilename
                )
                val body = resp.body ?: throw IOException("Empty download response")
                val totalLen = body.contentLength().takeIf { it > 0L }
                downloaded = streamBodyToPartFile(body, partFile, totalLen, onProgress)
            }

            promotePartFile(partFile, destDir, suggestedName, downloaded)
        } catch (err: Exception) {
            partFile.delete()
            throw err
        }
    }

    private suspend fun streamBodyToPartFile(
        body: ResponseBody,
        partFile: File,
        totalLen: Long?,
        onProgress: ((downloadedBytes: Long, totalBytes: Long?) -> Unit)?
    ): Long {
        onProgress?.invoke(0L, totalLen)
        var downloaded = 0L
        var lastNotifyBytes = 0L
        val coroutineCtx = currentCoroutineContext()
        body.byteStream().use { input ->
            partFile.outputStream().use { output ->
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    coroutineCtx.ensureActive()
                    val read = input.read(buffer)
                    if (read <= 0) break
                    output.write(buffer, 0, read)
                    downloaded += read
                    if (onProgress != null && (downloaded - lastNotifyBytes >= PROGRESS_STEP_BYTES || (totalLen != null && downloaded >= totalLen))) {
                        lastNotifyBytes = downloaded
                        onProgress.invoke(downloaded, totalLen)
                    }
                }
            }
        }
        onProgress?.invoke(downloaded, totalLen)
        return downloaded
    }

    private fun resolveDownloadFilename(
        preferredFilename: String?,
        contentDisposition: String?,
        fallbackFilename: String
    ): String {
        val dispositionName = extractDispositionFilename(contentDisposition)
        val rawName = preferredFilename?.trim()?.takeIf { it.isNotEmpty() }
            ?: dispositionName
            ?: fallbackFilename
        return File(rawName).name.ifBlank { fallbackFilename }
    }

    private fun promotePartFile(
        partFile: File,
        destDir: File,
        suggestedName: String,
        bytesWritten: Long
    ): DownloadedFileResult {
        if (!partFile.exists() || partFile.length() <= 0L) {
            throw IOException("Downloaded file was empty.")
        }
        val finalFile = File(destDir, suggestedName)
        if (finalFile.exists()) finalFile.delete()
        if (!partFile.renameTo(finalFile)) {
            partFile.copyTo(finalFile, overwrite = true)
            partFile.delete()
        }
        return DownloadedFileResult(file = finalFile, suggestedFilename = suggestedName, bytesWritten = bytesWritten)
    }

    companion object {
        private const val SMALL_SINGLE_STREAM_THRESHOLD_BYTES = 1_500_000L
        private const val INITIAL_RANGE_BYTES = 1L * 1024L * 1024L
        private const val MAX_EXTRA_PARALLEL_SEGMENTS = 4
        private const val PROGRESS_STEP_BYTES = 64L * 1024L
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

    suspend fun deleteServerPhoto(hash: String) = withContext(Dispatchers.IO) {
        val cleanHash = hash.trim().lowercase(Locale.ROOT)
        if (cleanHash.isEmpty()) throw IOException("Photo hash is required.")

        val req = Request.Builder()
            .url(makeUrl("/api/photo/$cleanHash"))
            .applyAuth()
            .delete()
            .build()

        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
        }

        val cur = settings.current
        LocalProxyStore.getInstance(context).removePhoto(
            hash = cleanHash,
            baseUrl = cur.normalizedBaseUrl,
            scopeKey = cur.apiKeyCacheScope,
            notify = true
        )
        LocalProxyTracker.getInstance(context).clearRestoredProtection(cleanHash)
        OriginalDownloadCache.removeCachedOriginals(context, listOf(cleanHash))
    }

    suspend fun deleteServerPhotosBatch(hashes: List<String>): DeletePhotosResult = withContext(Dispatchers.IO) {
        val cleaned = hashes
            .map { it.trim().lowercase(Locale.ROOT) }
            .filter { it.isNotEmpty() }
            .distinct()
        if (cleaned.isEmpty()) {
            return@withContext DeletePhotosResult(
                success = true,
                deleted = emptyList(),
                missing = emptyList(),
                freedBytes = 0L
            )
        }

        val allDeleted = mutableListOf<String>()
        val allMissing = mutableListOf<String>()
        var totalFreed = 0L
        var anyFailed = false

        var idx = 0
        while (idx < cleaned.size) {
            val end = minOf(cleaned.size, idx + 200)
            val chunk = cleaned.subList(idx, end)
            idx = end

            val payload = JSONObject().apply {
                put("hashes", JSONArray(chunk))
            }.toString()

            val req = Request.Builder()
                .url(makeUrl("/api/photos/delete"))
                .applyAuth()
                .post(payload.toRequestBody("application/json; charset=utf-8".toMediaTypeOrNull()))
                .build()

            client.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) throw ApiHttpException(resp.code, parseErrorMessage(resp.code, text))
                val json = JSONObject(text)
                if (!json.optBoolean("success", false)) {
                    anyFailed = true
                }
                json.optJSONArray("deleted")?.let { arr ->
                    for (i in 0 until arr.length()) {
                        arr.optString(i).takeIf { it.isNotBlank() }?.let { allDeleted.add(it) }
                    }
                }
                json.optJSONArray("missing")?.let { arr ->
                    for (i in 0 until arr.length()) {
                        arr.optString(i).takeIf { it.isNotBlank() }?.let { allMissing.add(it) }
                    }
                }
                totalFreed += json.optLong("freedBytes", 0L)
            }
        }

        val toEvict = (allDeleted + allMissing).distinct()
        if (toEvict.isNotEmpty()) {
            val cur = settings.current
            LocalProxyStore.getInstance(context).removePhotos(
                hashes = toEvict,
                baseUrl = cur.normalizedBaseUrl,
                scopeKey = cur.apiKeyCacheScope,
                notify = true
            )
            val tracker = LocalProxyTracker.getInstance(context)
            toEvict.forEach { tracker.clearRestoredProtection(it) }
            OriginalDownloadCache.removeCachedOriginals(context, toEvict)
        }

        DeletePhotosResult(
            success = !anyFailed,
            deleted = allDeleted,
            missing = allMissing,
            freedBytes = totalFreed
        )
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
