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
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

data class SettingsUiState(
    val isTestingConnection: Boolean = false,
    val connectionStatus: String? = null,
    val isTestingDelete: Boolean = false,
    val deleteDiagResult: String? = null,
    val pendingTestTrashIntentSender: IntentSender? = null,
    val localProxyCacheBytes: Long = 0L,
    val mediaPermissionLabel: String = "Denied"
)

class SettingsViewModel(application: Application) : AndroidViewModel(application) {
    private val context = application.applicationContext
    val settings = AppSettings.getInstance(context)
    val bgManager = BackgroundBackupManager.getInstance(context)
    val syncManager = LocalProxySyncManager.getInstance(context)
    private val authManager = GoogleAuthManager.getInstance(context)
    private val store = LocalProxyStore.getInstance(context)
    private val mediaService = MediaLibraryService(context)

    private val _uiState = MutableStateFlow(
        SettingsUiState(
            localProxyCacheBytes = store.totalStorageBytes(),
            mediaPermissionLabel = mediaService.permissionLabel()
        )
    )
    val uiState: StateFlow<SettingsUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            store.changes.collect {
                _uiState.update { it.copy(localProxyCacheBytes = store.totalStorageBytes()) }
            }
        }
    }

    fun onAppear() {
        bgManager.refreshNotificationPermissionLabel()
        _uiState.update {
            it.copy(
                localProxyCacheBytes = store.totalStorageBytes(),
                mediaPermissionLabel = mediaService.permissionLabel()
            )
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
                settings.updateServerStorage(info.storage)
                val folderNote = info.userFolder?.let { "/$it" } ?: "/ (root)"
                val s3Note = if (info.s3Enabled == true) "S3" else "Direct"
                _uiState.update {
                    it.copy(connectionStatus = "Connected · Folder: $folderNote · ${info.indexedPhotos} items ($s3Note)")
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
        settings.signOut()
    }

    fun downloadAllMissingToPhotos() {
        syncManager.downloadAllMissingToPhotos()
    }

    fun clearLocalProxyCache() {
        syncManager.cancel()
        store.clearAll()
        _uiState.update { it.copy(localProxyCacheBytes = store.totalStorageBytes()) }
    }
}
