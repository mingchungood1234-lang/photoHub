package com.photohub.compressor.background

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.text.format.Formatter
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.*
import com.photohub.compressor.MainActivity
import com.photohub.compressor.R
import com.photohub.compressor.data.AppSettings
import com.photohub.compressor.data.AppSettingsState
import com.photohub.compressor.data.CandidateSortMode
import com.photohub.compressor.data.StagedCleanupItem
import com.photohub.compressor.media.BackupPipelineOutcome
import com.photohub.compressor.media.BackupPipelineResult
import com.photohub.compressor.media.MediaAccessLevel
import com.photohub.compressor.media.MediaLibraryService
import com.photohub.compressor.media.PhotoBackupPipeline
import com.photohub.compressor.network.ApiHttpException
import com.photohub.compressor.network.PhotoHubApiClient
import com.photohub.compressor.sync.LocalProxyStore
import com.photohub.compressor.sync.LocalProxySyncManager
import com.photohub.compressor.sync.LocalProxyTracker
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Semaphore
import org.json.JSONArray
import java.util.concurrent.TimeUnit

data class BackgroundBackupUiState(
    val stagedItems: List<StagedCleanupItem> = emptyList(),
    val lastRunSummary: String = "",
    val notificationPermissionLabel: String = "Off",
    val pendingOpenCleanupFromNotification: Boolean = false,
    val activeBackgroundCount: Int = 0
) {
    val stagedSavedBytes: Long
        get() = stagedItems.sumOf { it.savedBytes.coerceAtLeast(0L) }
}

