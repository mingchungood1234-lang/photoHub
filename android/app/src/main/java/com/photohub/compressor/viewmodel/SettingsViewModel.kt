package com.photohub.compressor.viewmodel

import android.app.Application
import android.content.IntentSender
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.photohub.compressor.auth.GoogleAuthManager
import com.photohub.compressor.background.BackgroundBackupManager
import com.photohub.compressor.data.*
import com.photohub.compressor.media.MediaLibraryService
import com.photohub.compressor.media.TrashOrDeleteRequestResult
import com.photohub.compressor.network.PhotoHubApiClient
import com.photohub.compressor.sync.LocalProxyStore
import com.photohub.compressor.sync.LocalProxySyncManager
import com.photohub.compressor.sync.LocalProxyTracker
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale

data class SettingsUiState(
    val isTestingConnection: Boolean = false,
    val connectionStatus: String? = null,
    val isTestingDelete: Boolean = false,
    val deleteDiagResult: String? = null,
    val pendingTestTrashIntentSender: IntentSender? = null,
    val localProxyCacheBytes: Long = 0L,
    val mediaPermissionLabel: String = "Denied",
    val hasAllFilesAccess: Boolean = false,
    val canSilentlyDeleteOriginals: Boolean = false,
    val isLoadingRestoreSummary: Boolean = false,
    val hasLoadedRestoreSummary: Boolean = false,
    val restoreLibraryTotalCount: Int = 0,
    val restoreLibraryUnrestoredCount: Int = 0,
    val restoreLibraryUnrestoredBytes: Long = 0L,
    val deviceAvailableBytes: Long? = DeviceStorageHelper.availableBytes(),
    val isBatchRestoringOriginals: Boolean = false,
    val restoreOriginalsCompleted: Int = 0,
    val restoreOriginalsTotal: Int = 0,
    val restoreOriginalsCurrentName: String = "",
    val restoreOriginalsMessage: String? = null,
    val restoreOriginalsConfirmRequest: BatchRestoreConfirmRequest? = null,
    val pendingProxyDeleteIntentSender: IntentSender? = null,
    val pendingProxyDeleteTargetIds: List<String> = emptyList(),
    val pendingProxyDeleteRemainingIds: List<String> = emptyList(),
    val pendingProxyDeleteBaseRestoredCount: Int = 0,
    val pendingProxyDeleteBaseFailedCount: Int = 0,
    val pendingProxyDeleteAlreadyDeletedCount: Int = 0,
    val pendingProxyDeleteFromRestoreRun: Boolean = false
)

class SettingsViewModel(application: Application) : AndroidViewModel(application) {
    private val context = application.applicationContext
    val settings = AppSettings.getInstance(context)
    val bgManager = BackgroundBackupManager.getInstance(context)
    val syncManager = LocalProxySyncManager.getInstance(context)
    private val authManager = GoogleAuthManager.getInstance(context)
    private val store = LocalProxyStore.getInstance(context)
    private val tracker = LocalProxyTracker.getInstance(context)
    private val mediaService = MediaLibraryService(context)
    private var cachedServerPhotos: List<ServerPhoto> = emptyList()
    private var restoreOriginalsJob: Job? = null

    private val _uiState = MutableStateFlow(
        SettingsUiState(
            localProxyCacheBytes = store.totalStorageBytes(),
            mediaPermissionLabel = mediaService.permissionLabel(),
            hasAllFilesAccess = mediaService.hasAllFilesAccess(),
            canSilentlyDeleteOriginals = mediaService.canSilentlyDeleteOriginals()
        )
    )
    val uiState: StateFlow<SettingsUiState> = _uiState.asStateFlow()

    init {
        refreshCachedRestoreSummary()
        viewModelScope.launch {
            store.changes.collect {
                _uiState.update { it.copy(localProxyCacheBytes = store.totalStorageBytes()) }
                refreshCachedRestoreSummary()
            }
        }
    }

