package com.photohub.compressor.data

import android.net.Uri
import android.text.format.Formatter
import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Date
import java.util.Locale

enum class UploadMode(val rawValue: String, val displayName: String) {
    DIRECT_VPS("direct_vps", "Direct"),
    S3_PRESIGNED("s3_presigned", "S3");

    companion object {
        fun fromRaw(raw: String?): UploadMode =
            entries.firstOrNull { it.rawValue == raw } ?: DIRECT_VPS
    }
}

enum class ProxyFormat(val rawValue: String, val displayName: String) {
    HEIC("heic", "HEIC"),
    JPEG("jpeg", "JPEG");

    companion object {
        fun fromRaw(raw: String?): ProxyFormat =
            entries.firstOrNull { it.rawValue == raw } ?: HEIC
    }
}

enum class CandidateSortMode(val rawValue: String, val displayName: String) {
    LARGEST_VIDEOS_FIRST("largest_videos_first", "Largest Videos First"),
    LARGEST_FIRST("largest_first", "Largest Files First"),
    NEWEST_FIRST("newest_first", "Newest First");

    companion object {
        fun fromRaw(raw: String?): CandidateSortMode =
            entries.firstOrNull { it.rawValue == raw } ?: LARGEST_VIDEOS_FIRST
    }
}

data class ServerStorageInfo(
    val usedBytes: Long,
    val mastersBytes: Long?,
    val proxiesBytes: Long?,
    val itemCount: Int?,
    val quotaBytes: Long?,
    val remainingBytes: Long?,
    val diskTotalBytes: Long?,
    val diskFreeBytes: Long?
) {
    val effectiveLimitBytes: Long?
        get() = when {
            quotaBytes != null && quotaBytes > 0 -> quotaBytes
            diskTotalBytes != null && diskTotalBytes > 0 -> diskTotalBytes
            else -> null
        }

    val isFixedQuota: Boolean
        get() = (quotaBytes ?: 0L) > 0L

    val usageFraction: Float
        get() {
            val limit = effectiveLimitBytes ?: return 0f
            if (limit <= 0L) return 0f
            return (usedBytes.toDouble() / limit.toDouble()).coerceIn(0.0, 1.0).toFloat()
        }

    fun toJson(): JSONObject = JSONObject().apply {
        put("usedBytes", usedBytes)
        if (mastersBytes != null) put("mastersBytes", mastersBytes)
        if (proxiesBytes != null) put("proxiesBytes", proxiesBytes)
        if (itemCount != null) put("itemCount", itemCount)
        if (quotaBytes != null) put("quotaBytes", quotaBytes)
        if (remainingBytes != null) put("remainingBytes", remainingBytes)
        if (diskTotalBytes != null) put("diskTotalBytes", diskTotalBytes)
        if (diskFreeBytes != null) put("diskFreeBytes", diskFreeBytes)
    }

    companion object {
        fun fromJson(obj: JSONObject?): ServerStorageInfo? {
            obj ?: return null
            return ServerStorageInfo(
                usedBytes = obj.optLong("usedBytes", 0L),
                mastersBytes = if (obj.has("mastersBytes") && !obj.isNull("mastersBytes")) obj.optLong("mastersBytes") else null,
                proxiesBytes = if (obj.has("proxiesBytes") && !obj.isNull("proxiesBytes")) obj.optLong("proxiesBytes") else null,
                itemCount = if (obj.has("itemCount") && !obj.isNull("itemCount")) obj.optInt("itemCount") else null,
                quotaBytes = if (obj.has("quotaBytes") && !obj.isNull("quotaBytes")) obj.optLong("quotaBytes") else null,
                remainingBytes = if (obj.has("remainingBytes") && !obj.isNull("remainingBytes")) obj.optLong("remainingBytes") else null,
                diskTotalBytes = if (obj.has("diskTotalBytes") && !obj.isNull("diskTotalBytes")) obj.optLong("diskTotalBytes") else null,
                diskFreeBytes = if (obj.has("diskFreeBytes") && !obj.isNull("diskFreeBytes")) obj.optLong("diskFreeBytes") else null
            )
        }
    }
}

data class WhoAmIResponse(
    val success: Boolean,
    val authMode: String?,
    val userFolder: String?,
    val email: String?,
    val name: String?,
    val nodeId: String?,
    val indexedPhotos: Int,
    val s3Enabled: Boolean?,
    val storage: ServerStorageInfo?
)

