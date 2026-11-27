package com.photohub.compressor.data

import android.content.Context
import android.content.SharedPreferences
import com.photohub.compressor.BuildConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.net.URI

enum class ProxyResolutionPreset(
    val maxPixelSize: Int,
    val title: String,
    val resolutionHint: String
) {
    AUTO_SMART(0, "Auto", "Auto · 720p"),
    P480(854, "480p", "480p · 854 px"),
    P720(1280, "720p", "720p · 1280 px"),
    P1080(1920, "1080p", "1080p · 1920 px"),
    P1440(2560, "1440p", "1440p · 2560 px");

    companion object {
        fun fromStoredPixels(px: Int): ProxyResolutionPreset = when {
            px <= 0 -> AUTO_SMART
            px <= 960 -> P480
            px <= 1440 -> P720
            px <= 2100 -> P1080
            else -> P1440
        }
    }
}

enum class ProxyDetailPreset(
    val qualityValue: Float,
    val title: String
) {
    COMPACT(0.50f, "Smallest"),
    BALANCED(0.68f, "Balance"),
    HIGH_DETAIL(0.85f, "High");

    companion object {
        fun fromStoredQuality(q: Float): ProxyDetailPreset = when {
            q < 0.59f -> COMPACT
            q <= 0.77f -> BALANCED
            else -> HIGH_DETAIL
        }
    }
}

data class AppSettingsState(
    val authToken: String = "",
    val assignedServerUrl: String = "",
    val assignedNodeId: String = "primary",
    val userEmail: String = "",
    val userName: String = "",
    val userFolder: String = "",
    val serverStorage: ServerStorageInfo? = null,
    val serverS3Enabled: Boolean = false,
    val uploadMode: UploadMode = UploadMode.DIRECT_VPS,
    val proxyFormat: ProxyFormat = ProxyFormat.HEIC,
    val proxyMaxPixelSize: Int = 0,
    val proxyQuality: Float = 0.72f,
    val minimumOriginalSizeKB: Int = 500,
    val keepLocalProxyInPhotos: Boolean = true,
    val autoCompressOnOpen: Boolean = false,
    val autoDownloadLocalProxies: Boolean = false,
    val autoDownloadLocalVideos: Boolean = false,
    val autoSaveProxiesToPhotosApp: Boolean = false,
    val nightlyAutoBackupEnabled: Boolean = true,
    val nightlyRequiresCharging: Boolean = false,
    val notifyWhenBackgroundUploadFinishes: Boolean = true,
    val silentAutoDeleteOriginals: Boolean = false,
    val morningReminderHour: Int = 8,
    val candidateSortMode: CandidateSortMode = CandidateSortMode.LARGEST_VIDEOS_FIRST
) {
    val isSignedIn: Boolean
        get() = authToken.trim().isNotEmpty()

    val gatewayUrl: String?
        get() = normalizeUrl(BuildConfig.PHOTOHUB_GATEWAY_URL, defaultScheme = "https")

    val normalizedBaseUrl: String?
        get() = normalizeUrl(assignedServerUrl, defaultScheme = "http") ?: gatewayUrl

    val apiKeyCacheScope: String
        get() = when {
            userFolder.isNotEmpty() -> userFolder
            userEmail.isNotEmpty() -> userEmail
            else -> authToken
        }

    companion object {
        fun normalizeUrl(raw: String?, defaultScheme: String = "https"): String? {
            val trimmed = raw?.trim()?.trimEnd('/') ?: ""
            if (trimmed.isEmpty()) return null
            val candidate = if (
                trimmed.startsWith("http://", ignoreCase = true) ||
                trimmed.startsWith("https://", ignoreCase = true)
            ) {
                trimmed
            } else {
                "$defaultScheme://$trimmed"
            }
            return try {
                val uri = URI(candidate)
                if (uri.host.isNullOrBlank()) null else candidate
            } catch (_: Exception) {
                null
            }
        }
    }
}

