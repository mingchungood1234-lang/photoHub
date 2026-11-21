package com.photohub.compressor.viewmodel

import android.app.Application
import android.content.IntentSender
import android.graphics.Bitmap
import android.text.format.Formatter
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.photohub.compressor.background.AssetUploadCoordinator
import com.photohub.compressor.background.BackgroundBackupManager
import com.photohub.compressor.background.UploadOwner
import com.photohub.compressor.data.*
import com.photohub.compressor.media.*
import com.photohub.compressor.network.ApiHttpException
import com.photohub.compressor.network.PhotoHubApiClient
import com.photohub.compressor.sync.LocalProxyStore
import com.photohub.compressor.sync.LocalProxySyncManager
import com.photohub.compressor.sync.LocalProxyTracker
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Semaphore
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

data class TrashPromptRequest(
    val intentSender: IntentSender,
    val targetIds: List<String>
)

data class CompressUiState(
    val candidates: List<PhotoCandidate> = emptyList(),
    val thumbnails: Map<String, Bitmap> = emptyMap(),
    val pendingDeleteIds: List<String> = emptyList(),
    val trashPromptRequest: TrashPromptRequest? = null,
    val isAwaitingDeleteConfirmation: Boolean = false,
    val deleteErrorAlertMessage: String? = null,
    val isScanning: Boolean = false,
    val isProcessing: Boolean = false,
    val accessLevel: MediaAccessLevel = MediaAccessLevel.DENIED,
    val statusBanner: String? = null,
    val totalSavedBytes: Long = 0L,
    val completedCount: Int = 0,
    val totalToProcess: Int = 0,
    val overallProgressFraction: Float = 0f,
    val sortMode: CandidateSortMode = CandidateSortMode.LARGEST_VIDEOS_FIRST,
    val recentlyDeletedNoticeCount: Int = 0,
    val recentlyDeletedNoticeBytes: Long = 0L,
    val backgroundActiveCount: Int = 0
) {
    val selectedCount: Int
        get() = candidates.count { it.isSelected && !it.state.isFinished }

    val pendingVideoCandidates: List<PhotoCandidate>
        get() = candidates.filter { it.isVideo && !it.state.isFinished }

    val pendingVideoEstimatedBytes: Long
        get() = pendingVideoCandidates.sumOf { it.estimatedBytes.coerceAtLeast(0L) }

    val totalEligibleEstimatedBytes: Long
        get() = candidates.filter { !it.state.isFinished }.sumOf { it.estimatedBytes.coerceAtLeast(0L) }
}

class CompressViewModel(application: Application) : AndroidViewModel(application) {
    private val context = application.applicationContext
    private val settings = AppSettings.getInstance(context)
    private val mediaService = MediaLibraryService(context)
    private val tracker = LocalProxyTracker.getInstance(context)
    private val bgManager = BackgroundBackupManager.getInstance(context)

    private val _uiState = MutableStateFlow(
        CompressUiState(
            accessLevel = mediaService.currentAccessLevel(),
            sortMode = settings.current.candidateSortMode,
            backgroundActiveCount = AssetUploadCoordinator.backgroundActiveAssetIds().size
        )
    )
    val uiState: StateFlow<CompressUiState> = _uiState.asStateFlow()

    private val itemProgress = ConcurrentHashMap<String, Double>()
    private var hasAutoStartedThisSession = false
    private var activeUploadJob: Job? = null

    init {
        viewModelScope.launch {
            AssetUploadCoordinator.changes.collect {
                syncBackgroundStateToCandidates()
            }
        }
        viewModelScope.launch {
            bgManager.openCleanupEvents.collect {
                handleNotificationOpenCleanup()
            }
        }
    }

    fun refreshPermissionsAndSync() {
        val level = mediaService.currentAccessLevel()
        _uiState.update { it.copy(accessLevel = level) }
        if (level != MediaAccessLevel.DENIED) {
            bgManager.ensureMediaObserverAndSchedule()
        }
        bgManager.pruneMissingAssetsFromStaged()
        syncBackgroundStateToCandidates()
    }

    fun setSortMode(newMode: CandidateSortMode) {
        settings.setCandidateSortMode(newMode)
        _uiState.update {
            it.copy(
                sortMode = newMode,
                candidates = PhotoBackupPipeline.sortCandidates(it.candidates, newMode)
            )
        }
    }