data class GoogleUserProfile(
    val email: String,
    val name: String,
    val folderName: String
)

data class GoogleExchangeResponse(
    val success: Boolean,
    val token: String,
    val serverUrl: String,
    val nodeId: String,
    val user: GoogleUserProfile
)

data class AuthResolveResponse(
    val success: Boolean,
    val serverUrl: String,
    val nodeId: String?,
    val user: GoogleUserProfile?
)

data class CheckResponse(
    val success: Boolean,
    val exists: Boolean,
    val isMaster: Boolean,
    val isProxy: Boolean,
    val hasProxy: Boolean,
    val proxySize: Long?,
    val isProtectedOriginal: Boolean,
    val keepOriginalOnDevice: Boolean,
    val canReplaceWithProxy: Boolean,
    val masterHash: String?,
    val savedPath: String?,
    val originalName: String? = null,
    val size: Long? = null
)

data class UploadConfirmResponse(
    val success: Boolean,
    val canDelete: Boolean,
    val checksumVerified: Boolean,
    val canReplaceWithProxy: Boolean,
    val serverSha256: String?,
    val hash: String?,
    val savedPath: String?,
    val error: String?
)

data class ServerPhoto(
    val hash: String,
    val originalName: String,
    val size: Long,
    val photoDate: String,
    val takenAt: String?,
    val uploadedAt: String,
    val savedPath: String,
    val hasProxy: Boolean?,
    val hasPreview: Boolean?,
    val proxyHash: String?,
    val proxySize: Long?,
    val hasVideoProxy: Boolean?,
    val videoProxySize: Long?,
    val keepOriginalOnDevice: Boolean?,
    val isFavorite: Boolean? = null,
    val deletedAt: String? = null,
    val daysRemaining: Int? = null,
    val cameraModel: String? = null
) {
    val isProtectedOriginal: Boolean
        get() = keepOriginalOnDevice == true

    val isFavorited: Boolean
        get() = isFavorite == true

    val isTrashed: Boolean
        get() = !deletedAt.isNullOrBlank()

    val isVideo: Boolean
        get() {
            val ext = originalName.substringAfterLast('.', "").lowercase(Locale.ROOT)
            return ext in setOf("mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm")
        }

    val needsProxy: Boolean
        get() = (hasProxy != true) || (hasPreview == false)

    val parsedCreationDateMs: Long?
        get() = parseDateMs(takenAt)
            ?: parseDateMs(photoDate)
            ?: parseDayFromSavedPath(savedPath)
            ?: parseDateMs(uploadedAt)

    fun toJson(): JSONObject = JSONObject().apply {
        put("hash", hash)
        put("originalName", originalName)
        put("size", size)
        put("photoDate", photoDate)
        if (takenAt != null) put("takenAt", takenAt)
        put("uploadedAt", uploadedAt)
        put("savedPath", savedPath)
        if (hasProxy != null) put("hasProxy", hasProxy)
        if (hasPreview != null) put("hasPreview", hasPreview)
        if (proxyHash != null) put("proxyHash", proxyHash)
        if (proxySize != null) put("proxySize", proxySize)
        if (hasVideoProxy != null) put("hasVideoProxy", hasVideoProxy)
        if (videoProxySize != null) put("videoProxySize", videoProxySize)
        if (keepOriginalOnDevice != null) put("keepOriginalOnDevice", keepOriginalOnDevice)
        if (isFavorite != null) put("isFavorite", isFavorite)
        if (deletedAt != null) put("deletedAt", deletedAt)
        if (daysRemaining != null) put("daysRemaining", daysRemaining)
        if (cameraModel != null) put("cameraModel", cameraModel)
    }

    companion object {
        private val pathDayRegex = Regex("""(?:^|/)(\d{4})[-_/](\d{2})[-_/](\d{2})(?:/|$)""")

        fun fromJson(obj: JSONObject): ServerPhoto = ServerPhoto(
            hash = obj.optString("hash", ""),
            originalName = obj.optString("originalName", "photo.jpg"),
            size = obj.optLong("size", 0L),
            photoDate = obj.optString("photoDate", ""),
            takenAt = obj.optString("takenAt", "").takeIf { it.isNotBlank() },
            uploadedAt = obj.optString("uploadedAt", ""),
            savedPath = obj.optString("savedPath", ""),
            hasProxy = if (obj.has("hasProxy") && !obj.isNull("hasProxy")) obj.optBoolean("hasProxy") else null,
            hasPreview = if (obj.has("hasPreview") && !obj.isNull("hasPreview")) obj.optBoolean("hasPreview") else null,
            proxyHash = obj.optString("proxyHash", "").takeIf { it.isNotBlank() },
            proxySize = if (obj.has("proxySize") && !obj.isNull("proxySize")) obj.optLong("proxySize") else null,
            hasVideoProxy = if (obj.has("hasVideoProxy") && !obj.isNull("hasVideoProxy")) obj.optBoolean("hasVideoProxy") else null,
            videoProxySize = if (obj.has("videoProxySize") && !obj.isNull("videoProxySize")) obj.optLong("videoProxySize") else null,
            keepOriginalOnDevice = if (obj.has("keepOriginalOnDevice") && !obj.isNull("keepOriginalOnDevice")) obj.optBoolean("keepOriginalOnDevice") else null,
            isFavorite = if (obj.has("isFavorite") && !obj.isNull("isFavorite")) obj.optBoolean("isFavorite") else null,
            deletedAt = obj.optString("deletedAt", "").takeIf { it.isNotBlank() && !obj.isNull("deletedAt") },
            daysRemaining = if (obj.has("daysRemaining") && !obj.isNull("daysRemaining")) obj.optInt("daysRemaining") else null,
            cameraModel = obj.optString("cameraModel", "").takeIf { it.isNotBlank() && !obj.isNull("cameraModel") }
        )

        fun listFromJsonArray(arr: JSONArray?): List<ServerPhoto> {
            arr ?: return emptyList()
            val out = ArrayList<ServerPhoto>(arr.length())
            for (i in 0 until arr.length()) {
                val item = arr.optJSONObject(i) ?: continue
                if (item.optString("hash").isNotBlank()) {
                    out.add(fromJson(item))
                }
            }
            return out
        }

        fun listToJsonArray(list: List<ServerPhoto>): JSONArray {
            val arr = JSONArray()
            for (item in list) arr.put(item.toJson())
            return arr
        }

        private fun parseDayFromSavedPath(savedPath: String): Long? {
            val norm = savedPath.replace('\\', '/')
            val match = pathDayRegex.find(norm) ?: return null
            val y = match.groupValues[1]
            val m = match.groupValues[2]
            val d = match.groupValues[3]
            return parseDateMs("$y-$m-$d")
        }

        fun parseDateMs(raw: String?): Long? {
            val trimmed = raw?.trim().orEmpty()
            if (trimmed.isEmpty()) return null
            return try {
                Instant.parse(trimmed).toEpochMilli()
            } catch (_: Exception) {
                try {
                    val date = LocalDate.parse(trimmed.take(10), DateTimeFormatter.ISO_LOCAL_DATE)
                    date.atTime(12, 0).toInstant(ZoneOffset.UTC).toEpochMilli()
                } catch (_: Exception) {
                    null
                }
            }
        }
    }
}