class AppSettings private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val prefs: SharedPreferences =
        appContext.getSharedPreferences("photohub_app_settings", Context.MODE_PRIVATE)

    private object SessionKeys {
        const val AUTH_TOKEN = "sessionToken"
        const val ASSIGNED_SERVER_URL = "assignedServerURL"
        const val ASSIGNED_NODE_ID = "assignedNodeId"
        const val USER_EMAIL = "userEmail"
        const val USER_NAME = "userName"
        const val USER_FOLDER = "userFolder"
        val all = listOf(
            AUTH_TOKEN,
            ASSIGNED_SERVER_URL,
            ASSIGNED_NODE_ID,
            USER_EMAIL,
            USER_NAME,
            USER_FOLDER
        )
    }

    private object PrefKeys {
        const val UPLOAD_MODE = "uploadMode"
        const val SERVER_S3_ENABLED = "serverS3Enabled"
        const val PROXY_FORMAT = "proxyFormat"
        const val PROXY_MAX_PX = "proxyMaxPixelSize"
        const val PROXY_QUALITY = "proxyQuality"
        const val MIN_ORIG_KB = "minimumOriginalSizeKB"
        const val KEEP_LOCAL_PROXY = "keepLocalProxyInPhotos"
        const val AUTO_COMPRESS_OPEN = "autoCompressOnOpen"
        const val AUTO_DOWNLOAD_PROXIES = "autoDownloadLocalProxies"
        const val AUTO_DOWNLOAD_VIDEOS = "autoDownloadLocalVideos"
        const val AUTO_SAVE_PHOTOS = "autoSaveProxiesToPhotosApp"
        const val NIGHTLY_BACKUP = "nightlyAutoBackupEnabled"
        const val NIGHTLY_CHARGING = "nightlyRequiresCharging"
        const val NOTIFY_ON_FINISH = "notifyWhenBackgroundUploadFinishes"
        const val SILENT_AUTO_DELETE = "silentAutoDeleteOriginals"
        const val MORNING_HOUR = "morningReminderHour"
        const val SORT_MODE = "candidateSortMode"
    }

    private val _state = MutableStateFlow(loadInitialState())
    val state: StateFlow<AppSettingsState> = _state.asStateFlow()

    val current: AppSettingsState
        get() = _state.value

    val pinnedCertHashes: List<String>
        get() = BuildConfig.PHOTOHUB_PINNED_CERT_SHA256
            .split(',', ';', ' ')
            .map { it.trim() }
            .filter { it.isNotEmpty() }

    private fun loadInitialState(): AppSettingsState = AppSettingsState(
        authToken = SecureTokenStore.get(appContext, SessionKeys.AUTH_TOKEN).orEmpty(),
        assignedServerUrl = SecureTokenStore.get(appContext, SessionKeys.ASSIGNED_SERVER_URL).orEmpty(),
        assignedNodeId = SecureTokenStore.get(appContext, SessionKeys.ASSIGNED_NODE_ID)?.ifBlank { "primary" } ?: "primary",
        userEmail = SecureTokenStore.get(appContext, SessionKeys.USER_EMAIL).orEmpty(),
        userName = SecureTokenStore.get(appContext, SessionKeys.USER_NAME).orEmpty(),
        userFolder = SecureTokenStore.get(appContext, SessionKeys.USER_FOLDER).orEmpty(),
        serverS3Enabled = prefs.getBoolean(PrefKeys.SERVER_S3_ENABLED, false),
        uploadMode = if (prefs.getBoolean(PrefKeys.SERVER_S3_ENABLED, false)) UploadMode.S3_PRESIGNED else UploadMode.DIRECT_VPS,
        proxyFormat = ProxyFormat.fromRaw(prefs.getString(PrefKeys.PROXY_FORMAT, ProxyFormat.HEIC.rawValue)),
        proxyMaxPixelSize = prefs.getInt(PrefKeys.PROXY_MAX_PX, 0),
        proxyQuality = prefs.getFloat(PrefKeys.PROXY_QUALITY, 0.72f),
        minimumOriginalSizeKB = prefs.getInt(PrefKeys.MIN_ORIG_KB, 500),
        keepLocalProxyInPhotos = prefs.getBoolean(PrefKeys.KEEP_LOCAL_PROXY, true),
        autoCompressOnOpen = prefs.getBoolean(PrefKeys.AUTO_COMPRESS_OPEN, false),
        autoDownloadLocalProxies = prefs.getBoolean(PrefKeys.AUTO_DOWNLOAD_PROXIES, false),
        autoDownloadLocalVideos = prefs.getBoolean(PrefKeys.AUTO_DOWNLOAD_VIDEOS, false),
        autoSaveProxiesToPhotosApp = prefs.getBoolean(PrefKeys.AUTO_SAVE_PHOTOS, false),
        nightlyAutoBackupEnabled = prefs.getBoolean(PrefKeys.NIGHTLY_BACKUP, true),
        nightlyRequiresCharging = prefs.getBoolean(PrefKeys.NIGHTLY_CHARGING, false),
        notifyWhenBackgroundUploadFinishes = prefs.getBoolean(PrefKeys.NOTIFY_ON_FINISH, true),
        silentAutoDeleteOriginals = prefs.getBoolean(PrefKeys.SILENT_AUTO_DELETE, false),
        morningReminderHour = prefs.getInt(PrefKeys.MORNING_HOUR, 8),
        candidateSortMode = CandidateSortMode.fromRaw(
            prefs.getString(PrefKeys.SORT_MODE, CandidateSortMode.LARGEST_VIDEOS_FIRST.rawValue)
        )
    )

    fun applyGoogleSession(
        token: String,
        serverUrl: String,
        nodeId: String?,
        email: String,
        name: String,
        folderName: String
    ) {
        val cleanToken = token.trim()
        val cleanServer = serverUrl.trim().trimEnd('/')
        val cleanNode = (nodeId ?: "primary").trim().ifEmpty { "primary" }
        val cleanEmail = email.trim()
        val cleanName = name.trim()
        val cleanFolder = folderName.trim()

        SecureTokenStore.set(appContext, SessionKeys.AUTH_TOKEN, cleanToken)
        SecureTokenStore.set(appContext, SessionKeys.ASSIGNED_SERVER_URL, cleanServer)
        SecureTokenStore.set(appContext, SessionKeys.ASSIGNED_NODE_ID, cleanNode)
        SecureTokenStore.set(appContext, SessionKeys.USER_EMAIL, cleanEmail)
        SecureTokenStore.set(appContext, SessionKeys.USER_NAME, cleanName)
        SecureTokenStore.set(appContext, SessionKeys.USER_FOLDER, cleanFolder)

        _state.update {
            it.copy(
                authToken = cleanToken,
                assignedServerUrl = cleanServer,
                assignedNodeId = cleanNode,
                userEmail = cleanEmail,
                userName = cleanName,
                userFolder = cleanFolder
            )
        }
    }

    fun updateResolvedNode(
        serverUrl: String,
        nodeId: String?,
        folderName: String?,
        email: String?,
        name: String?
    ) {
        val cleanServer = serverUrl.trim().trimEnd('/')
        _state.update { prev ->
            var nextServer = prev.assignedServerUrl
            var nextNode = prev.assignedNodeId
            var nextFolder = prev.userFolder
            var nextEmail = prev.userEmail
            var nextName = prev.userName

            if (cleanServer.isNotEmpty() && cleanServer != prev.assignedServerUrl) {
                SecureTokenStore.set(appContext, SessionKeys.ASSIGNED_SERVER_URL, cleanServer)
                nextServer = cleanServer
            }
            if (!nodeId.isNullOrBlank() && nodeId != prev.assignedNodeId) {
                SecureTokenStore.set(appContext, SessionKeys.ASSIGNED_NODE_ID, nodeId)
                nextNode = nodeId
            }
            if (folderName != null && folderName != prev.userFolder) {
                SecureTokenStore.set(appContext, SessionKeys.USER_FOLDER, folderName)
                nextFolder = folderName
            }
            if (!email.isNullOrBlank() && email != prev.userEmail) {
                SecureTokenStore.set(appContext, SessionKeys.USER_EMAIL, email)
                nextEmail = email
            }
            if (!name.isNullOrBlank() && name != prev.userName) {
                SecureTokenStore.set(appContext, SessionKeys.USER_NAME, name)
                nextName = name
            }
            prev.copy(
                assignedServerUrl = nextServer,
                assignedNodeId = nextNode,
                userFolder = nextFolder,
                userEmail = nextEmail,
                userName = nextName
            )
        }
    }

    fun updateServerStorage(storage: ServerStorageInfo?) {
        _state.update { it.copy(serverStorage = storage) }
    }

    fun updateServerCapabilities(storage: ServerStorageInfo?, s3Enabled: Boolean?) {
        if (s3Enabled != null) {
            val mode = if (s3Enabled) UploadMode.S3_PRESIGNED else UploadMode.DIRECT_VPS
            prefs.edit()
                .putBoolean(PrefKeys.SERVER_S3_ENABLED, s3Enabled)
                .putString(PrefKeys.UPLOAD_MODE, mode.rawValue)
                .apply()
            _state.update {
                it.copy(
                    serverStorage = storage ?: it.serverStorage,
                    serverS3Enabled = s3Enabled,
                    uploadMode = mode
                )
            }
        } else if (storage != null) {
            _state.update { it.copy(serverStorage = storage) }
        }
    }

    fun signOut() {
        SecureTokenStore.clearKeys(appContext, SessionKeys.all)
        _state.update {
            it.copy(
                authToken = "",
                assignedServerUrl = "",
                assignedNodeId = "primary",
                userEmail = "",
                userName = "",
                userFolder = "",
                serverStorage = null
            )
        }
    }

    fun setUploadMode(mode: UploadMode) {
        prefs.edit().putString(PrefKeys.UPLOAD_MODE, mode.rawValue).apply()
        _state.update { it.copy(uploadMode = mode) }
    }

    fun setProxyFormat(format: ProxyFormat) {
        prefs.edit().putString(PrefKeys.PROXY_FORMAT, format.rawValue).apply()
        _state.update { it.copy(proxyFormat = format) }
    }

    fun setProxyMaxPixelSize(maxPx: Int) {
        prefs.edit().putInt(PrefKeys.PROXY_MAX_PX, maxPx).apply()
        _state.update { it.copy(proxyMaxPixelSize = maxPx) }
    }

    fun setProxyQuality(quality: Float) {
        val clamped = quality.coerceIn(0.4f, 0.95f)
        prefs.edit().putFloat(PrefKeys.PROXY_QUALITY, clamped).apply()
        _state.update { it.copy(proxyQuality = clamped) }
    }

    fun setKeepLocalProxyInPhotos(enabled: Boolean) {
        prefs.edit().putBoolean(PrefKeys.KEEP_LOCAL_PROXY, enabled).apply()
        _state.update { it.copy(keepLocalProxyInPhotos = enabled) }
    }

    fun setAutoCompressOnOpen(enabled: Boolean) {
        prefs.edit().putBoolean(PrefKeys.AUTO_COMPRESS_OPEN, enabled).apply()
        _state.update { it.copy(autoCompressOnOpen = enabled) }
    }

    fun setAutoDownloadLocalProxies(enabled: Boolean) {
        prefs.edit().putBoolean(PrefKeys.AUTO_DOWNLOAD_PROXIES, enabled).apply()
        _state.update { it.copy(autoDownloadLocalProxies = enabled) }
    }

    fun setAutoDownloadLocalVideos(enabled: Boolean) {
        prefs.edit().putBoolean(PrefKeys.AUTO_DOWNLOAD_VIDEOS, enabled).apply()
        _state.update { it.copy(autoDownloadLocalVideos = enabled) }
    }

    fun setAutoSaveProxiesToPhotosApp(enabled: Boolean) {
        prefs.edit().putBoolean(PrefKeys.AUTO_SAVE_PHOTOS, enabled).apply()
        _state.update { it.copy(autoSaveProxiesToPhotosApp = enabled) }
    }

    fun setNightlyAutoBackupEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(PrefKeys.NIGHTLY_BACKUP, enabled).apply()
        _state.update { it.copy(nightlyAutoBackupEnabled = enabled) }
    }

    fun setNightlyRequiresCharging(enabled: Boolean) {
        prefs.edit().putBoolean(PrefKeys.NIGHTLY_CHARGING, enabled).apply()
        _state.update { it.copy(nightlyRequiresCharging = enabled) }
    }

    fun setNotifyWhenBackgroundUploadFinishes(enabled: Boolean) {
        prefs.edit().putBoolean(PrefKeys.NOTIFY_ON_FINISH, enabled).apply()
        _state.update { it.copy(notifyWhenBackgroundUploadFinishes = enabled) }
    }

    fun setSilentAutoDeleteOriginals(enabled: Boolean) {
        prefs.edit().putBoolean(PrefKeys.SILENT_AUTO_DELETE, enabled).apply()
        _state.update { it.copy(silentAutoDeleteOriginals = enabled) }
    }

    fun setMorningReminderHour(hour: Int) {
        val clamped = hour.coerceIn(6, 11)
        prefs.edit().putInt(PrefKeys.MORNING_HOUR, clamped).apply()
        _state.update { it.copy(morningReminderHour = clamped) }
    }

    fun setCandidateSortMode(mode: CandidateSortMode) {
        prefs.edit().putString(PrefKeys.SORT_MODE, mode.rawValue).apply()
        _state.update { it.copy(candidateSortMode = mode) }
    }

    companion object {
        @Volatile
        private var instance: AppSettings? = null

        fun getInstance(context: Context): AppSettings =
            instance ?: synchronized(this) {
                instance ?: AppSettings(context).also { instance = it }
            }
    }
}