    fun onAppear() {
        bgManager.refreshNotificationPermissionLabel()
        val hasAllFiles = mediaService.hasAllFilesAccess()
        val canSilentDelete = mediaService.canSilentlyDeleteOriginals()
        _uiState.update {
            it.copy(
                localProxyCacheBytes = store.totalStorageBytes(),
                mediaPermissionLabel = mediaService.permissionLabel(),
                hasAllFilesAccess = hasAllFiles,
                canSilentlyDeleteOriginals = canSilentDelete,
                deviceAvailableBytes = DeviceStorageHelper.availableBytes()
            )
        }
        if (canSilentDelete && settings.current.silentAutoDeleteOriginals) {
            bgManager.silentlyCleanStagedItemsIfAllowedAsync()
        }
        bgManager.ensureMediaObserverAndSchedule()
    }

    fun setSilentAutoDeleteOriginals(enabled: Boolean) {
        settings.setSilentAutoDeleteOriginals(enabled)
        _uiState.update {
            it.copy(
                hasAllFilesAccess = mediaService.hasAllFilesAccess(),
                canSilentlyDeleteOriginals = mediaService.canSilentlyDeleteOriginals()
            )
        }
        bgManager.scheduleBackgroundWorkersIfEnabled()
        if (enabled && mediaService.canSilentlyDeleteOriginals()) {
            bgManager.silentlyCleanStagedItemsIfAllowedAsync()
        }
    }

    fun refreshAccountAndStorage() {
        if (_uiState.value.isTestingConnection) return
        _uiState.update { it.copy(isTestingConnection = true, connectionStatus = null) }
        viewModelScope.launch {
            try {
                authManager.refreshGatewayRouteAndStorage()
                if (!settings.current.isSignedIn) return@launch
                val info = PhotoHubApiClient(context, settings).whoami()
                settings.updateServerCapabilities(info.storage, info.s3Enabled)
                val folderNote = info.userFolder?.let { "/$it" } ?: "/ (root)"
                val s3Note = if (info.s3Enabled == true) "S3" else "Direct"
                _uiState.update {
                    it.copy(
                        connectionStatus = "Connected · Folder: $folderNote · ${info.indexedPhotos} items ($s3Note)",
                        deviceAvailableBytes = DeviceStorageHelper.availableBytes()
                    )
                }
            } catch (err: Exception) {
                _uiState.update {
                    it.copy(connectionStatus = "Offline: ${err.localizedMessage}")
                }
            } finally {
                _uiState.update { it.copy(isTestingConnection = false) }
            }
        }
    }

    fun runDeleteDiagnostic() {
        _uiState.update {
            it.copy(
                isTestingDelete = true,
                deleteDiagResult = "Requesting native Android Trash dialog for latest photo (tap Cancel/Deny if you want to keep it)…"
            )
        }
        viewModelScope.launch {
            val latest = mediaService.findLatestImageCandidate(LocalProxyTracker.getInstance(context))
            if (latest == null) {
                _uiState.update {
                    it.copy(
                        isTestingDelete = false,
                        mediaPermissionLabel = mediaService.permissionLabel(),
                        deleteDiagResult = "Auth=${mediaService.permissionLabel()}, no unproxied photo found."
                    )
                }
                return@launch
            }
            try {
                when (val res = mediaService.prepareTrashOrDeleteOriginals(listOf(latest.id))) {
                    is TrashOrDeleteRequestResult.DeletedImmediately -> {
                        _uiState.update {
                            it.copy(
                                isTestingDelete = false,
                                mediaPermissionLabel = mediaService.permissionLabel(),
                                deleteDiagResult = "Deleted ${res.deletedIds.size} item(s). Auth=${mediaService.permissionLabel()}"
                            )
                        }
                    }
                    is TrashOrDeleteRequestResult.NeedsSystemConfirmation -> {
                        _uiState.update {
                            it.copy(pendingTestTrashIntentSender = res.intentSender)
                        }
                    }
                }
            } catch (err: Exception) {
                _uiState.update {
                    it.copy(
                        isTestingDelete = false,
                        mediaPermissionLabel = mediaService.permissionLabel(),
                        deleteDiagResult = "Failed: ${err.localizedMessage}"
                    )
                }
            }
        }
    }

    fun onDiagnosticTrashResult(confirmed: Boolean) {
        _uiState.update {
            it.copy(
                isTestingDelete = false,
                pendingTestTrashIntentSender = null,
                mediaPermissionLabel = mediaService.permissionLabel(),
                deleteDiagResult = if (confirmed) {
                    "Native Android Trash dialog confirmed for test item."
                } else {
                    "Native Android Trash dialog DID appear! (User tapped Deny/Cancel; Auth=${mediaService.permissionLabel()})"
                }
            )
        }
    }