    fun scanLibrary() {
        if (_uiState.value.isScanning) return
        _uiState.update { it.copy(isScanning = true, statusBanner = null) }
        bgManager.pruneMissingAssetsFromStaged()

        val level = mediaService.currentAccessLevel()
        _uiState.update { it.copy(accessLevel = level) }
        if (level == MediaAccessLevel.DENIED) {
            _uiState.update {
                it.copy(
                    isScanning = false,
                    statusBanner = "Please allow Photos & Videos access in Android Settings to scan your library."
                )
            }
            return
        }
        bgManager.ensureMediaObserverAndSchedule()

        val mode = _uiState.value.sortMode
        val cur = settings.current
        viewModelScope.launch(Dispatchers.IO) {
            val cached = LocalProxyStore.getInstance(context)
                .cachedPhotos(cur.normalizedBaseUrl, cur.apiKeyCacheScope)
            val raw = mediaService.scanCandidates(tracker = tracker, knownServerPhotos = cached)
            val sorted = PhotoBackupPipeline.sortCandidates(raw, mode)
            withContext(Dispatchers.Main) {
                applyScannedCandidates(sorted)
                _uiState.update {
                    it.copy(
                        pendingDeleteIds = emptyList(),
                        isScanning = false,
                        statusBanner = if (sorted.isEmpty()) "No uncompressed photos or videos found." else it.statusBanner
                    )
                }
            }
        }
    }

    fun scanAndAutoCompressIfEnabled(forceNow: Boolean = false) {
        if (!forceNow) {
            if (hasAutoStartedThisSession || !settings.current.autoCompressOnOpen) return
            hasAutoStartedThisSession = true
        }
        if (_uiState.value.isScanning || _uiState.value.isProcessing) return
        _uiState.update { it.copy(isScanning = true, statusBanner = "Finding new photos & videos to back up…") }
        bgManager.pruneMissingAssetsFromStaged()

        val level = mediaService.currentAccessLevel()
        _uiState.update { it.copy(accessLevel = level) }
        if (level == MediaAccessLevel.DENIED) {
            _uiState.update {
                it.copy(
                    isScanning = false,
                    statusBanner = "Allow Photos & Videos access to auto-upload and free up space."
                )
            }
            return
        }
        bgManager.ensureMediaObserverAndSchedule()

        val mode = _uiState.value.sortMode
        val cur = settings.current
        viewModelScope.launch(Dispatchers.IO) {
            val cached = LocalProxyStore.getInstance(context)
                .cachedPhotos(cur.normalizedBaseUrl, cur.apiKeyCacheScope)
            val raw = mediaService.scanCandidates(
                tracker = tracker,
                knownServerPhotos = cached,
                maxResults = 200,
                maxInspect = 3000
            )
            val sorted = PhotoBackupPipeline.sortCandidates(raw, mode)
            withContext(Dispatchers.Main) {
                applyScannedCandidates(sorted)
                _uiState.update { it.copy(isScanning = false) }
                if (sorted.isNotEmpty() && (forceNow || settings.current.autoCompressOnOpen)) {
                    selectAllEligible(true)
                    startProcessingSelectedPhotos()
                } else if (sorted.isEmpty()) {
                    _uiState.update { it.copy(statusBanner = "All scanned photos & videos are already backed up.") }
                }
            }
        }
    }

    private fun applyScannedCandidates(scanned: List<PhotoCandidate>) {
        val stagedById = bgManager.state.value.stagedItems.associateBy { it.id }
        val bgIds = AssetUploadCoordinator.backgroundActiveAssetIds()
        val mapped = scanned.map { item ->
            val staged = stagedById[item.id]
            when {
                staged != null -> item.copy(
                    state = PhotoCompressionState.ReadyToDelete(staged.savedBytes),
                    isSelected = false
                )
                item.id in bgIds -> item.copy(
                    state = PhotoCompressionState.UploadingInBackground,
                    isSelected = false
                )
                else -> item
            }
        }
        _uiState.update {
            it.copy(
                candidates = mapped,
                backgroundActiveCount = bgIds.size
            )
        }
    }

