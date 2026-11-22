package com.photohub.compressor.viewmodel

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.MediaStore
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.photohub.compressor.data.*
import com.photohub.compressor.media.MediaLibraryService
import com.photohub.compressor.media.OriginalDownloadCache
import com.photohub.compressor.media.OriginalMediaResolver
import com.photohub.compressor.media.ProxyGenerator
import com.photohub.compressor.network.ApiHttpException
import com.photohub.compressor.network.PhotoHubApiClient
import com.photohub.compressor.sync.LocalProxyStore
import com.photohub.compressor.sync.LocalProxySyncManager
import com.photohub.compressor.sync.LocalProxyTracker
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.io.File
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.atomic.AtomicInteger

enum class ServerGalleryFilter(val title: String) {
    ALL("All"),
    NEEDS_PROXY("Needs Proxy")
}

enum class ServerMediaTypeFilter(val title: String) {
    ALL("All Media"),
    PHOTOS("Photos Only"),
    VIDEOS("Videos Only")
}

enum class ServerTimelineGrouping(val title: String) {
    DAY("Date & Year"),
    MONTH("Month & Year"),
    YEAR("Year Only")
}

data class ServerTimelineYearSummary(
    val year: Int?,
    val label: String,
    val anchorId: String,
    val itemCount: Int,
    val videoCount: Int
)

data class ServerTimelineSection(
    val id: String,
    val anchorId: String,
    val year: Int?,
    val yearLabel: String,
    val startsNewYear: Boolean,
    val title: String,
    val scrubLabel: String,
    val subtitle: String,
    val photos: List<ServerPhoto>
)

data class ServerTimelineData(
    val sections: List<ServerTimelineSection> = emptyList(),
    val years: List<ServerTimelineYearSummary> = emptyList()
)

object ServerTimelineBuilder {
    fun build(
        photos: List<ServerPhoto>,
        filterMode: ServerGalleryFilter,
        mediaTypeFilter: ServerMediaTypeFilter,
        grouping: ServerTimelineGrouping,
        nowMs: Long = System.currentTimeMillis()
    ): ServerTimelineData {
        val filtered = photos.filter { photo ->
            if (filterMode == ServerGalleryFilter.NEEDS_PROXY && !photo.needsProxy) return@filter false
            when (mediaTypeFilter) {
                ServerMediaTypeFilter.ALL -> true
                ServerMediaTypeFilter.PHOTOS -> !photo.isVideo
                ServerMediaTypeFilter.VIDEOS -> photo.isVideo
            }
        }
        if (filtered.isEmpty()) return ServerTimelineData()

        val paired = filtered.map { it to it.parsedCreationDateMs }.sortedWith { lhs, rhs ->
            val ld = lhs.second
            val rd = rhs.second
            when {
                ld != null && rd != null && ld != rd -> rd.compareTo(ld)
                ld != null && rd == null -> -1
                ld == null && rd != null -> 1
                lhs.first.originalName != rhs.first.originalName -> rhs.first.originalName.compareTo(lhs.first.originalName)
                else -> rhs.first.hash.compareTo(lhs.first.hash)
            }
        }

        val cal = Calendar.getInstance().apply { timeInMillis = nowMs }
        val currentYear = cal.get(Calendar.YEAR)
        val todayDay = cal.get(Calendar.DAY_OF_YEAR)
        val yesterdayCal = Calendar.getInstance().apply {
            timeInMillis = nowMs
            add(Calendar.DAY_OF_YEAR, -1)
        }
        val yesterdayYear = yesterdayCal.get(Calendar.YEAR)
        val yesterdayDay = yesterdayCal.get(Calendar.DAY_OF_YEAR)

        val sameYearFmt = SimpleDateFormat("EEE, MMM d", Locale.getDefault())
        val otherYearFmt = SimpleDateFormat("MMM d, yyyy", Locale.getDefault())
        val monthYearFmt = SimpleDateFormat("MMMM yyyy", Locale.getDefault())
        val scrubMonthFmt = SimpleDateFormat("MMM yyyy", Locale.getDefault())

        data class Bucket(
            val key: String,
            val year: Int?,
            val yearLabel: String,
            val title: String,
            val scrubLabel: String,
            val photos: MutableList<ServerPhoto> = mutableListOf()
        )

        val buckets = mutableListOf<Bucket>()
        val itemCal = Calendar.getInstance()

        for ((photo, dateMs) in paired) {
            val key: String
            val year: Int?
            val yearLabel: String
            val title: String
            val scrubLabel: String

            if (dateMs != null) {
                itemCal.timeInMillis = dateMs
                val y = itemCal.get(Calendar.YEAR)
                val m = itemCal.get(Calendar.MONTH) + 1
                val d = itemCal.get(Calendar.DAY_OF_MONTH)
                val doy = itemCal.get(Calendar.DAY_OF_YEAR)
                year = y
                yearLabel = y.toString()
                val dateObj = Date(dateMs)

                when (grouping) {
                    ServerTimelineGrouping.DAY -> {
                        key = String.format(Locale.US, "%04d-%02d-%02d", y, m, d)
                        title = when {
                            y == currentYear && doy == todayDay -> "Today"
                            y == yesterdayYear && doy == yesterdayDay -> "Yesterday"
                            y == currentYear -> sameYearFmt.format(dateObj)
                            else -> otherYearFmt.format(dateObj)
                        }
                        scrubLabel = otherYearFmt.format(dateObj)
                    }
                    ServerTimelineGrouping.MONTH -> {
                        key = String.format(Locale.US, "%04d-%02d", y, m)
                        title = monthYearFmt.format(dateObj)
                        scrubLabel = scrubMonthFmt.format(dateObj)
                    }
                    ServerTimelineGrouping.YEAR -> {
                        key = y.toString()
                        title = y.toString()
                        scrubLabel = y.toString()
                    }
                }
            } else {
                key = "undated"
                year = null
                yearLabel = "Undated"
                title = "Undated"
                scrubLabel = "Undated"
            }

            val last = buckets.lastOrNull()
            if (last != null && last.key == key) {
                last.photos.add(photo)
            } else {
                buckets.add(Bucket(key, year, yearLabel, title, scrubLabel, mutableListOf(photo)))
            }
        }

        val sections = ArrayList<ServerTimelineSection>(buckets.size)
        val years = mutableListOf<ServerTimelineYearSummary>()
        val yearIndexMap = mutableMapOf<String, Int>()
        var prevYearLabel: String? = null

        for (b in buckets) {
            val startsNewYear = (b.yearLabel != prevYearLabel)
            prevYearLabel = b.yearLabel
            val totalCount = b.photos.size
            val videoCount = b.photos.count { it.isVideo }
            val photoCount = (totalCount - videoCount).coerceAtLeast(0)
            val subtitle = when {
                photoCount > 0 && videoCount > 0 ->
                    "$photoCount photo${if (photoCount == 1) "" else "s"} · $videoCount video${if (videoCount == 1) "" else "s"}"
                videoCount > 0 -> "$videoCount video${if (videoCount == 1) "" else "s"}"
                else -> "$photoCount photo${if (photoCount == 1) "" else "s"}"
            }

            sections.add(
                ServerTimelineSection(
                    id = b.key,
                    anchorId = "sec-${b.key}",
                    year = b.year,
                    yearLabel = b.yearLabel,
                    startsNewYear = startsNewYear,
                    title = b.title,
                    scrubLabel = b.scrubLabel,
                    subtitle = subtitle,
                    photos = b.photos
                )
            )

            val existingIdx = yearIndexMap[b.yearLabel]
            if (existingIdx != null) {
                val prev = years[existingIdx]
                years[existingIdx] = prev.copy(
                    itemCount = prev.itemCount + totalCount,
                    videoCount = prev.videoCount + videoCount
                )
            } else {
                yearIndexMap[b.yearLabel] = years.size
                years.add(
                    ServerTimelineYearSummary(
                        year = b.year,
                        label = b.yearLabel,
                        anchorId = "year-${b.yearLabel}",
                        itemCount = totalCount,
                        videoCount = videoCount
                    )
                )
            }
        }

        return ServerTimelineData(sections = sections, years = years)
    }
}