    fun clearPendingTestTrash() {
        _uiState.update { it.copy(pendingTestTrashIntentSender = null) }
    }

    fun signOut() {
        syncManager.cancel()
        restoreOriginalsJob?.cancel()
        restoreOriginalsJob = null
        cachedServerPhotos = emptyList()
        _uiState.update {
            it.copy(
                isLoadingRestoreSummary = false,
                hasLoadedRestoreSummary = false,
                restoreLibraryTotalCount = 0,
                restoreLibraryUnrestoredCount = 0,
                restoreLibraryUnrestoredBytes = 0L,
                isBatchRestoringOriginals = false,
                restoreOriginalsCompleted = 0,
                restoreOriginalsTotal = 0,
                restoreOriginalsCurrentName = "",
                restoreOriginalsMessage = null,
                restoreOriginalsConfirmRequest = null,
                pendingProxyDeleteIntentSender = null,
                pendingProxyDeleteTargetIds = emptyList(),
                pendingProxyDeleteRemainingIds = emptyList(),
                pendingProxyDeleteBaseRestoredCount = 0,
                pendingProxyDeleteBaseFailedCount = 0,
                pendingProxyDeleteAlreadyDeletedCount = 0,
                pendingProxyDeleteFromRestoreRun = false
            )
        }
        settings.signOut()
    }

    fun downloadAllMissingToPhotos() {
        syncManager.downloadAllMissingToPhotos()
    }

    fun clearLocalProxyCache() {
        syncManager.cancel()
        store.clearAll()
        cachedServerPhotos = emptyList()
        _uiState.update {
            it.copy(
                localProxyCacheBytes = store.totalStorageBytes(),
                hasLoadedRestoreSummary = false,
                restoreLibraryTotalCount = 0,
                restoreLibraryUnrestoredCount = 0,
                restoreLibraryUnrestoredBytes = 0L
            )
        }
    }

    fun canWriteGallery(): Boolean = mediaService.canWriteGallery()

    fun refreshRestoreOriginalsSummary(fetchRemote: Boolean = true) {
        refreshCachedRestoreSummary()
        val cur = settings.current
        if (!fetchRemote || !cur.isSignedIn || cur.normalizedBaseUrl == null || _uiState.value.isLoadingRestoreSummary) {
            return
        }
        viewModelScope.launch {
            _uiState.update { it.copy(isLoadingRestoreSummary = true) }
            try {
                val fetched = PhotoHubApiClient(context, settings).fetchAllServerPhotos(sync = true)
                val latest = settings.current
                store.savePhotos(fetched, latest.normalizedBaseUrl, latest.apiKeyCacheScope)
                withContext(Dispatchers.IO) { applyRestoreSummary(fetched, markLoaded = true) }
            } catch (_: Exception) {
                // Keep cached summary when offline
            } finally {
                _uiState.update { it.copy(isLoadingRestoreSummary = false) }
            }
        }
    }

    fun requestRestoreAllOriginals() {
        val state = _uiState.value
        val cur = settings.current
        if (state.isBatchRestoringOriginals || state.isLoadingRestoreSummary || !cur.isSignedIn || cur.normalizedBaseUrl == null) {
            return
        }

        viewModelScope.launch {
            _uiState.update { it.copy(isLoadingRestoreSummary = true, restoreOriginalsMessage = null) }
            var fetchError: Exception? = null
            val targets: List<ServerPhoto> = try {
                val fetched = PhotoHubApiClient(context, settings).fetchAllServerPhotos(sync = true)
                val latest = settings.current
                store.savePhotos(fetched, latest.normalizedBaseUrl, latest.apiKeyCacheScope)
                withContext(Dispatchers.IO) { applyRestoreSummary(fetched, markLoaded = true) }
                fetched
            } catch (err: Exception) {
                fetchError = err
                withContext(Dispatchers.IO) { refreshCachedRestoreSummarySync() }
            }

            _uiState.update { it.copy(isLoadingRestoreSummary = false) }

            if (targets.isEmpty()) {
                val errMsg = fetchError?.let { "Could not load server library: ${it.localizedMessage ?: "Offline"}" }
                    ?: "No photos or videos found on server yet."
                _uiState.update { it.copy(restoreOriginalsMessage = errMsg) }
                return@launch
            }

            val req = withContext(Dispatchers.IO) {
                val verifiedLocalHashes = targets
                    .asSequence()
                    .map { it.hash.trim().lowercase(Locale.ROOT) }
                    .filter { it.isNotEmpty() && tracker.liveRestoredAssetId(it) != null }
                    .toSet()
                val leftoverProxyCount = if (verifiedLocalHashes.isNotEmpty()) {
                    mediaService.findCompressedProxyAssetIds(tracker, verifiedLocalHashes).size
                } else {
                    0
                }
                BatchRestorePlanner.buildConfirmRequest(
                    title = "Restore All Originals",
                    targets = targets,
                    locallyProtectedHashes = computeLocallyProtectedHashes(targets),
                    isRestoreAll = true,
                    leftoverProxyHashes = verifiedLocalHashes,
                    leftoverProxyCount = leftoverProxyCount
                )
            }
            _uiState.update { it.copy(restoreOriginalsConfirmRequest = req) }
        }
    }