    fun syncBackgroundStateToCandidates() {
        val bgIds = AssetUploadCoordinator.backgroundActiveAssetIds()
        val stagedById = bgManager.state.value.stagedItems.associateBy { it.id }
        _uiState.update { prev ->
            val updated = prev.candidates.map { item ->
                val staged = stagedById[item.id]
                when {
                    staged != null -> item.copy(
                        state = PhotoCompressionState.ReadyToDelete(staged.savedBytes),
                        isSelected = false
                    )
                    item.id in bgIds -> item.copy(
                        state = PhotoCompressionState.UploadingInBackground,
                        isSelected = false
                    )
                    item.state is PhotoCompressionState.UploadingInBackground -> item.copy(
                        state = PhotoCompressionState.Pending
                    )
                    else -> item
                }
            }
            prev.copy(
                candidates = updated,
                backgroundActiveCount = bgIds.size
            )
        }
    }

    fun loadThumbnailIfNeeded(candidate: PhotoCandidate) {
        if (_uiState.value.thumbnails.containsKey(candidate.id)) return
        viewModelScope.launch {
            val bmp = mediaService.loadThumbnail(candidate.contentUri)
            if (bmp != null) {
                _uiState.update {
                    if (it.thumbnails.containsKey(candidate.id)) it
                    else it.copy(thumbnails = it.thumbnails + (candidate.id to bmp))
                }
            }
        }
    }

    fun toggleSelection(id: String) {
        _uiState.update { prev ->
            val next = prev.candidates.map { item ->
                if (item.id == id && !item.state.isFinished) {
                    item.copy(isSelected = !item.isSelected)
                } else {
                    item
                }
            }
            prev.copy(candidates = next)
        }
    }

    fun selectAllEligible(selected: Boolean) {
        _uiState.update { prev ->
            val next = prev.candidates.map { item ->
                if (!item.state.isFinished) item.copy(isSelected = selected) else item
            }
            prev.copy(candidates = next)
        }
    }

    fun selectTopVideos(maxCount: Int = 25) {
        val eligibleVideos = PhotoBackupPipeline.sortCandidates(
            _uiState.value.candidates.filter { it.isVideo && !it.state.isFinished },
            CandidateSortMode.LARGEST_FIRST
        ).take(maxCount).map { it.id }.toSet()

        _uiState.update { prev ->
            val next = prev.candidates.map { item ->
                if (!item.state.isFinished) item.copy(isSelected = item.id in eligibleVideos) else item
            }
            prev.copy(candidates = next)
        }
    }

    fun dismissRecentlyDeletedNotice() {
        _uiState.update { it.copy(recentlyDeletedNoticeCount = 0, recentlyDeletedNoticeBytes = 0L) }
    }