sealed class PhotoCompressionState {
    data object Pending : PhotoCompressionState()
    data object Hashing : PhotoCompressionState()
    data object AlreadyProxy : PhotoCompressionState()
    data object UploadingInBackground : PhotoCompressionState()
    data class Uploading(val progress: Double) : PhotoCompressionState()
    data object VerifyingChecksum : PhotoCompressionState()
    data object CreatingProxy : PhotoCompressionState()
    data object ReplacingInPhotos : PhotoCompressionState()
    data class ReadyToDelete(val savedBytes: Long) : PhotoCompressionState()
    data class Completed(val savedBytes: Long) : PhotoCompressionState()
    data class Skipped(val reason: String) : PhotoCompressionState()
    data class Failed(val message: String) : PhotoCompressionState()

    fun label(context: Context): String = when (this) {
        is Pending -> "Tap to Select"
        is Hashing -> "Hashing SHA-256…"
        is AlreadyProxy -> "Already Compressed Proxy"
        is UploadingInBackground -> "Uploading in Background…"
        is Uploading -> "Uploading ${(progress * 100).toInt()}%"
        is VerifyingChecksum -> "Verifying SHA-256…"
        is CreatingProxy -> "Compressing Proxy…"
        is ReplacingInPhotos -> "Saving Proxy to Gallery…"
        is ReadyToDelete -> {
            val formatted = Formatter.formatFileSize(context, savedBytes.coerceAtLeast(0L))
            "Backed Up · Ready to Delete Original (Free $formatted)"
        }
        is Completed -> {
            if (savedBytes <= 0L) {
                "Backed Up · Original Kept"
            } else {
                val formatted = Formatter.formatFileSize(context, savedBytes.coerceAtLeast(0L))
                "Verified & Saved $formatted"
            }
        }
        is Skipped -> reason
        is Failed -> "Error: $message"
    }