    fun dismissRestoreOriginalsConfirm() {
        _uiState.update { it.copy(restoreOriginalsConfirmRequest = null) }
    }

    fun reportRestoreOriginalsPermissionDenied() {
        _uiState.update {
            it.copy(restoreOriginalsMessage = "Photos & Videos permission is required to save originals to Gallery.")
        }
    }

    fun dismissRestoreOriginalsMessage() {
        _uiState.update { it.copy(restoreOriginalsMessage = null) }
    }

    fun stopRestoreOriginals() {
        restoreOriginalsJob?.cancel()
    }

    fun clearPendingProxyDeleteIntent() {
        _uiState.update { it.copy(pendingProxyDeleteIntentSender = null) }
    }

    fun onProxyDeleteConfirmationResult(confirmed: Boolean) {
        val state = _uiState.value
        val targetIds = state.pendingProxyDeleteTargetIds
        val remainingIds = state.pendingProxyDeleteRemainingIds
        val baseRestored = state.pendingProxyDeleteBaseRestoredCount
        val baseFailed = state.pendingProxyDeleteBaseFailedCount
        val alreadyDeleted = state.pendingProxyDeleteAlreadyDeletedCount
        val fromRestore = state.pendingProxyDeleteFromRestoreRun

        viewModelScope.launch {
            if (confirmed) {
                if (targetIds.isNotEmpty()) {
                    withContext(Dispatchers.IO) { tracker.clearProxyMappings(targetIds) }
                }
                val nextDeleted = alreadyDeleted + targetIds.size
                if (remainingIds.isNotEmpty()) {
                    when (val nextRes = mediaService.deleteCompressedProxiesAfterRestore(tracker, remainingIds)) {
                        is com.photohub.compressor.media.CompressedProxyDeleteResult.Deleted -> {
                            val totalDeleted = nextDeleted + nextRes.deletedIds.size
                            val msg = if (fromRestore) {
                                BatchRestoreExecutor.formatSummaryMessage(
                                    ok = baseRestored,
                                    errCount = baseFailed,
                                    cancelled = false,
                                    deletedProxyCount = totalDeleted
                                )
                            } else {
                                "Deleted $totalDeleted compressed copy(s) from Gallery."
                            }
                            _uiState.update {
                                it.copy(
                                    pendingProxyDeleteIntentSender = null,
                                    pendingProxyDeleteTargetIds = emptyList(),
                                    pendingProxyDeleteRemainingIds = emptyList(),
                                    restoreOriginalsMessage = msg
                                )
                            }
                        }
                        is com.photohub.compressor.media.CompressedProxyDeleteResult.NeedsSystemConfirmation -> {
                            _uiState.update {
                                it.copy(
                                    pendingProxyDeleteIntentSender = nextRes.intentSender,
                                    pendingProxyDeleteTargetIds = nextRes.targetIds,
                                    pendingProxyDeleteRemainingIds = nextRes.remainingIds,
                                    pendingProxyDeleteAlreadyDeletedCount = nextDeleted + nextRes.alreadyDeletedIds.size
                                )
                            }
                        }
                    }
                    return@launch
                }

                val msg = if (fromRestore) {
                    BatchRestoreExecutor.formatSummaryMessage(
                        ok = baseRestored,
                        errCount = baseFailed,
                        cancelled = false,
                        deletedProxyCount = nextDeleted
                    )
                } else {
                    "Deleted $nextDeleted compressed copy(s) from Gallery."
                }
                _uiState.update {
                    it.copy(
                        pendingProxyDeleteIntentSender = null,
                        pendingProxyDeleteTargetIds = emptyList(),
                        pendingProxyDeleteRemainingIds = emptyList(),
                        restoreOriginalsMessage = msg
                    )
                }
            } else {
                val msg = if (fromRestore) {
                    if (alreadyDeleted > 0) {
                        "Restored $baseRestored original(s) & deleted $alreadyDeleted compressed copy(s); remaining copies kept (delete cancelled)."
                    } else {
                        "Restored $baseRestored original(s) to Gallery, but kept compressed copies (delete cancelled)."
                    }
                } else {
                    if (alreadyDeleted > 0) {
                        "Deleted $alreadyDeleted compressed copy(s); remaining copies kept (delete cancelled)."
                    } else {
                        "Kept compressed copies in Gallery (delete cancelled)."
                    }
                }
                _uiState.update {
                    it.copy(
                        pendingProxyDeleteIntentSender = null,
                        pendingProxyDeleteTargetIds = emptyList(),
                        pendingProxyDeleteRemainingIds = emptyList(),
                        restoreOriginalsMessage = msg
                    )
                }
            }
        }
    }

