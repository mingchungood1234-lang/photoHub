package com.photohub.compressor.sync

import android.content.Context
import com.photohub.compressor.data.AppSettings
import com.photohub.compressor.data.ServerPhoto
import com.photohub.compressor.media.MediaLibraryService
import com.photohub.compressor.media.OrderedCommitGate
import com.photohub.compressor.media.PhotoBackupPipeline
import com.photohub.compressor.media.ProxyGenerator
import com.photohub.compressor.network.PhotoHubApiClient
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

data class LocalSyncUiState(
    val isSyncing: Boolean = false,
    val completedCount: Int = 0,
    val totalCount: Int = 0,
    val savedToPhotosCount: Int = 0,
    val statusText: String = ""
)

private data class PrefetchWorkItem(
    val photo: ServerPhoto,
    val cachePreviewLocally: Boolean,
    val cacheVideoLocally: Boolean,
    val saveToPhotosApp: Boolean
)

class LocalProxySyncManager private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val settings = AppSettings.getInstance(appContext)
    private val store = LocalProxyStore.getInstance(appContext)
    private val tracker = LocalProxyTracker.getInstance(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _state = MutableStateFlow(LocalSyncUiState())
    val state: StateFlow<LocalSyncUiState> = _state.asStateFlow()

    private val _serverSyncCompleted = MutableSharedFlow<Unit>(extraBufferCapacity = 8)
    val serverSyncCompleted: SharedFlow<Unit> = _serverSyncCompleted.asSharedFlow()

    private var activeJob: Job? = null

    fun cancel() {
        activeJob?.cancel()
        activeJob = null
        _state.value = LocalSyncUiState()
    }

    fun syncFromServerOnLaunch() {
        val cur = settings.current
        if (!cur.isSignedIn ||
            (!cur.autoDownloadLocalProxies && !cur.autoSaveProxiesToPhotosApp) ||
            cur.normalizedBaseUrl == null
        ) {
            return
        }

        activeJob?.cancel()
        activeJob = scope.launch {
            try {
                val client = PhotoHubApiClient(appContext, settings)
                val fetched = client.fetchAllServerPhotos(sync = false)
                if (!isActive) return@launch
                store.savePhotos(fetched, cur.normalizedBaseUrl, cur.apiKeyCacheScope)
                store.notifyChanged()
                _serverSyncCompleted.tryEmit(Unit)

                prefetchMissingProxies(
                    photos = fetched,
                    client = client,
                    cachePreviewsLocally = cur.autoDownloadLocalProxies,
                    cacheVideosLocally = cur.autoDownloadLocalProxies && cur.autoDownloadLocalVideos,
                    saveToPhotosApp = cur.autoSaveProxiesToPhotosApp,
                    forceAllMissingInPhotos = false
                )
            } catch (_: Exception) {
                // Silent on launch; errors surface on Server tab
            }
        }
    }

    fun startPrefetchIfNeeded(photos: List<ServerPhoto>) {
        val cur = settings.current
        if (!cur.autoDownloadLocalProxies && !cur.autoSaveProxiesToPhotosApp) {
            cancel()
            return
        }
        activeJob?.cancel()
        activeJob = scope.launch {
            val client = PhotoHubApiClient(appContext, settings)
            prefetchMissingProxies(
                photos = photos,
                client = client,
                cachePreviewsLocally = cur.autoDownloadLocalProxies,
                cacheVideosLocally = cur.autoDownloadLocalProxies && cur.autoDownloadLocalVideos,
                saveToPhotosApp = cur.autoSaveProxiesToPhotosApp,
                forceAllMissingInPhotos = false
            )
        }
    }

    fun downloadAllMissingToPhotos(knownPhotos: List<ServerPhoto> = emptyList()) {
        val cur = settings.current
        if (cur.normalizedBaseUrl == null) return

        activeJob?.cancel()
        activeJob = scope.launch {
            val mediaService = MediaLibraryService(appContext)
            if (!mediaService.canWriteGallery()) {
                _state.value = LocalSyncUiState(
                    isSyncing = false,
                    statusText = "Allow Photos & Videos permission in Android Settings to save proxies."
                )
                return@launch
            }

            _state.value = LocalSyncUiState(
                isSyncing = true,
                statusText = "Checking server proxies…"
            )

            val client = PhotoHubApiClient(appContext, settings)
            val targetPhotos = runCatching {
                val fresh = client.fetchAllServerPhotos(sync = true)
                if (fresh.isNotEmpty()) {
                    store.savePhotos(fresh, cur.normalizedBaseUrl, cur.apiKeyCacheScope)
                    fresh
                } else {
                    knownPhotos
                }
            }.getOrDefault(knownPhotos)

            prefetchMissingProxies(
                photos = targetPhotos,
                client = client,
                cachePreviewsLocally = cur.autoDownloadLocalProxies,
                cacheVideosLocally = cur.autoDownloadLocalProxies && cur.autoDownloadLocalVideos,
                saveToPhotosApp = true,
                forceAllMissingInPhotos = true
            )
        }
    }

    private suspend fun prefetchMissingProxies(
        photos: List<ServerPhoto>,
        client: PhotoHubApiClient,
        cachePreviewsLocally: Boolean,
        cacheVideosLocally: Boolean,
        saveToPhotosApp: Boolean,
        forceAllMissingInPhotos: Boolean
    ) {
        val mediaService = MediaLibraryService(appContext)
        val canReadGallery = mediaService.currentAccessLevel() != com.photohub.compressor.media.MediaAccessLevel.DENIED
        val canWriteGallery = saveToPhotosApp && mediaService.canWriteGallery()
        val existingProxyPrefixes = if (canReadGallery) {
            mediaService.scanExistingProxyPrefixesInGallery()
        } else {
            emptyMap()
        }
        val existingOriginalsMap = if (canReadGallery) {
            mediaService.scanExistingOriginalMapInGallery()
        } else {
            emptyMap()
        }

        val workItems = mutableListOf<PrefetchWorkItem>()
        for (photo in photos) {
            val hasServerPreview = (photo.hasPreview == true) ||
                (photo.hasPreview == null && photo.hasProxy == true && !photo.isVideo)
            val hasServerVideoProxy = photo.isVideo && photo.hasVideoProxy == true

            val prefixTag = ProxyGenerator.proxyPrefixTag(photo.hash)
            val syncedAssetId = existingProxyPrefixes[prefixTag]
            if (syncedAssetId != null) {
                tracker.markAsProxy(
                    assetId = syncedAssetId,
                    proxySha256 = photo.proxyHash.orEmpty(),
                    masterHash = photo.hash,
                    originalName = photo.originalName
                )
            }

            // Detect any matching original already sitting in native Android Gallery (prevents duplicate downloads & saves!)
            var matchedOriginalAssetId: String? = null
            if (existingOriginalsMap.isNotEmpty()) {
                val keys = mediaService.originalMatchKeys(photo.originalName, photo.parsedCreationDateMs, photo.size, photo.isVideo)
                for (key in keys) {
                    val found = existingOriginalsMap[key]
                    if (found != null) {
                        matchedOriginalAssetId = found
                        tracker.markUploadedOriginal(found, photo.hash)
                        break
                    }
                }
            }

            val isActiveUpload = com.photohub.compressor.background.AssetUploadCoordinator.isMasterHashActive(photo.hash)
            val hasLiveNativeGalleryAsset = tracker.hasAnyLiveGalleryAsset(photo.hash) ||
                syncedAssetId != null ||
                matchedOriginalAssetId != null ||
                isActiveUpload

            // Skip downloading into LocalProxyStore whenever a live copy already exists in native Gallery
            // (Cloud tab loads thumbnails & plays videos straight from MediaStore with zero duplication!).
            val needCachePreview = cachePreviewsLocally &&
                !hasLiveNativeGalleryAsset &&
                hasServerPreview &&
                store.previewData(photo.hash) == null
            val needCacheVideo = cacheVideosLocally &&
                !hasLiveNativeGalleryAsset &&
                hasServerVideoProxy &&
                store.videoProxyFileIfExists(photo.hash) == null

            val isProtected = photo.keepOriginalOnDevice == true || tracker.isRestoredMasterHash(photo.hash)
            val alreadyInGallery = when {
                isProtected || hasLiveNativeGalleryAsset -> true
                forceAllMissingInPhotos -> false
                else -> tracker.isMasterHandledForPhotos(photo.hash)
            }

            val canSupplyMedia = if (photo.isVideo) {
                hasServerVideoProxy || store.videoProxyFileIfExists(photo.hash) != null
            } else {
                hasServerPreview || store.previewData(photo.hash) != null
            }

            val needSaveGallery = canWriteGallery && !photo.needsProxy && !alreadyInGallery && canSupplyMedia
            if (needCachePreview || needCacheVideo || needSaveGallery) {
                workItems.add(
                    PrefetchWorkItem(
                        photo = photo,
                        cachePreviewLocally = needCachePreview || (!photo.isVideo && needSaveGallery && cachePreviewsLocally),
                        cacheVideoLocally = needCacheVideo || (photo.isVideo && needSaveGallery && cacheVideosLocally),
                        saveToPhotosApp = needSaveGallery
                    )
                )
            }
        }

        if (workItems.isEmpty()) {
            _state.value = LocalSyncUiState(
                isSyncing = false,
                statusText = if (forceAllMissingInPhotos) "All proxied items are already saved in Gallery." else ""
            )
            return
        }

        val galleryTargets = workItems.count { it.saveToPhotosApp }
        if (galleryTargets > 1) {
            // Insert oldest photos into Android MediaStore first and newest photos LAST so
            // third-party share pickers (WhatsApp, Telegram, Instagram, Android Photo Picker)
            // show the newest photo first — matching the native Gallery timeline.
            val orderedHashes = PhotoBackupPipeline
                .sortServerPhotosOldestFirst(workItems.map { it.photo })
                .withIndex()
                .associate { it.value.hash.lowercase() to it.index }
            workItems.sortBy { orderedHashes[it.photo.hash.lowercase()] ?: Int.MAX_VALUE }
        }
        val total = workItems.size
        val completed = AtomicInteger(0)
        val savedCount = AtomicInteger(0)
        _state.value = LocalSyncUiState(
            isSyncing = true,
            completedCount = 0,
            totalCount = total,
            savedToPhotosCount = 0,
            statusText = if (galleryTargets > 0) {
                "Downloading proxies to Gallery (0/$total)…"
            } else {
                "Auto-downloading local proxies (0/$total)…"
            }
        )

        val channel = Channel<Pair<Int, PrefetchWorkItem>>(Channel.UNLIMITED)
        workItems.forEachIndexed { idx, item -> channel.trySend(idx to item) }
        channel.close()
        val commitGate = if (galleryTargets > 0) OrderedCommitGate() else null

        try {
            coroutineScope {
                val workerCount = minOf(4, workItems.size)
                val workers = List(workerCount) {
                    launch {
                        for ((workIndex, item) in channel) {
                            if (!isActive) break
                            val photo = item.photo

                            var imageBytes = store.previewData(photo.hash)
                            if (imageBytes == null && (item.cachePreviewLocally || (!photo.isVideo && item.saveToPhotosApp))) {
                                runCatching { client.downloadPhotoPreviewData(photo.hash) }.getOrNull()?.let { raw ->
                                    imageBytes = if (item.cachePreviewLocally) {
                                        store.cacheDownloadedPreviewData(raw, photo.hash)
                                    } else {
                                        store.makeSmallCompressedPreview(raw)?.second ?: raw
                                    }
                                }
                            }

                            var videoFile = store.videoProxyFileIfExists(photo.hash)
                            var tempVideo: File? = null
                            try {
                                if (videoFile == null && (item.cacheVideoLocally || (photo.isVideo && item.saveToPhotosApp))) {
                                    runCatching { client.downloadVideoProxyToTempFile(photo.hash) }.getOrNull()?.let { downloaded ->
                                        if (item.cacheVideoLocally) {
                                            videoFile = store.copyVideoProxy(downloaded, photo.hash)
                                            downloaded.delete()
                                        } else {
                                            videoFile = downloaded
                                            tempVideo = downloaded
                                        }
                                    }
                                }

                                var savedNow = false
                                if (item.saveToPhotosApp) {
                                    val canCommit = commitGate?.waitForTurn(workIndex) ?: true
                                    if (canCommit) {
                                        val res = runCatching {
                                            mediaService.saveServerProxyToGallery(photo, imageBytes, videoFile)
                                        }.getOrNull()
                                        if (res != null) savedNow = true
                                    }
                                }

                                val done = completed.incrementAndGet()
                                val saved = if (savedNow) savedCount.incrementAndGet() else savedCount.get()
                                _state.value = LocalSyncUiState(
                                    isSyncing = true,
                                    completedCount = done,
                                    totalCount = total,
                                    savedToPhotosCount = saved,
                                    statusText = if (galleryTargets > 0) {
                                        "Downloading proxies to Gallery ($done/$total)…"
                                    } else {
                                        "Auto-downloading local proxies ($done/$total)…"
                                    }
                                )
                                if (done % 4 == 0) store.notifyChanged()
                            } finally {
                                commitGate?.completeTurn(workIndex)
                                tempVideo?.delete()
                            }
                        }
                    }
                }
                workers.joinAll()
            }
        } finally {
            commitGate?.cancelAll()
        }

        store.notifyChanged()
        _state.value = LocalSyncUiState(
            isSyncing = false,
            completedCount = completed.get(),
            totalCount = total,
            savedToPhotosCount = savedCount.get(),
            statusText = if (forceAllMissingInPhotos) {
                "Saved ${savedCount.get()} proxy item(s) to Gallery."
            } else {
                ""
            }
        )
    }

    companion object {
        @Volatile
        private var instance: LocalProxySyncManager? = null

        fun getInstance(context: Context): LocalProxySyncManager =
            instance ?: synchronized(this) {
                instance ?: LocalProxySyncManager(context).also { instance = it }
            }
    }
}