    val isFinished: Boolean
        get() = when (this) {
            is Completed, is ReadyToDelete, is AlreadyProxy, is UploadingInBackground, is Skipped -> true
            else -> false
        }

    val isIntegrityVerified: Boolean
        get() = when (this) {
            is ReadyToDelete, is Completed -> true
            is Skipped -> reason.contains("Backed up", ignoreCase = true)
            else -> false
        }

    val stageFraction: Double
        get() = when (this) {
            is Pending -> 0.0
            is Hashing -> 0.06
            is Uploading -> 0.12 + progress.coerceIn(0.0, 1.0) * 0.62
            is VerifyingChecksum -> 0.78
            is CreatingProxy -> 0.86
            is ReplacingInPhotos -> 0.94
            is AlreadyProxy, is UploadingInBackground, is ReadyToDelete, is Completed, is Skipped, is Failed -> 1.0
        }
}

data class PhotoCandidate(
    val id: String, // content:// MediaStore URI string
    val mediaStoreId: Long,
    val isVideo: Boolean,
    val durationMs: Long,
    val filename: String,
    val mimeType: String,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val creationDateMs: Long?,
    val estimatedBytes: Long,
    val state: PhotoCompressionState = PhotoCompressionState.Pending,
    val isSelected: Boolean = false,
    val masterHash: String? = null,
    val detectionSource: String? = null,
    val linkedOriginalName: String? = null,
    val linkedOriginalBytes: Long? = null,
    val isBackedUpOnServer: Boolean = false
) {
    val contentUri: Uri get() = Uri.parse(id)
    val isDetectedProxy: Boolean get() = state is PhotoCompressionState.AlreadyProxy
    fun estimatedSizeLabel(context: Context): String =
        "~${Formatter.formatFileSize(context, estimatedBytes.coerceAtLeast(0L))}"

    val resolutionLabel: String
        get() {
            if (isVideo) {
                val totalSec = (durationMs / 1000L).coerceAtLeast(0L)
                val mins = totalSec / 60L
                val secs = totalSec % 60L
                val durStr = String.format(Locale.US, "%d:%02d", mins, secs)
                return if (pixelWidth > 0 && pixelHeight > 0) {
                    "Video $durStr ($pixelWidth×$pixelHeight)"
                } else {
                    "Video $durStr"
                }
            }
            if (pixelWidth <= 0 || pixelHeight <= 0) return "Photo"
            val mp = (pixelWidth.toDouble() * pixelHeight.toDouble()) / 1_000_000.0
            return String.format(Locale.US, "%.1f MP (%d×%d)", mp, pixelWidth, pixelHeight)
        }
}

data class ShareLinkResult(
    val token: String,
    val shareUrl: String,
    val title: String,
    val expiresAt: String,
    val hasPasscode: Boolean
)

data class TrashListResult(
    val photos: List<ServerPhoto>,
    val total: Int,
    val trashBytes: Long,
    val retentionDays: Int
)

data class StagedCleanupItem(
    val id: String,
    val filename: String,
    val masterSha256: String,
    val savedBytes: Long,
    val verifiedAtMs: Long
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("filename", filename)
        put("masterSha256", masterSha256)
        put("savedBytes", savedBytes)
        put("verifiedAtMs", verifiedAtMs)
    }

    companion object {
        fun fromJson(obj: JSONObject): StagedCleanupItem = StagedCleanupItem(
            id = obj.optString("id"),
            filename = obj.optString("filename"),
            masterSha256 = obj.optString("masterSha256"),
            savedBytes = obj.optLong("savedBytes", 0L),
            verifiedAtMs = obj.optLong("verifiedAtMs", System.currentTimeMillis())
        )
    }
}