    fun startProcessingSelectedPhotos() {
        if (_uiState.value.isProcessing) return
        val targetIds = _uiState.value.candidates
            .filter { it.isSelected && !it.state.isFinished }
            .map { it.id }
        if (targetIds.isEmpty()) return

        itemProgress.clear()
        _uiState.update {
            it.copy(
                isProcessing = true,
                completedCount = 0,
                totalToProcess = targetIds.size,
                overallProgressFraction = 0f,
                statusBanner = null
            )
        }

        val cur = settings.current
        val apiClient = PhotoHubApiClient(context, settings)

        activeUploadJob?.cancel()
        activeUploadJob = viewModelScope.launch {
            try {
                val info = apiClient.whoami()
                settings.updateServerStorage(info.storage)
            } catch (err: ApiHttpException) {
                if (err.statusCode == 401) {
                    _uiState.update {
                        it.copy(isProcessing = false, statusBanner = "Session expired. Please sign in again.")
                    }
                    LocalProxySyncManager.getInstance(context).cancel()
                    settings.signOut()
                    return@launch
                } else {
                    _uiState.update {
                        it.copy(isProcessing = false, statusBanner = "Server check failed: ${err.message}")
                    }
                    return@launch
                }
            } catch (err: Exception) {
                _uiState.update {
                    it.copy(isProcessing = false, statusBanner = "Server check failed: ${err.localizedMessage}")
                }
                return@launch
            }

            val queue = Channel<String>(Channel.UNLIMITED)
            targetIds.forEach { queue.trySend(it) }
            queue.close()

            val videoSem = Semaphore(1)
            val gallerySem = Semaphore(1)
            val failedCount = AtomicInteger(0)
            val totalCount = targetIds.size

            coroutineScope {
                val workerCount = minOf(3, targetIds.size)
                val workers = List(workerCount) {
                    launch(Dispatchers.Default) {
                        for (id in queue) {
                            if (!isActive) break
                            val ok = processSingleCandidate(
                                id = id,
                                apiClient = apiClient,
                                cur = cur,
                                videoSem = videoSem,
                                gallerySem = gallerySem,
                                totalCount = totalCount
                            )
                            if (!ok) failedCount.incrementAndGet()
                        }
                    }
                }
                workers.joinAll()
            }

            runCatching { apiClient.whoami() }.getOrNull()?.let { updated ->
                settings.updateServerStorage(updated.storage)
            }

            val failures = failedCount.get()
            val pendingIds = _uiState.value.pendingDeleteIds
            val saved = _uiState.value.totalSavedBytes
            val savedStr = Formatter.formatFileSize(context, saved.coerceAtLeast(0L))

            _uiState.update {
                it.copy(
                    isProcessing = false,
                    overallProgressFraction = if (failures == 0) 1f else it.overallProgressFraction
                )
            }

            if (pendingIds.isNotEmpty()) {
                val latestSettings = settings.current
                if (latestSettings.silentAutoDeleteOriginals && mediaService.canSilentlyDeleteOriginals()) {
                    val silentlyDeleted = mutableListOf<String>()
                    val remaining = mutableListOf<String>()
                    for (id in pendingIds) {
                        if (mediaService.trySilentDeleteOriginal(id)) {
                            silentlyDeleted.add(id)
                        } else {
                            remaining.add(id)
                        }
                    }
                    if (silentlyDeleted.isNotEmpty()) {
                        onTrashConfirmed(silentlyDeleted, silent = true)
                    }
                    if (remaining.isNotEmpty()) {
                        triggerTrashConfirmation(remaining)
                    }
                } else {
                    triggerTrashConfirmation(pendingIds)
                }
            } else if (failures > 0 && _uiState.value.statusBanner == null) {
                _uiState.update { it.copy(statusBanner = "Finished with $failures error(s). Space saved: $savedStr.") }
            } else if (failures == 0) {
                _uiState.update { it.copy(statusBanner = "Finished! All originals backed up & verified.") }
            }
        }
    }

    private suspend fun processSingleCandidate(
        id: String,
        apiClient: PhotoHubApiClient,
        cur: AppSettingsState,
        videoSem: Semaphore,
        gallerySem: Semaphore,
        totalCount: Int
    ): Boolean {
        val candidate = _uiState.value.candidates.firstOrNull { it.id == id }
        if (candidate == null) {
            recordDone(id, totalCount)
            return true
        }

        val stagedMatch = bgManager.state.value.stagedItems.firstOrNull { it.id == id }
        if (stagedMatch != null) {
            withContext(Dispatchers.Main) {
                stageOriginalForDeletion(id, stagedMatch.savedBytes)
            }
            recordDone(id, totalCount)
            return true
        }

        if (AssetUploadCoordinator.isClaimedByBackground(id) ||
            !AssetUploadCoordinator.tryClaimAsset(id, UploadOwner.MANUAL)
        ) {
            updateCandidateState(id, PhotoCompressionState.UploadingInBackground, clearSelect = true)
            recordDone(id, totalCount)
            return true
        }

        try {
            updateCandidateState(id, PhotoCompressionState.Hashing)
            val result = PhotoBackupPipeline.backupAndProxyAsset(
                context = context,
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
                onStageChange = { stage ->
                    updateCandidateState(id, stage)
                    recordItemProgress(id, stage.stageFraction, totalCount)
                }
            )

            withContext(Dispatchers.Main) {
                when (result) {
                    is BackupPipelineResult.BackedUp -> {
                        stageOriginalForDeletion(id, result.outcome.savedBytes)
                        bgManager.appendStagedItems(
                            listOf(
                                StagedCleanupItem(
                                    id = id,
                                    filename = result.outcome.filename,
                                    masterSha256 = result.outcome.masterSha256,
                                    savedBytes = result.outcome.savedBytes,
                                    verifiedAtMs = System.currentTimeMillis()
                                )
                            )
                        )
                    }
                    is BackupPipelineResult.SkippedExistingProxy -> {
                        updateCandidateState(id, PhotoCompressionState.AlreadyProxy, clearSelect = true)
                    }
                    is BackupPipelineResult.SkippedProtectedOriginal -> {
                        updateCandidateState(id, PhotoCompressionState.Skipped("Restored Original Protected"), clearSelect = true)
                    }
                    is BackupPipelineResult.SkippedInFlight -> {
                        val state = if (AssetUploadCoordinator.isClaimedByBackground(id)) {
                            PhotoCompressionState.UploadingInBackground
                        } else {
                            PhotoCompressionState.Skipped("Already Uploading")
                        }
                        updateCandidateState(id, state, clearSelect = true)
                    }
                }
            }
            recordDone(id, totalCount)
            return true
        } catch (err: Exception) {
            val msg = err.localizedMessage ?: "Upload failed"
            updateCandidateState(id, PhotoCompressionState.Failed(msg))
            _uiState.update { it.copy(statusBanner = msg) }
            recordDone(id, totalCount)
            return false
        } finally {
            AssetUploadCoordinator.releaseAsset(id, UploadOwner.MANUAL)
        }
    }