    fun executeDeleteLeftoverCompressedProxies() {
        val req = _uiState.value.restoreOriginalsConfirmRequest ?: return
        _uiState.update { it.copy(restoreOriginalsConfirmRequest = null) }
        val hashes = req.leftoverProxyHashes
        if (_uiState.value.isBatchRestoringOriginals || hashes.isEmpty()) return

        restoreOriginalsJob?.cancel()
        _uiState.update {
            it.copy(
                isBatchRestoringOriginals = true,
                restoreOriginalsMessage = null,
                restoreOriginalsCompleted = 0,
                restoreOriginalsTotal = 1,
                restoreOriginalsCurrentName = "Deleting compressed copies from Gallery…"
            )
        }

        restoreOriginalsJob = viewModelScope.launch {
            val proxyIds = mediaService.findCompressedProxyAssetIds(tracker, hashes)
            if (proxyIds.isEmpty()) {
                _uiState.update {
                    it.copy(
                        isBatchRestoringOriginals = false,
                        restoreOriginalsCurrentName = "",
                        restoreOriginalsMessage = "No compressed copies found in Gallery."
                    )
                }
                return@launch
            }
            when (val res = mediaService.deleteCompressedProxiesAfterRestore(tracker, proxyIds)) {
                is com.photohub.compressor.media.CompressedProxyDeleteResult.Deleted -> {
                    val count = res.deletedIds.size
                    _uiState.update {
                        it.copy(
                            isBatchRestoringOriginals = false,
                            restoreOriginalsCurrentName = "",
                            restoreOriginalsMessage = if (count > 0) {
                                "Deleted $count compressed copy(s) from Gallery."
                            } else {
                                "No compressed copies found in Gallery."
                            }
                        )
                    }
                }
                is com.photohub.compressor.media.CompressedProxyDeleteResult.NeedsSystemConfirmation -> {
                    _uiState.update {
                        it.copy(
                            isBatchRestoringOriginals = false,
                            restoreOriginalsCurrentName = "",
                            pendingProxyDeleteIntentSender = res.intentSender,
                            pendingProxyDeleteTargetIds = res.targetIds,
                            pendingProxyDeleteRemainingIds = res.remainingIds,
                            pendingProxyDeleteBaseRestoredCount = 0,
                            pendingProxyDeleteBaseFailedCount = 0,
                            pendingProxyDeleteAlreadyDeletedCount = res.alreadyDeletedIds.size,
                            pendingProxyDeleteFromRestoreRun = false
                        )
                    }
                }
            }
        }
    }