data class BatchRestoreConfirmRequest(
    val title: String,
    val allTargets: List<ServerPhoto>,
    val unrestoredTargets: List<ServerPhoto>,
    val skippedCount: Int,
    val unrestoredBytes: Long,
    val allBytes: Long,
    val isRestoreAll: Boolean
)

object BatchRestorePlanner {
    fun buildConfirmRequest(
        title: String,
        targets: List<ServerPhoto>,
        locallyProtectedHashes: Set<String>,
        isRestoreAll: Boolean
    ): BatchRestoreConfirmRequest {
        val normProtected = locallyProtectedHashes.map { it.trim().lowercase(Locale.ROOT) }.toSet()
        val unrestored = targets.filter { photo ->
            !photo.isProtectedOriginal && !normProtected.contains(photo.hash.trim().lowercase(Locale.ROOT))
        }
        return BatchRestoreConfirmRequest(
            title = title,
            allTargets = targets,
            unrestoredTargets = unrestored,
            skippedCount = (targets.size - unrestored.size).coerceAtLeast(0),
            unrestoredBytes = unrestored.sumOf { maxOf(0L, it.size) },
            allBytes = targets.sumOf { maxOf(0L, it.size) },
            isRestoreAll = isRestoreAll
        )
    }

    fun resolveExecutionTargets(
        request: BatchRestoreConfirmRequest,
        includeAlreadyRestored: Boolean
    ): List<ServerPhoto> =
        if (includeAlreadyRestored || request.unrestoredTargets.isEmpty()) {
            request.allTargets
        } else {
            request.unrestoredTargets
        }
}

data class ServerGalleryUiState(
    val photos: List<ServerPhoto> = emptyList(),
    val timeline: ServerTimelineData = ServerTimelineData(),
    val imageCache: Map<String, Bitmap> = emptyMap(),
    val failedPreviewHashes: Set<String> = emptySet(),
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
    val filterMode: ServerGalleryFilter = ServerGalleryFilter.ALL,
    val mediaTypeFilter: ServerMediaTypeFilter = ServerMediaTypeFilter.ALL,
    val timelineGrouping: ServerTimelineGrouping = ServerTimelineGrouping.DAY,
    val selectedYearAnchor: String? = null,
    val isSelectionMode: Boolean = false,
    val selectedHashes: Set<String> = emptySet(),
    val locallyProtectedHashes: Set<String> = emptySet(),
    val isBatchProxying: Boolean = false,
    val batchCompleted: Int = 0,
    val batchTotal: Int = 0,
    val batchStatusText: String = "",
    val batchBannerMessage: String? = null,
    val isBatchRestoring: Boolean = false,
    val restoreCompleted: Int = 0,
    val restoreTotal: Int = 0,
    val restoreStatusText: String = "",
    val restoreBannerMessage: String? = null,
    val restoreConfirmRequest: BatchRestoreConfirmRequest? = null,
    val isResolvingPick: Boolean = false,
    val pickStatusText: String = "Preparing original…",
    val pickerErrorMessage: String? = null,
    val shareFileReady: File? = null
) {
    val unproxiedCount: Int get() = photos.count { it.needsProxy }
    val visiblePhotos: List<ServerPhoto> get() = timeline.sections.flatMap { it.photos }
    fun isRestoredOrProtected(photo: ServerPhoto): Boolean =
        photo.isProtectedOriginal || locallyProtectedHashes.contains(photo.hash.lowercase(Locale.ROOT))
    val unrestoredCount: Int get() = photos.count { !isRestoredOrProtected(it) }
}