    private fun stageOriginalForDeletion(id: String, savedBytes: Long) {
        _uiState.update { prev ->
            val updatedCandidates = prev.candidates.map {
                if (it.id == id) {
                    it.copy(state = PhotoCompressionState.ReadyToDelete(savedBytes), isSelected = false)
                } else {
                    it
                }
            }
            val nextPending = if (id in prev.pendingDeleteIds) prev.pendingDeleteIds else prev.pendingDeleteIds + id
            prev.copy(
                candidates = updatedCandidates,
                pendingDeleteIds = nextPending,
                totalSavedBytes = prev.totalSavedBytes + savedBytes
            )
        }
    }

    private fun updateCandidateState(id: String, state: PhotoCompressionState, clearSelect: Boolean = false) {
        _uiState.update { prev ->
            val updated = prev.candidates.map {
                if (it.id == id) {
                    it.copy(
                        state = state,
                        isSelected = if (clearSelect) false else it.isSelected
                    )
                } else {
                    it
                }
            }
            prev.copy(candidates = updated)
        }
    }

    private fun recordItemProgress(id: String, fraction: Double, totalCount: Int) {
        itemProgress.merge(id, fraction.coerceIn(0.0, 1.0)) { a, b -> maxOf(a, b) }
        val overall = (itemProgress.values.sum() / totalCount.coerceAtLeast(1).toDouble()).toFloat().coerceIn(0f, 1f)
        _uiState.update { it.copy(overallProgressFraction = overall) }
    }

    private fun recordDone(id: String, totalCount: Int) {
        recordItemProgress(id, 1.0, totalCount)
        _uiState.update { it.copy(completedCount = it.completedCount + 1) }
    }

    fun triggerStagedOvernightCleanupPrompt() {
        val staged = bgManager.state.value.stagedItems
        if (staged.isEmpty()) return
        val liveIds = mediaService.fetchLiveAssetIds(staged.map { it.id }).map { it.toString() }
        if (liveIds.isEmpty()) {
            bgManager.clearAllStagedItems()
            return
        }
        val savedTotal = if (_uiState.value.totalSavedBytes == 0L) bgManager.state.value.stagedSavedBytes else _uiState.value.totalSavedBytes
        _uiState.update {
            it.copy(
                pendingDeleteIds = liveIds,
                totalSavedBytes = savedTotal
            )
        }
        triggerTrashConfirmation(liveIds)
    }

    fun handleNotificationOpenCleanup() {
        bgManager.consumeOpenCleanupFlag()
        if (_uiState.value.isProcessing) return
        val pending = _uiState.value.pendingDeleteIds
        if (pending.isNotEmpty()) {
            triggerTrashConfirmation(pending)
        } else if (bgManager.state.value.stagedItems.isNotEmpty()) {
            triggerStagedOvernightCleanupPrompt()
        }
    }