class BackgroundBackupManager private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val settings = AppSettings.getInstance(appContext)
    private val prefs = appContext.getSharedPreferences("photohub_bg_backup_state", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _state = MutableStateFlow(loadInitialState())
    val state: StateFlow<BackgroundBackupUiState> = _state.asStateFlow()

    private val _openCleanupEvents = MutableSharedFlow<Unit>(extraBufferCapacity = 8)
    val openCleanupEvents: SharedFlow<Unit> = _openCleanupEvents.asSharedFlow()

    private var hasRegisteredObserver = false
    private var isSilentRunning = false
    private var pendingRescan = false
    private var debouncedJob: Job? = null
    private val cooldownUntilMs = mutableMapOf<String, Long>()
    private val mediaObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) {
            scheduleDebouncedSilentCheck(2500L)
        }
    }

    init {
        ensureNotificationChannel()
        refreshNotificationPermissionLabel()
        scope.launch {
            LocalProxySyncManager.getInstance(appContext).serverSyncCompleted.collect {
                scheduleDebouncedSilentCheck(1500L)
            }
        }
        scope.launch {
            AssetUploadCoordinator.changes.collect {
                val active = AssetUploadCoordinator.backgroundActiveAssetIds().size
                if (_state.value.activeBackgroundCount != active) {
                    _state.value = _state.value.copy(activeBackgroundCount = active)
                }
            }
        }
    }

    private fun loadInitialState(): BackgroundBackupUiState {
        val summary = prefs.getString(KEY_LAST_SUMMARY, "").orEmpty()
        val stagedRaw = prefs.getString(KEY_STAGED_ITEMS, null)
        val staged = if (stagedRaw != null) {
            runCatching {
                val arr = JSONArray(stagedRaw)
                List(arr.length()) { idx -> StagedCleanupItem.fromJson(arr.getJSONObject(idx)) }
            }.getOrDefault(emptyList())
        } else {
            emptyList()
        }
        return BackgroundBackupUiState(
            stagedItems = staged,
            lastRunSummary = summary,
            notificationPermissionLabel = currentNotificationLabel()
        )
    }

    private fun saveStaged(items: List<StagedCleanupItem>) {
        val arr = JSONArray()
        items.forEach { arr.put(it.toJson()) }
        prefs.edit().putString(KEY_STAGED_ITEMS, arr.toString()).apply()
    }

    fun updateSummary(message: String) {
        prefs.edit().putString(KEY_LAST_SUMMARY, message).apply()
        _state.value = _state.value.copy(lastRunSummary = message)
    }

    fun markOpenCleanupFromNotification() {
        _state.value = _state.value.copy(pendingOpenCleanupFromNotification = true)
        _openCleanupEvents.tryEmit(Unit)
    }

    fun consumeOpenCleanupFlag() {
        _state.value = _state.value.copy(pendingOpenCleanupFromNotification = false)
    }

    fun currentNotificationLabel(): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                appContext,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            return if (granted) "Allowed" else "Denied (Enable in Android Settings)"
        }
        return if (NotificationManagerCompat.from(appContext).areNotificationsEnabled()) {
            "Allowed"
        } else {
            "Denied (Enable in Android Settings)"
        }
    }

    fun refreshNotificationPermissionLabel() {
        _state.value = _state.value.copy(notificationPermissionLabel = currentNotificationLabel())
    }

    fun ensureMediaObserverAndSchedule() {
        val mediaService = MediaLibraryService(appContext)
        if (!hasRegisteredObserver && mediaService.currentAccessLevel() != MediaAccessLevel.DENIED) {
            hasRegisteredObserver = true
            appContext.contentResolver.registerContentObserver(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                true,
                mediaObserver
            )
            appContext.contentResolver.registerContentObserver(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                true,
                mediaObserver
            )
        }
        scheduleBackgroundWorkersIfEnabled()
    }

    fun scheduleBackgroundWorkersIfEnabled() {
        val cur = settings.current
        val workManager = WorkManager.getInstance(appContext)
        if (!cur.nightlyAutoBackupEnabled || !cur.isSignedIn) {
            workManager.cancelUniqueWork(UNIQUE_PERIODIC_WORK)
            workManager.cancelUniqueWork(UNIQUE_CONTENT_TRIGGER_WORK)
            return
        }

        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.UNMETERED)
            .setRequiresCharging(cur.nightlyRequiresCharging)
            .setRequiresBatteryNotLow(true)
            .build()

        val periodic = PeriodicWorkRequestBuilder<PhotoUploadWorker>(6, TimeUnit.HOURS)
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .setInputData(workDataOf(PhotoUploadWorker.KEY_IS_OVERNIGHT to true))
            .build()

        workManager.enqueueUniquePeriodicWork(
            UNIQUE_PERIODIC_WORK,
            ExistingPeriodicWorkPolicy.UPDATE,
            periodic
        )
        scheduleMediaContentTriggerIfEnabled(replaceExisting = false)
        if (_state.value.lastRunSummary.isEmpty()) {
            updateSummary("Auto backup active")
        }
    }

    /**
     * Enqueues a short-delay continuation worker when a background batch hits its per-run cap,
     * so large camera shoots finish backing up seamlessly without reopening the app.
     */
    fun scheduleBatchContinuationIfEnabled(isOvernight: Boolean) {
        val cur = settings.current
        if (!cur.nightlyAutoBackupEnabled || !cur.isSignedIn) return
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(if (isOvernight) NetworkType.UNMETERED else NetworkType.CONNECTED)
            .setRequiresBatteryNotLow(true)
            .build()
        val continuation = OneTimeWorkRequestBuilder<PhotoUploadWorker>()
            .setConstraints(constraints)
            .setInitialDelay(5, TimeUnit.SECONDS)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .setInputData(workDataOf(PhotoUploadWorker.KEY_IS_OVERNIGHT to isOvernight))
            .build()
        WorkManager.getInstance(appContext).enqueueUniqueWork(
            UNIQUE_CONTINUATION_BG_WORK,
            ExistingWorkPolicy.REPLACE,
            continuation
        )
    }

    /**
     * Registers a persistent WorkManager MediaStore content trigger so Android wakes PhotoUploadWorker
     * in the background whenever new camera photos/videos appear—even if the app is closed.
     */
    fun scheduleMediaContentTriggerIfEnabled(replaceExisting: Boolean = false) {
        val cur = settings.current
        val workManager = WorkManager.getInstance(appContext)
        if (!cur.nightlyAutoBackupEnabled || !cur.isSignedIn) {
            workManager.cancelUniqueWork(UNIQUE_CONTENT_TRIGGER_WORK)
            return
        }
        val mediaService = MediaLibraryService(appContext)
        if (mediaService.currentAccessLevel() == MediaAccessLevel.DENIED) return

        val triggerConstraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .addContentUriTrigger(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true)
            .addContentUriTrigger(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true)
            .setTriggerContentUpdateDelay(3, TimeUnit.SECONDS)
            .setTriggerContentMaxDelay(20, TimeUnit.SECONDS)
            .build()

        val triggerWork = OneTimeWorkRequestBuilder<PhotoUploadWorker>()
            .setConstraints(triggerConstraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .setInputData(workDataOf(PhotoUploadWorker.KEY_IS_OVERNIGHT to false))
            .build()

        workManager.enqueueUniqueWork(
            UNIQUE_CONTENT_TRIGGER_WORK,
            if (replaceExisting) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP,
            triggerWork
        )
    }

    fun scheduleDebouncedSilentCheck(delayMs: Long = 2500L) {
        val cur = settings.current
        if (!cur.nightlyAutoBackupEnabled || !cur.isSignedIn) return
        debouncedJob?.cancel()
        debouncedJob = scope.launch {
            delay(delayMs)
            triggerSilentAutoUpload(isMovingToBackground = false)
        }
    }

    fun triggerSilentAutoUpload(isMovingToBackground: Boolean) {
        ensureMediaObserverAndSchedule()
        val cur = settings.current
        if (!cur.nightlyAutoBackupEnabled || !cur.isSignedIn || cur.normalizedBaseUrl == null) return

        val mediaService = MediaLibraryService(appContext)
        if (mediaService.currentAccessLevel() == MediaAccessLevel.DENIED) return

        if (isSilentRunning) {
            pendingRescan = true
            return
        }

        // If moving to background, enqueue a silent WorkManager task so OS finishes uploads even if killed
        if (isMovingToBackground) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()
            val oneTime = OneTimeWorkRequestBuilder<PhotoUploadWorker>()
                .setConstraints(constraints)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .setInputData(workDataOf(PhotoUploadWorker.KEY_IS_OVERNIGHT to false))
                .build()
            WorkManager.getInstance(appContext).enqueueUniqueWork(
                UNIQUE_IMMEDIATE_BG_WORK,
                ExistingWorkPolicy.KEEP,
                oneTime
            )
            return
        }

        isSilentRunning = true
        scope.launch {
            var hasMoreEligible = false
            val failedIds = mutableListOf<String>()
            try {
                val apiClient = PhotoHubApiClient(appContext, settings)
                val whoamiOk = runCatching { apiClient.whoami() }.isSuccess
                if (!whoamiOk) return@launch

                val tracker = LocalProxyTracker.getInstance(appContext)
                val cached = LocalProxyStore.getInstance(appContext)
                    .cachedPhotos(cur.normalizedBaseUrl, cur.apiKeyCacheScope)
                val raw = mediaService.scanCandidates(
                    tracker = tracker,
                    knownServerPhotos = cached,
                    maxResults = 30,
                    maxInspect = 400
                )

                val now = System.currentTimeMillis()
                val stagedIds = _state.value.stagedItems.map { it.id }.toSet()
                val activeIds = AssetUploadCoordinator.activeAssetIds()
                val eligible = PhotoBackupPipeline
                    .sortCandidates(raw, CandidateSortMode.LARGEST_VIDEOS_FIRST)
                    .filter { cand ->
                        cand.id !in stagedIds &&
                            cand.id !in activeIds &&
                            (cooldownUntilMs[cand.id] ?: 0L) <= now
                    }

                hasMoreEligible = eligible.size > 12
                val batch = eligible.take(12)
                val videoSem = Semaphore(1)
                val gallerySem = Semaphore(1)
                val newStaged = mutableListOf<StagedCleanupItem>()
                var silentDeletedCount = 0
                var silentDeletedBytes = 0L

                for (candidate in batch) {
                    if (!isActive) break
                    if (!AssetUploadCoordinator.tryClaimAsset(candidate.id, UploadOwner.BACKGROUND)) {
                        continue
                    }
                    try {
                        val res = PhotoBackupPipeline.backupAndProxyAsset(
                            context = appContext,
                            candidate = candidate,
                            mediaService = mediaService,
                            apiClient = apiClient,
                            tracker = tracker,
                            format = cur.proxyFormat,
                            maxPixelSize = cur.proxyMaxPixelSize,
                            quality = cur.proxyQuality,
                            uploadMode = cur.uploadMode,
                            keepLocalProxy = cur.keepLocalProxyInPhotos,
                            normalizedBaseUrl = cur.normalizedBaseUrl,
                            cacheScopeKey = cur.apiKeyCacheScope,
                            videoSemaphore = videoSem,
                            gallerySaveSemaphore = gallerySem,
                            onStageChange = {}
                        )
                        if (res is BackupPipelineResult.BackedUp) {
                            val deletedSilently = tryHandleBackedUpSilentDelete(
                                candidateId = candidate.id,
                                outcome = res.outcome,
                                settingsState = cur,
                                mediaService = mediaService,
                                tracker = tracker
                            )
                            if (deletedSilently) {
                                silentDeletedCount++
                                silentDeletedBytes += res.outcome.savedBytes.coerceAtLeast(0L)
                            } else {
                                newStaged.add(
                                    StagedCleanupItem(
                                        id = candidate.id,
                                        filename = res.outcome.filename,
                                        masterSha256 = res.outcome.masterSha256,
                                        savedBytes = res.outcome.savedBytes,
                                        verifiedAtMs = System.currentTimeMillis()
                                    )
                                )
                            }
                        }
                    } catch (err: ApiHttpException) {
                        if (err.statusCode == 507) break
                        failedIds.add(candidate.id)
                    } catch (_: Exception) {
                        failedIds.add(candidate.id)
                    } finally {
                        AssetUploadCoordinator.releaseAsset(candidate.id, UploadOwner.BACKGROUND)
                    }
                }

                if (newStaged.isNotEmpty()) {
                    appendStagedItems(newStaged)
                }
                pruneMissingAssetsFromStaged()
                silentlyCleanStagedItemsIfAllowed()

                val stagedCount = _state.value.stagedItems.size
                val stagedBytes = _state.value.stagedSavedBytes
                val totalStr = Formatter.formatFileSize(appContext, stagedBytes)
                if (stagedCount > 0 && newStaged.isNotEmpty()) {
                    updateSummary("Silently backed up ${newStaged.size} item(s); $stagedCount original(s) ready to delete (~$totalStr).")
                    if (cur.notifyWhenBackgroundUploadFinishes) {
                        sendDeleteOriginalsNotification(
                            count = stagedCount,
                            savedBytes = stagedBytes,
                            immediate = true,
                            morningHour = cur.morningReminderHour
                        )
                    }
                } else if (silentDeletedCount > 0) {
                    val freedStr = Formatter.formatFileSize(appContext, silentDeletedBytes)
                    updateSummary("Silently uploaded, verified & deleted $silentDeletedCount original(s) (freed ~$freedStr).")
                }
            } finally {
                val retryAt = System.currentTimeMillis() + 180_000L
                for (id in failedIds) cooldownUntilMs[id] = retryAt
                isSilentRunning = false
                val shouldContinue = pendingRescan || hasMoreEligible
                pendingRescan = false
                if (shouldContinue) {
                    scheduleDebouncedSilentCheck(1000L)
                }
            }
        }
    }

    fun appendStagedItems(newItems: List<StagedCleanupItem>) {
        if (newItems.isEmpty()) return
        val current = _state.value.stagedItems.toMutableList()
        var changed = false
        for (item in newItems) {
            if (current.none { it.id == item.id }) {
                current.add(item)
                changed = true
            }
        }
        if (changed) {
            saveStaged(current)
            _state.value = _state.value.copy(stagedItems = current)
        }
    }

    fun pruneMissingAssetsFromStaged() {
        val current = _state.value.stagedItems
        if (current.isEmpty()) return
        val liveIds = MediaLibraryService(appContext).fetchLiveAssetIds(current.map { it.id })
            .map { it.toString() }
            .toSet()
        val filtered = current.filter { it.id in liveIds }
        if (filtered.size != current.size) {
            saveStaged(filtered)
            _state.value = _state.value.copy(stagedItems = filtered)
            if (filtered.isEmpty()) {
                NotificationManagerCompat.from(appContext).cancel(NOTIFICATION_ID_DELETE_READY)
            }
        }
    }

    fun removeStagedItems(ids: Set<String>) {
        if (ids.isEmpty()) return
        val current = _state.value.stagedItems
        val filtered = current.filterNot { it.id in ids }
        if (filtered.size != current.size) {
            saveStaged(filtered)
            _state.value = _state.value.copy(stagedItems = filtered)
        }
        if (filtered.isEmpty()) {
            NotificationManagerCompat.from(appContext).cancel(NOTIFICATION_ID_DELETE_READY)
        }
    }

    fun clearAllStagedItems() {
        saveStaged(emptyList())
        _state.value = _state.value.copy(stagedItems = emptyList())
        NotificationManagerCompat.from(appContext).cancel(NOTIFICATION_ID_DELETE_READY)
    }

    /**
     * Silently deletes a verified original right after backup+proxy creation if user opted in
     * and granted All Files Access (`MANAGE_EXTERNAL_STORAGE`). Never runs on restored-protected items.
     */
    suspend fun tryHandleBackedUpSilentDelete(
        candidateId: String,
        outcome: BackupPipelineOutcome,
        settingsState: AppSettingsState = settings.current,
        mediaService: MediaLibraryService = MediaLibraryService(appContext),
        tracker: LocalProxyTracker = LocalProxyTracker.getInstance(appContext)
    ): Boolean {
        if (!settingsState.silentAutoDeleteOriginals || !mediaService.canSilentlyDeleteOriginals()) {
            return false
        }
        if (tracker.isRestoredMasterHash(outcome.masterSha256) || tracker.isRestoredOriginal(candidateId)) {
            return false
        }
        if (settingsState.keepLocalProxyInPhotos && tracker.liveProxyAssetId(outcome.masterSha256) == null) {
            return false
        }
        return mediaService.trySilentDeleteOriginal(candidateId)
    }

    suspend fun silentlyCleanStagedItemsIfAllowed(): Int {
        val cur = settings.current
        val mediaService = MediaLibraryService(appContext)
        if (!cur.silentAutoDeleteOriginals || !mediaService.canSilentlyDeleteOriginals()) {
            return 0
        }
        val current = _state.value.stagedItems
        if (current.isEmpty()) return 0

        val tracker = LocalProxyTracker.getInstance(appContext)
        val deletedIds = mutableSetOf<String>()
        var freedBytes = 0L

        for (item in current) {
            if (tracker.isRestoredMasterHash(item.masterSha256) || tracker.isRestoredOriginal(item.id)) {
                continue
            }
            if (cur.keepLocalProxyInPhotos && tracker.liveProxyAssetId(item.masterSha256) == null) {
                continue
            }
            if (mediaService.trySilentDeleteOriginal(item.id)) {
                deletedIds.add(item.id)
                freedBytes += item.savedBytes.coerceAtLeast(0L)
            }
        }

        if (deletedIds.isNotEmpty()) {
            removeStagedItems(deletedIds)
            val freedStr = Formatter.formatFileSize(appContext, freedBytes)
            updateSummary("Silently deleted ${deletedIds.size} backed-up original(s) (freed ~$freedStr).")
        }
        return deletedIds.size
    }

    fun silentlyCleanStagedItemsIfAllowedAsync() {
        val cur = settings.current
        if (!cur.silentAutoDeleteOriginals || !MediaLibraryService(appContext).canSilentlyDeleteOriginals()) {
            return
        }
        scope.launch {
            silentlyCleanStagedItemsIfAllowed()
        }
    }

    fun sendTestMorningAlert() {
        scope.launch {
            delay(5000L)
            val curState = _state.value
            val count = curState.stagedItems.size
            val bytes = curState.stagedSavedBytes
            val title = if (count > 0) {
                "Delete $count Backed-Up Original Photo${if (count == 1) "" else "s"}?"
            } else {
                "Delete Backed-Up Original Photos?"
            }
            val body = if (count > 0) {
                val sizeStr = Formatter.formatFileSize(appContext, bytes)
                "photoHub uploaded & verified $count item${if (count == 1) "" else "s"} silently in the background. Tap to delete the original photos from your phone (free ~$sizeStr)."
            } else {
                "Your originals are backed up & SHA-256 verified on your server. Tap to confirm deleting original photos from your phone."
            }
            postDeleteNotification(title, body, NOTIFICATION_ID_TEST)
        }
    }

    fun sendDeleteOriginalsNotification(
        count: Int,
        savedBytes: Long,
        immediate: Boolean,
        morningHour: Int
    ) {
        if (count <= 0) return
        val sizeStr = Formatter.formatFileSize(appContext, savedBytes.coerceAtLeast(0L))
        val title = "Delete $count Original Photo${if (count == 1) "" else "s"} to Free ~$sizeStr"
        val body = "$count original${if (count == 1) " is" else "s are"} uploaded & SHA-256 verified on your server. Tap to move the original files to Trash."
        postDeleteNotification(title, body, NOTIFICATION_ID_DELETE_READY)
    }

    private fun postDeleteNotification(title: String, body: String, notificationId: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(appContext, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensureNotificationChannel()

        val intent = Intent(appContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(MainActivity.EXTRA_OPEN_CLEANUP, true)
        }
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pendingIntent = PendingIntent.getActivity(appContext, notificationId, intent, piFlags)

        val notification = NotificationCompat.Builder(appContext, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        NotificationManagerCompat.from(appContext).notify(notificationId, notification)
    }

    private fun ensureNotificationChannel() {
        val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Delete Originals Ready Alerts",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Notifies once backed-up photos & videos are SHA-256 verified and ready to remove from phone."
        }
        nm.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "photohub_delete_ready"
        private const val NOTIFICATION_ID_DELETE_READY = 4101
        private const val NOTIFICATION_ID_TEST = 4102
        private const val UNIQUE_PERIODIC_WORK = "photohub_periodic_backup"
        private const val UNIQUE_CONTENT_TRIGGER_WORK = "photohub_content_trigger_backup"
        private const val UNIQUE_IMMEDIATE_BG_WORK = "photohub_immediate_bg_backup"
        private const val UNIQUE_CONTINUATION_BG_WORK = "photohub_continuation_bg_backup"
        private const val KEY_STAGED_ITEMS = "staged_cleanup_items_v1"
        private const val KEY_LAST_SUMMARY = "last_run_summary_v1"

        @Volatile
        private var instance: BackgroundBackupManager? = null

        fun getInstance(context: Context): BackgroundBackupManager =
            instance ?: synchronized(this) {
                instance ?: BackgroundBackupManager(context).also { instance = it }
            }
    }
}