data class PhotoDetailUiState(
    val photo: ServerPhoto,
    val isLocallyProtected: Boolean = false,
    val previewBitmap: Bitmap? = null,
    val videoFile: File? = null,
    val isLoadingVideo: Boolean = false,
    val videoUnavailableNote: String? = null,
    val isBusy: Boolean = false,
    val busyLabel: String = "",
    val saveMessage: String? = null,
    val shareFileReady: File? = null
)

class ServerGalleryViewModel(application: Application) : AndroidViewModel(application) {
    private val context = application.applicationContext
    private val settings = AppSettings.getInstance(context)
    private val store = LocalProxyStore.getInstance(context)
    private val tracker = LocalProxyTracker.getInstance(context)
    private val syncManager = LocalProxySyncManager.getInstance(context)
    private val mediaService = MediaLibraryService(context)

    private val _uiState = MutableStateFlow(ServerGalleryUiState())
    val uiState: StateFlow<ServerGalleryUiState> = _uiState.asStateFlow()

    private val _detailState = MutableStateFlow<PhotoDetailUiState?>(null)
    val detailState: StateFlow<PhotoDetailUiState?> = _detailState.asStateFlow()

    private val inFlightPreviews = Collections.synchronizedSet(mutableSetOf<String>())
    private var batchJob: Job? = null
    private var restoreJob: Job? = null
    private var speculativePrefetchJob: Job? = null

    init {
        viewModelScope.launch {
            store.changes.collect {
                loadFromLocalStore()
            }
        }
    }

    fun onEnterScreen() {
        loadFromLocalStore()
        loadPhotos()
        viewModelScope.launch {
            PhotoHubApiClient(context, settings).warmConnectionIfNeeded()
        }
    }

    private fun normHash(hash: String): String = hash.trim().lowercase(Locale.ROOT)

    private fun computeLocallyProtectedHashes(photos: List<ServerPhoto>): Set<String> =
        photos.asSequence()
            .map { normHash(it.hash) }
            .filter { it.isNotEmpty() && tracker.isRestoredMasterHash(it) }
            .toSet()

    fun refreshProtectedHashes() {
        val currentPhotos = _uiState.value.photos
        val protectedSet = computeLocallyProtectedHashes(currentPhotos)
        _uiState.update { it.copy(locallyProtectedHashes = protectedSet) }
    }

    fun loadFromLocalStore() {
        val cur = settings.current
        val cached = store.cachedPhotos(cur.normalizedBaseUrl, cur.apiKeyCacheScope)
        viewModelScope.launch(Dispatchers.IO) {
            val loadedBitmaps = mutableMapOf<String, Bitmap>()
            for (photo in cached) {
                if (!_uiState.value.imageCache.containsKey(photo.hash)) {
                    store.previewData(photo.hash)?.let { data ->
                        BitmapFactory.decodeByteArray(data, 0, data.size)?.let { bmp ->
                            loadedBitmaps[photo.hash] = bmp
                        }
                    }
                }
            }
            val protectedSet = computeLocallyProtectedHashes(cached)
            withContext(Dispatchers.Main) {
                _uiState.update { prev ->
                    val nextPhotos = if (cached.isNotEmpty() || prev.photos.isEmpty()) cached else prev.photos
                    val nextCache = if (loadedBitmaps.isEmpty()) prev.imageCache else prev.imageCache + loadedBitmaps
                    val rebuilt = rebuildTimelineData(nextPhotos, prev.filterMode, prev.mediaTypeFilter, prev.timelineGrouping, prev.selectedYearAnchor)
                    prev.copy(
                        photos = nextPhotos,
                        imageCache = nextCache,
                        locallyProtectedHashes = if (nextPhotos === cached) protectedSet else computeLocallyProtectedHashes(nextPhotos),
                        timeline = rebuilt.first,
                        selectedYearAnchor = rebuilt.second
                    )
                }
            }
        }
    }

    fun loadPhotos() {
        if (_uiState.value.isLoading) return
        _uiState.update { it.copy(isLoading = true) }

        viewModelScope.launch {
            val client = PhotoHubApiClient(context, settings)
            try {
                val fetched = client.fetchAllServerPhotos(sync = true)
                val cur = settings.current
                store.savePhotos(fetched, cur.normalizedBaseUrl, cur.apiKeyCacheScope)
                val protectedSet = withContext(Dispatchers.IO) { computeLocallyProtectedHashes(fetched) }
                _uiState.update { prev ->
                    val rebuilt = rebuildTimelineData(fetched, prev.filterMode, prev.mediaTypeFilter, prev.timelineGrouping, prev.selectedYearAnchor)
                    val clearedFailed = prev.failedPreviewHashes.filterNot { h ->
                        fetched.any { it.hash == h && !it.needsProxy }
                    }.toSet()
                    prev.copy(
                        photos = fetched,
                        locallyProtectedHashes = protectedSet,
                        timeline = rebuilt.first,
                        selectedYearAnchor = rebuilt.second,
                        failedPreviewHashes = clearedFailed,
                        errorMessage = null,
                        isLoading = false
                    )
                }
                syncManager.startPrefetchIfNeeded(fetched)
            } catch (err: ApiHttpException) {
                if (err.statusCode == 401) {
                    syncManager.cancel()
                    settings.signOut()
                }
                _uiState.update { it.copy(errorMessage = err.message, isLoading = false) }
            } catch (err: Exception) {
                _uiState.update { it.copy(errorMessage = err.localizedMessage ?: "Offline", isLoading = false) }
            }
        }
    }