    fun triggerTrashConfirmation(targetIds: List<String>) {
        if (targetIds.isEmpty() || _uiState.value.isAwaitingDeleteConfirmation) return
        val savedStr = Formatter.formatFileSize(context, _uiState.value.totalSavedBytes.coerceAtLeast(0L))
        _uiState.update {
            it.copy(
                isAwaitingDeleteConfirmation = true,
                statusBanner = "Backed up & SHA-256 verified! Confirm Android Trash popup to remove ${targetIds.size} original photo(s) (~$savedStr)."
            )
        }

        try {
            when (val res = mediaService.prepareTrashOrDeleteOriginals(targetIds)) {
                is TrashOrDeleteRequestResult.DeletedImmediately -> {
                    onTrashConfirmed(res.deletedIds)
                }
                is TrashOrDeleteRequestResult.NeedsSystemConfirmation -> {
                    _uiState.update {
                        it.copy(
                            trashPromptRequest = TrashPromptRequest(
                                intentSender = res.intentSender,
                                targetIds = res.targetIds
                            )
                        )
                    }
                }
            }
        } catch (err: Exception) {
            _uiState.update {
                it.copy(
                    isAwaitingDeleteConfirmation = false,
                    deleteErrorAlertMessage = err.localizedMessage ?: "Failed to trigger Trash confirmation."
                )
            }
        }
    }

    fun clearTrashPromptRequest() {
        _uiState.update { it.copy(trashPromptRequest = null) }
    }

    fun onTrashConfirmed(targetIds: List<String>, silent: Boolean = false) {
        val deletedSet = targetIds.toSet()
        val stagedSaved = bgManager.state.value.stagedItems
            .filter { it.id in deletedSet }
            .sumOf { it.savedBytes.coerceAtLeast(0L) }
        val freed = if (_uiState.value.totalSavedBytes > 0L) _uiState.value.totalSavedBytes else stagedSaved

        bgManager.removeStagedItems(deletedSet)
        val freedStr = Formatter.formatFileSize(context, freed.coerceAtLeast(0L))

        _uiState.update { prev ->
            val remainingPending = prev.pendingDeleteIds.filterNot { it in deletedSet }
            prev.copy(
                isAwaitingDeleteConfirmation = false,
                trashPromptRequest = null,
                candidates = prev.candidates.filterNot { it.id in deletedSet },
                pendingDeleteIds = remainingPending,
                recentlyDeletedNoticeCount = if (silent) prev.recentlyDeletedNoticeCount else prev.recentlyDeletedNoticeCount + deletedSet.size,
                recentlyDeletedNoticeBytes = if (silent) prev.recentlyDeletedNoticeBytes else prev.recentlyDeletedNoticeBytes + freed.coerceAtLeast(0L),
                statusBanner = when {
                    silent && remainingPending.isEmpty() ->
                        "Verified & silently freed $freedStr across ${deletedSet.size} original(s)."
                    silent ->
                        "Silently deleted ${deletedSet.size} original(s). ${remainingPending.size} remain."
                    remainingPending.isEmpty() ->
                        "Verified & moved ${deletedSet.size} original(s) ($freedStr) to Trash (30 days)."
                    else ->
                        "Moved ${deletedSet.size} original(s) to Trash. ${remainingPending.size} remain."
                }
            )
        }
    }

    fun onTrashCancelled(targetIds: List<String>) {
        val targetSet = targetIds.toSet()
        bgManager.removeStagedItems(targetSet)
        _uiState.update { prev ->
            prev.copy(
                isAwaitingDeleteConfirmation = false,
                trashPromptRequest = null,
                pendingDeleteIds = prev.pendingDeleteIds.filterNot { it in targetSet },
                candidates = prev.candidates.map {
                    if (it.id in targetSet) {
                        it.copy(
                            state = PhotoCompressionState.Skipped("Backed up (SHA-256) · Kept on phone"),
                            isSelected = false
                        )
                    } else {
                        it
                    }
                },
                statusBanner = "Originals kept on phone (safely backed up on server)."
            )
        }
    }

    fun dismissPendingDeleteAfterError() {
        val pendingSet = _uiState.value.pendingDeleteIds.toSet()
        bgManager.removeStagedItems(pendingSet)
        _uiState.update { prev ->
            prev.copy(
                isAwaitingDeleteConfirmation = false,
                pendingDeleteIds = emptyList(),
                deleteErrorAlertMessage = null,
                candidates = prev.candidates.map {
                    if (it.id in pendingSet) {
                        it.copy(
                            state = PhotoCompressionState.Skipped("Backed up (SHA-256) · Original kept"),
                            isSelected = false
                        )
                    } else {
                        it
                    }
                }
            )
        }
    }

    fun clearDeleteError() {
        _uiState.update { it.copy(deleteErrorAlertMessage = null) }
    }
}