    fun executeRestoreOriginalsConfirm(includeAlreadyRestored: Boolean = false) {
        val req = _uiState.value.restoreOriginalsConfirmRequest ?: return
        _uiState.update { it.copy(restoreOriginalsConfirmRequest = null) }
        val targets = BatchRestorePlanner.resolveExecutionTargets(req, includeAlreadyRestored)
        if (_uiState.value.isBatchRestoringOriginals || targets.isEmpty()) return
        if (!mediaService.canWriteGallery()) {
            reportRestoreOriginalsPermissionDenied()
            return
        }

        restoreOriginalsJob?.cancel()
        _uiState.update {
            it.copy(
                isBatchRestoringOriginals = true,
                restoreOriginalsMessage = null,
                restoreOriginalsCompleted = 0,
                restoreOriginalsTotal = targets.size,
                restoreOriginalsCurrentName = "Preparing…"
            )
        }

        restoreOriginalsJob = viewModelScope.launch {
            val client = PhotoHubApiClient(context, settings)
            val cur = settings.current
            BatchRestoreExecutor.runBatchRestore(
                context = context,
                client = client,
                mediaService = mediaService,
                tracker = tracker,
                targets = targets,
                deleteCompressedProxies = true,
                additionalProxyCleanupHashes = req.leftoverProxyHashes,
                onPhaseChange = { stage ->
                    _uiState.update { it.copy(restoreOriginalsCurrentName = stage) }
                },
                onItemComplete = { progress ->
                    val updated = progress.updatedPhoto
                    if (updated != null) {
                        store.updatePhoto(updated, cur.normalizedBaseUrl, cur.apiKeyCacheScope, notify = false)
                        cachedServerPhotos = cachedServerPhotos.map {
                            if (it.hash.equals(updated.hash, ignoreCase = true)) updated else it
                        }
                    }
                    _uiState.update {
                        it.copy(
                            restoreOriginalsCompleted = progress.completed,
                            restoreOriginalsCurrentName = progress.currentName
                        )
                    }
                },
                onFinished = { result ->
                    withContext(Dispatchers.IO) {
                        applyRestoreSummary(
                            cachedServerPhotos,
                            markLoaded = _uiState.value.hasLoadedRestoreSummary || cachedServerPhotos.isNotEmpty()
                        )
                    }
                    store.notifyChanged()
                    val pending = result.proxyDeletePending
                    _uiState.update {
                        it.copy(
                            isBatchRestoringOriginals = false,
                            restoreOriginalsCurrentName = "",
                            restoreOriginalsMessage = result.summaryMessage,
                            pendingProxyDeleteIntentSender = pending?.intentSender,
                            pendingProxyDeleteTargetIds = pending?.targetIds ?: emptyList(),
                            pendingProxyDeleteRemainingIds = pending?.remainingIds ?: emptyList(),
                            pendingProxyDeleteBaseRestoredCount = result.succeeded,
                            pendingProxyDeleteBaseFailedCount = result.failed,
                            pendingProxyDeleteAlreadyDeletedCount = result.deletedProxyCount,
                            pendingProxyDeleteFromRestoreRun = pending != null
                        )
                    }
                }
            )
        }
    }

    private fun refreshCachedRestoreSummary() {
        viewModelScope.launch(Dispatchers.IO) {
            refreshCachedRestoreSummarySync()
        }
    }

    private fun refreshCachedRestoreSummarySync(): List<ServerPhoto> {
        val cur = settings.current
        val cached = store.cachedPhotos(cur.normalizedBaseUrl, cur.apiKeyCacheScope)
        applyRestoreSummary(cached, markLoaded = cached.isNotEmpty())
        return cached
    }

    private fun applyRestoreSummary(photos: List<ServerPhoto>, markLoaded: Boolean) {
        cachedServerPhotos = photos
        val prompt = BatchRestorePlanner.buildConfirmRequest(
            title = "Restore All Originals",
            targets = photos,
            locallyProtectedHashes = computeLocallyProtectedHashes(photos),
            isRestoreAll = true
        )
        _uiState.update {
            it.copy(
                hasLoadedRestoreSummary = markLoaded,
                restoreLibraryTotalCount = photos.size,
                restoreLibraryUnrestoredCount = prompt.unrestoredTargets.size,
                restoreLibraryUnrestoredBytes = prompt.unrestoredBytes,
                deviceAvailableBytes = prompt.deviceAvailableBytes
            )
        }
    }

    private fun computeLocallyProtectedHashes(photos: List<ServerPhoto>): Set<String> =
        photos.asSequence()
            .map { it.hash.trim().lowercase(Locale.ROOT) }
            .filter { it.isNotEmpty() && tracker.isRestoredMasterHash(it) }
            .toSet()
}