    fun setFilterMode(mode: ServerGalleryFilter) {
        _uiState.update { prev ->
            val rebuilt = rebuildTimelineData(prev.photos, mode, prev.mediaTypeFilter, prev.timelineGrouping, prev.selectedYearAnchor)
            prev.copy(filterMode = mode, timeline = rebuilt.first, selectedYearAnchor = rebuilt.second)
        }
    }

    fun setMediaTypeFilter(media: ServerMediaTypeFilter) {
        _uiState.update { prev ->
            val rebuilt = rebuildTimelineData(prev.photos, prev.filterMode, media, prev.timelineGrouping, prev.selectedYearAnchor)
            prev.copy(mediaTypeFilter = media, timeline = rebuilt.first, selectedYearAnchor = rebuilt.second)
        }
    }

    fun setTimelineGrouping(grouping: ServerTimelineGrouping) {
        _uiState.update { prev ->
            val rebuilt = rebuildTimelineData(prev.photos, prev.filterMode, prev.mediaTypeFilter, grouping, prev.selectedYearAnchor)
            prev.copy(timelineGrouping = grouping, timeline = rebuilt.first, selectedYearAnchor = rebuilt.second)
        }
    }

    fun selectYearAnchor(anchorId: String) {
        _uiState.update { it.copy(selectedYearAnchor = anchorId) }
    }

    private fun rebuildTimelineData(
        photos: List<ServerPhoto>,
        filterMode: ServerGalleryFilter,
        mediaTypeFilter: ServerMediaTypeFilter,
        grouping: ServerTimelineGrouping,
        existingAnchor: String?
    ): Pair<ServerTimelineData, String?> {
        val data = ServerTimelineBuilder.build(photos, filterMode, mediaTypeFilter, grouping)
        val nextAnchor = if (existingAnchor != null && data.years.any { it.anchorId == existingAnchor }) {
            existingAnchor
        } else {
            data.years.firstOrNull()?.anchorId
        }
        return data to nextAnchor
    }

    fun loadCompressedPreviewIfNeeded(photo: ServerPhoto) {
        if (_uiState.value.imageCache.containsKey(photo.hash) || !inFlightPreviews.add(photo.hash)) {
            return
        }
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val cached = store.previewData(photo.hash)
                if (cached != null) {
                    BitmapFactory.decodeByteArray(cached, 0, cached.size)?.let { bmp ->
                        withContext(Dispatchers.Main) {
                            _uiState.update { prev ->
                                prev.copy(
                                    imageCache = prev.imageCache + (photo.hash to bmp),
                                    failedPreviewHashes = prev.failedPreviewHashes - photo.hash
                                )
                            }
                        }
                        return@launch
                    }
                }

                if (photo.isVideo && photo.needsProxy) {
                    withContext(Dispatchers.Main) {
                        _uiState.update { prev ->
                            prev.copy(failedPreviewHashes = prev.failedPreviewHashes + photo.hash)
                        }
                    }
                    return@launch
                }

                val client = PhotoHubApiClient(context, settings)
                val raw = runCatching { client.downloadPhotoPreviewData(photo.hash) }.getOrNull()
                val compressed = raw?.let { store.cacheDownloadedPreview(it, photo.hash) }
                withContext(Dispatchers.Main) {
                    if (compressed != null) {
                        _uiState.update { prev ->
                            prev.copy(
                                imageCache = prev.imageCache + (photo.hash to compressed.first),
                                failedPreviewHashes = prev.failedPreviewHashes - photo.hash
                            )
                        }
                    } else {
                        _uiState.update { prev ->
                            prev.copy(failedPreviewHashes = prev.failedPreviewHashes + photo.hash)
                        }
                    }
                }
            } finally {
                inFlightPreviews.remove(photo.hash)
            }
        }
    }

    fun startBatchProxy() {
        val targets = _uiState.value.photos.filter { it.needsProxy }
        if (_uiState.value.isBatchProxying || _uiState.value.isBatchRestoring || targets.isEmpty()) return

        batchJob?.cancel()
        _uiState.update {
            it.copy(
                isBatchProxying = true,
                batchBannerMessage = null,
                batchCompleted = 0,
                batchTotal = targets.size,
                batchStatusText = "Preparing…"
            )
        }

        batchJob = viewModelScope.launch {
            val client = PhotoHubApiClient(context, settings)
            val queue = Channel<ServerPhoto>(Channel.UNLIMITED)
            targets.forEach { queue.trySend(it) }
            queue.close()

            val videoSem = Semaphore(1)
            val succeeded = AtomicInteger(0)
            val failed = AtomicInteger(0)
            val completed = AtomicInteger(0)

            try {
                coroutineScope {
                    val workerCount = minOf(3, targets.size)
                    val workers = List(workerCount) {
                        launch(Dispatchers.Default) {
                            for (item in queue) {
                                if (!isActive) break
                                try {
                                    val updated = if (item.isVideo) {
                                        videoSem.withPermit { client.createAndRegisterProxy(item) }
                                    } else {
                                        client.createAndRegisterProxy(item)
                                    }
                                    applyUpdatedPhoto(updated)
                                    succeeded.incrementAndGet()
                                } catch (_: Exception) {
                                    failed.incrementAndGet()
                                }
                                val done = completed.incrementAndGet()
                                _uiState.update {
                                    it.copy(batchCompleted = done, batchStatusText = item.originalName)
                                }
                            }
                        }
                    }
                    workers.joinAll()
                }
            } finally {
                val ok = succeeded.get()
                val errCount = failed.get()
                val cancelled = !isActive
                _uiState.update { prev ->
                    val nextFilter = if (prev.unproxiedCount == 0 && prev.filterMode == ServerGalleryFilter.NEEDS_PROXY) {
                        ServerGalleryFilter.ALL
                    } else {
                        prev.filterMode
                    }
                    val rebuilt = rebuildTimelineData(prev.photos, nextFilter, prev.mediaTypeFilter, prev.timelineGrouping, prev.selectedYearAnchor)
                    prev.copy(
                        isBatchProxying = false,
                        batchStatusText = "",
                        filterMode = nextFilter,
                        timeline = rebuilt.first,
                        selectedYearAnchor = rebuilt.second,
                        batchBannerMessage = when {
                            cancelled -> "Stopped after creating $ok proxy(s)."
                            errCount > 0 -> "Created $ok proxy(s); $errCount failed."
                            else -> "Created compressed proxies for all $ok item(s)."
                        }
                    )
                }
                if (ok > 0 && !cancelled) {
                    syncManager.startPrefetchIfNeeded(_uiState.value.photos)
                }
            }
        }
    }

    fun stopBatchProxy() {
        batchJob?.cancel()
    }

    fun dismissBatchBanner() {
        _uiState.update { it.copy(batchBannerMessage = null) }
    }

    fun applyUpdatedPhoto(updated: ServerPhoto) {
        viewModelScope.launch(Dispatchers.IO) {
            val previewBmp = store.previewData(updated.hash)?.let {
                BitmapFactory.decodeByteArray(it, 0, it.size)
            }
            val norm = normHash(updated.hash)
            val isLocProtected = tracker.isRestoredMasterHash(norm)
            withContext(Dispatchers.Main) {
                _uiState.update { prev ->
                    val nextPhotos = prev.photos.map {
                        if (it.hash.equals(updated.hash, ignoreCase = true)) updated else it
                    }
                    val nextCache = if (previewBmp != null) prev.imageCache + (updated.hash to previewBmp) else prev.imageCache
                    val nextLocallyProtected = if (isLocProtected) {
                        prev.locallyProtectedHashes + norm
                    } else {
                        prev.locallyProtectedHashes - norm
                    }
                    val rebuilt = rebuildTimelineData(nextPhotos, prev.filterMode, prev.mediaTypeFilter, prev.timelineGrouping, prev.selectedYearAnchor)
                    prev.copy(
                        photos = nextPhotos,
                        imageCache = nextCache,
                        locallyProtectedHashes = nextLocallyProtected,
                        failedPreviewHashes = prev.failedPreviewHashes - updated.hash,
                        timeline = rebuilt.first,
                        selectedYearAnchor = rebuilt.second
                    )
                }
            }
        }
    }

    fun resolvePickedGalleryUri(uri: Uri) {
        _uiState.update { it.copy(isResolvingPick = true, pickStatusText = "Matching selected item…") }
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val resolver = OriginalMediaResolver(context, settings)
                val fetched = resolver.resolveAndFetchOriginal(
                    uri = uri,
                    onStage = { stage ->
                        _uiState.update { it.copy(pickStatusText = stage) }
                    }
                )
                withContext(Dispatchers.Main) {
                    _uiState.update { it.copy(isResolvingPick = false, shareFileReady = fetched.file) }
                }
            } catch (err: Exception) {
                withContext(Dispatchers.Main) {
                    _uiState.update {
                        it.copy(
                            isResolvingPick = false,
                            pickerErrorMessage = err.localizedMessage ?: "Download failed."
                        )
                    }
                }
            }
        }
    }

    fun clearPickerError() {
        _uiState.update { it.copy(pickerErrorMessage = null) }
    }

    fun clearShareFileReady() {
        _uiState.update { it.copy(shareFileReady = null) }
    }

    // MARK: - Detail Modal Actions

    fun openPhotoDetail(photo: ServerPhoto) {
        val initialBmp = _uiState.value.imageCache[photo.hash]
        _detailState.value = PhotoDetailUiState(
            photo = photo,
            isLocallyProtected = tracker.isRestoredMasterHash(photo.hash),
            previewBitmap = initialBmp
        )
        speculativePrefetchJob?.cancel()

        viewModelScope.launch(Dispatchers.IO) {
            if (initialBmp == null && !(photo.isVideo && photo.needsProxy)) {
                val cached = store.previewData(photo.hash)?.let {
                    BitmapFactory.decodeByteArray(it, 0, it.size)
                }
                val bmp = cached ?: runCatching {
                    val raw = PhotoHubApiClient(context, settings).downloadPhotoPreviewData(photo.hash)
                    store.cacheDownloadedPreview(raw, photo.hash)?.first
                }.getOrNull()
                if (bmp != null) {
                    _detailState.update { it?.copy(previewBitmap = bmp) }
                }
            }

            if (photo.isVideo && !photo.needsProxy) {
                prepareDetailVideoProxy(photo)
            }
        }

        // Speculatively pre-fetch full-resolution originals for opened photos (<= 40 MB)
        // so tapping Share Original or Restore completes immediately, just like iCloud Photos.
        if (!photo.isVideo && photo.size in 1L..SPECULATIVE_PREFETCH_MAX_BYTES) {
            speculativePrefetchJob = viewModelScope.launch(Dispatchers.IO) {
                runCatching {
                    OriginalDownloadCache.getOrFetchOriginal(
                        context = context,
                        apiClient = PhotoHubApiClient(context, settings),
                        masterHash = photo.hash,
                        preferredFilename = photo.originalName,
                        expectedSizeBytes = photo.size
                    )
                }
            }
        }
    }

    fun closePhotoDetail() {
        speculativePrefetchJob?.cancel()
        speculativePrefetchJob = null
        _detailState.value = null
    }

    fun clearDetailShareFile() {
        _detailState.update { it?.copy(shareFileReady = null) }
    }

    private suspend fun prepareDetailVideoProxy(photo: ServerPhoto) {
        val existing = store.videoProxyFileIfExists(photo.hash)
        if (existing != null) {
            _detailState.update { it?.copy(videoFile = existing) }
            return
        }
        _detailState.update { it?.copy(isLoadingVideo = true) }
        try {
            val temp = PhotoHubApiClient(context, settings).downloadVideoProxyToTempFile(photo.hash)
            val saved = store.copyVideoProxy(temp, photo.hash)
            temp.delete()
            _detailState.update {
                it?.copy(videoFile = saved, isLoadingVideo = false)
            }
        } catch (_: Exception) {
            _detailState.update {
                it?.copy(
                    isLoadingVideo = false,
                    videoUnavailableNote = "No compressed video proxy on server yet. Tap Create Video Proxy below, or Share Original."
                )
            }
        }
    }

    fun createProxyForDetail() {
        val curDetail = _detailState.value ?: return
        val photo = curDetail.photo
        _detailState.update {
            it?.copy(
                isBusy = true,
                busyLabel = if (photo.isVideo) "Creating compressed MP4 video proxy…" else "Creating compressed proxy…",
                saveMessage = null,
                videoUnavailableNote = null
            )
        }
        viewModelScope.launch {
            try {
                val client = PhotoHubApiClient(context, settings)
                val updated = client.createAndRegisterProxy(photo)
                applyUpdatedPhoto(updated)
                val bmp = withContext(Dispatchers.IO) {
                    store.previewData(updated.hash)?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                }
                val vidFile = if (updated.isVideo) store.videoProxyFileIfExists(updated.hash) else null
                _detailState.update {
                    it?.copy(
                        photo = updated,
                        previewBitmap = bmp ?: it.previewBitmap,
                        videoFile = vidFile ?: it.videoFile,
                        isBusy = false,
                        busyLabel = "",
                        saveMessage = "Compressed proxy created and stored on server & local cache."
                    )
                }
            } catch (err: Exception) {
                _detailState.update {
                    it?.copy(
                        isBusy = false,
                        busyLabel = "",
                        saveMessage = "Proxy creation failed: ${err.localizedMessage}"
                    )
                }
            }
        }
    }

    fun shareOriginalFromDetail() {
        val photo = _detailState.value?.photo ?: return
        _detailState.update { it?.copy(isBusy = true, busyLabel = "Fetching full-resolution original…", saveMessage = null) }
        viewModelScope.launch {
            try {
                val (file, _) = OriginalDownloadCache.getOrFetchOriginal(
                    context = context,
                    apiClient = PhotoHubApiClient(context, settings),
                    masterHash = photo.hash,
                    preferredFilename = photo.originalName,
                    expectedSizeBytes = photo.size,
                    onProgress = { down, total ->
                        val label = formatDetailProgressLabel("Fetching original…", down, total)
                        _detailState.update { it?.copy(busyLabel = label) }
                    }
                )
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", shareFileReady = file)
                }
            } catch (err: Exception) {
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", saveMessage = "Share failed: ${err.localizedMessage}")
                }
            }
        }
    }

    fun saveProxyToGalleryFromDetail() {
        val curDetail = _detailState.value ?: return
        val photo = curDetail.photo
        _detailState.update { it?.copy(isBusy = true, busyLabel = "Saving proxy to Gallery…", saveMessage = null) }
        viewModelScope.launch {
            if (!mediaService.canWriteGallery()) {
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", saveMessage = "Photos & Videos permission is required.")
                }
                return@launch
            }
            if (tracker.liveProxyAssetId(photo.hash) != null) {
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", saveMessage = "Already saved in phone Gallery.")
                }
                return@launch
            }
            try {
                if (photo.isVideo) {
                    var videoFile = curDetail.videoFile ?: store.videoProxyFileIfExists(photo.hash)
                    var tempVid: File? = null
                    try {
                        if (videoFile == null && !photo.needsProxy) {
                            _detailState.update { it?.copy(busyLabel = "Downloading compressed MP4 proxy…") }
                            val dl = PhotoHubApiClient(context, settings).downloadVideoProxyToTempFile(photo.hash)
                            val cached = store.copyVideoProxy(dl, photo.hash)
                            if (cached != null) {
                                dl.delete()
                                videoFile = cached
                            } else {
                                tempVid = dl
                                videoFile = dl
                            }
                        }
                        if (videoFile != null) {
                            mediaService.saveServerProxyToGallery(photo, null, videoFile)
                            val sz = android.text.format.Formatter.formatFileSize(context, videoFile.length())
                            _detailState.update {
                                it?.copy(
                                    videoFile = videoFile,
                                    isBusy = false,
                                    busyLabel = "",
                                    saveMessage = "Saved compressed video proxy ($sz) to Gallery."
                                )
                            }
                            return@launch
                        }
                    } finally {
                        tempVid?.delete()
                    }
                }

                var imgData = store.previewData(photo.hash)
                if (imgData == null) {
                    _detailState.update { it?.copy(busyLabel = "Downloading compressed preview…") }
                    val raw = PhotoHubApiClient(context, settings).downloadPhotoPreviewData(photo.hash)
                    imgData = store.cacheDownloadedPreviewData(raw, photo.hash)
                }
                if (imgData == null) {
                    _detailState.update {
                        it?.copy(isBusy = false, busyLabel = "", saveMessage = "Preview not available yet.")
                    }
                    return@launch
                }
                mediaService.saveServerProxyToGallery(photo, imgData, null)
                val sz = android.text.format.Formatter.formatFileSize(context, imgData.size.toLong())
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", saveMessage = "Saved compressed proxy ($sz) to Gallery.")
                }
            } catch (err: Exception) {
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", saveMessage = "Failed: ${err.localizedMessage}")
                }
            }
        }
    }

    // MARK: - Selection & Batch / Restore All Actions

    fun canWriteGallery(): Boolean = mediaService.canWriteGallery()

    fun reportRestorePermissionDenied() {
        _uiState.update {
            it.copy(restoreBannerMessage = "Photos & Videos permission is required to save originals to Gallery.")
        }
    }

    fun enterSelectionMode(initialHash: String? = null) {
        val prev = _uiState.value
        if (prev.isBatchRestoring || prev.isBatchProxying || prev.photos.isEmpty()) return
        val initial = initialHash?.let(::normHash)?.takeIf { it.isNotEmpty() }
        _uiState.update {
            it.copy(
                isSelectionMode = true,
                selectedHashes = if (initial != null) setOf(initial) else emptySet()
            )
        }
    }

    fun exitSelectionMode() {
        _uiState.update { it.copy(isSelectionMode = false, selectedHashes = emptySet()) }
    }

    fun togglePhotoSelection(hash: String) {
        val norm = normHash(hash)
        if (norm.isEmpty()) return
        _uiState.update { prev ->
            val next = if (norm in prev.selectedHashes) {
                prev.selectedHashes - norm
            } else {
                prev.selectedHashes + norm
            }
            prev.copy(selectedHashes = next)
        }
    }

    fun selectAllVisible() {
        _uiState.update { prev ->
            prev.copy(selectedHashes = prev.visiblePhotos.map { normHash(it.hash) }.toSet())
        }
    }

    fun clearSelection() {
        _uiState.update { it.copy(selectedHashes = emptySet()) }
    }

    fun toggleSectionSelection(sectionPhotos: List<ServerPhoto>) {
        if (sectionPhotos.isEmpty()) return
        val sectionHashes = sectionPhotos.map { normHash(it.hash) }.toSet()
        _uiState.update { prev ->
            val allSelected = sectionHashes.all { it in prev.selectedHashes }
            val next = if (allSelected) {
                prev.selectedHashes - sectionHashes
            } else {
                prev.selectedHashes + sectionHashes
            }
            prev.copy(selectedHashes = next)
        }
    }

    fun requestRestoreAll() {
        val state = _uiState.value
        if (state.isBatchRestoring || state.isBatchProxying || state.photos.isEmpty()) return
        openRestoreConfirm(
            title = "Restore All Originals",
            targets = state.photos,
            isRestoreAll = true
        )
    }

    fun requestRestoreSelected() {
        val state = _uiState.value
        if (state.isBatchRestoring || state.isBatchProxying || state.selectedHashes.isEmpty()) return
        val targets = state.photos.filter { normHash(it.hash) in state.selectedHashes }
        if (targets.isEmpty()) return
        openRestoreConfirm(
            title = "Restore Selected Originals",
            targets = targets,
            isRestoreAll = false
        )
    }

    private fun openRestoreConfirm(
        title: String,
        targets: List<ServerPhoto>,
        isRestoreAll: Boolean
    ) {
        val protectedSet = computeLocallyProtectedHashes(targets)
        val req = BatchRestorePlanner.buildConfirmRequest(
            title = title,
            targets = targets,
            locallyProtectedHashes = protectedSet,
            isRestoreAll = isRestoreAll
        )
        _uiState.update { it.copy(restoreConfirmRequest = req) }
    }

    fun dismissRestoreConfirm() {
        _uiState.update { it.copy(restoreConfirmRequest = null) }
    }

    fun executeRestoreConfirm(includeAlreadyRestored: Boolean = false) {
        val req = _uiState.value.restoreConfirmRequest ?: return
        _uiState.update { it.copy(restoreConfirmRequest = null) }
        val targets = BatchRestorePlanner.resolveExecutionTargets(req, includeAlreadyRestored)
        startBatchRestore(targets = targets, exitSelectionAfter = !req.isRestoreAll)
    }

    private fun startBatchRestore(
        targets: List<ServerPhoto>,
        exitSelectionAfter: Boolean
    ) {
        val curState = _uiState.value
        if (curState.isBatchRestoring || curState.isBatchProxying || targets.isEmpty()) return
        if (!mediaService.canWriteGallery()) {
            reportRestorePermissionDenied()
            return
        }

        restoreJob?.cancel()
        _uiState.update {
            it.copy(
                isBatchRestoring = true,
                restoreBannerMessage = null,
                restoreCompleted = 0,
                restoreTotal = targets.size,
                restoreStatusText = "Preparing…",
                isSelectionMode = if (exitSelectionAfter) false else it.isSelectionMode,
                selectedHashes = if (exitSelectionAfter) emptySet() else it.selectedHashes
            )
        }

        restoreJob = viewModelScope.launch {
            val client = PhotoHubApiClient(context, settings)
            val queue = Channel<ServerPhoto>(Channel.UNLIMITED)
            targets.forEach { queue.trySend(it) }
            queue.close()

            val succeeded = AtomicInteger(0)
            val failed = AtomicInteger(0)
            val completed = AtomicInteger(0)

            try {
                coroutineScope {
                    val workerCount = minOf(3, targets.size)
                    val workers = List(workerCount) {
                        launch(Dispatchers.IO) {
                            for (item in queue) {
                                if (!isActive) break
                                try {
                                    restoreSinglePhotoToGallery(client, item)
                                    succeeded.incrementAndGet()
                                } catch (c: CancellationException) {
                                    throw c
                                } catch (_: Exception) {
                                    failed.incrementAndGet()
                                }
                                val done = completed.incrementAndGet()
                                _uiState.update {
                                    it.copy(restoreCompleted = done, restoreStatusText = item.originalName)
                                }
                            }
                        }
                    }
                    workers.joinAll()
                }
            } finally {
                val ok = succeeded.get()
                val errCount = failed.get()
                val cancelled = !isActive
                val protectedSet = withContext(NonCancellable + Dispatchers.IO) {
                    computeLocallyProtectedHashes(_uiState.value.photos)
                }
                _uiState.update { prev ->
                    prev.copy(
                        isBatchRestoring = false,
                        restoreStatusText = "",
                        locallyProtectedHashes = protectedSet,
                        restoreBannerMessage = when {
                            cancelled -> "Stopped after restoring $ok original(s)."
                            errCount > 0 && ok == 0 -> "Restore failed for $errCount item(s)."
                            errCount > 0 -> "Restored $ok original(s) & protected them; $errCount failed."
                            else -> "Restored $ok original(s) to Gallery & protected them."
                        }
                    )
                }
            }
        }
    }

    fun stopBatchRestore() {
        restoreJob?.cancel()
    }

    fun dismissRestoreBanner() {
        _uiState.update { it.copy(restoreBannerMessage = null) }
    }

    private suspend fun restoreSinglePhotoToGallery(
        client: PhotoHubApiClient,
        photo: ServerPhoto,
        onProgress: ((Long, Long?) -> Unit)? = null
    ): Pair<ServerPhoto?, Long> {
        val (originalFile, _) = OriginalDownloadCache.getOrFetchOriginal(
            context = context,
            apiClient = client,
            masterHash = photo.hash,
            preferredFilename = photo.originalName,
            expectedSizeBytes = photo.size,
            onProgress = onProgress
        )
        val fileSize = originalFile.length()
        val savedId = mediaService.saveRestoredOriginalToGallery(
            file = originalFile,
            isVideo = photo.isVideo,
            originalFilename = photo.originalName,
            creationDateMs = photo.parsedCreationDateMs
        )
        tracker.markRestoredOriginal(savedId, photo.hash)
        val updated = runCatching { client.setOriginalProtected(photo.hash, true) }.getOrNull()
        if (updated != null) {
            applyUpdatedPhoto(updated)
        }
        return updated to fileSize
    }

    fun restoreFullMasterFromDetail() {
        val photo = _detailState.value?.photo ?: return
        _detailState.update { it?.copy(isBusy = true, busyLabel = "Downloading full-resolution original…", saveMessage = null) }
        viewModelScope.launch {
            if (!mediaService.canWriteGallery()) {
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", saveMessage = "Photos & Videos permission is required.")
                }
                return@launch
            }
            val client = PhotoHubApiClient(context, settings)
            try {
                val (updated, fileSize) = restoreSinglePhotoToGallery(
                    client = client,
                    photo = photo,
                    onProgress = { down, total ->
                        val label = formatDetailProgressLabel("Downloading original…", down, total)
                        _detailState.update { it?.copy(busyLabel = label) }
                    }
                )
                refreshProtectedHashes()
                val sz = android.text.format.Formatter.formatFileSize(context, fileSize)
                _detailState.update {
                    it?.copy(
                        photo = updated ?: it.photo,
                        isLocallyProtected = true,
                        isBusy = false,
                        busyLabel = "",
                        saveMessage = "Restored original ($sz) to Gallery & protected it from re-proxying."
                    )
                }
            } catch (err: Exception) {
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", saveMessage = "Restore failed: ${err.localizedMessage}")
                }
            }
        }
    }

    private fun formatDetailProgressLabel(prefix: String, downloaded: Long, total: Long?): String {
        if (downloaded <= 0L && total == null) return prefix
        val downStr = android.text.format.Formatter.formatFileSize(context, downloaded)
        return if (total != null && total > 0L) {
            val totalStr = android.text.format.Formatter.formatFileSize(context, total)
            "$prefix ($downStr / $totalStr)"
        } else {
            "$prefix ($downStr)"
        }
    }

    companion object {
        private const val SPECULATIVE_PREFETCH_MAX_BYTES = 40L * 1024L * 1024L
    }

    fun updateOriginalProtection(protected: Boolean) {
        val photo = _detailState.value?.photo ?: return
        _detailState.update {
            it?.copy(
                isBusy = true,
                busyLabel = if (protected) "Protecting original…" else "Allowing re-proxy…",
                saveMessage = null
            )
        }
        viewModelScope.launch {
            if (!protected) tracker.clearRestoredProtection(photo.hash)
            try {
                val updated = PhotoHubApiClient(context, settings).setOriginalProtected(photo.hash, protected)
                applyUpdatedPhoto(updated)
                _detailState.update {
                    it?.copy(
                        photo = updated,
                        isLocallyProtected = protected || tracker.isRestoredMasterHash(updated.hash),
                        isBusy = false,
                        busyLabel = "",
                        saveMessage = if (protected) {
                            "Protected: this original won't be auto re-proxied."
                        } else {
                            "Unlocked: this photo can be compressed into a proxy again."
                        }
                    )
                }
            } catch (err: Exception) {
                _detailState.update {
                    it?.copy(
                        isBusy = false,
                        busyLabel = "",
                        saveMessage = "Failed to update protection: ${err.localizedMessage}"
                    )
                }
            }
        }
    }
}
