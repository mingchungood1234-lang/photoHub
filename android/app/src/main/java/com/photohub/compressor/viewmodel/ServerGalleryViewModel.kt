package com.photohub.compressor.viewmodel

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.MediaStore
import android.util.LruCache
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.photohub.compressor.background.BackgroundBackupManager
import com.photohub.compressor.data.*
import com.photohub.compressor.media.MediaLibraryService
import com.photohub.compressor.media.OrderedCommitGate
import com.photohub.compressor.media.OriginalDownloadCache
import com.photohub.compressor.media.OriginalMediaResolver
import com.photohub.compressor.media.PhotoBackupPipeline
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
    ALL("All"),
    PHOTOS("Photos"),
    VIDEOS("Videos"),
    FAVORITES("Favorites"),
    PROTECTED("Protected"),
    TRASH("Trash")
}

enum class ServerTimelineGrouping(val title: String, val shortLabel: String) {
    DAY("Date & Year", "Day"),
    MONTH("Month & Year", "Month"),
    YEAR("Year Only", "Year")
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
    private val monthKeywords = listOf(
        "january jan", "february feb", "march mar", "april apr",
        "may", "june jun", "july jul", "august aug",
        "september sept sep", "october oct", "november nov", "december dec"
    )

    private fun matchesSmartQuery(photo: ServerPhoto, tokens: List<String>): Boolean {
        val dateStr = photo.photoDate.ifBlank { photo.takenAt?.take(10).orEmpty() }
        val monthIdx = if (dateStr.length >= 7 && dateStr[4] == '-') {
            dateStr.substring(5, 7).toIntOrNull()?.minus(1) ?: -1
        } else {
            -1
        }
        val monthWords = if (monthIdx in monthKeywords.indices) monthKeywords[monthIdx] else ""
        val hay = buildString {
            append(photo.originalName).append(' ')
            append(photo.photoDate).append(' ')
            append(photo.takenAt.orEmpty()).append(' ')
            append(photo.savedPath).append(' ')
            append(photo.cameraModel.orEmpty()).append(' ')
            append(monthWords).append(' ')
            append(if (photo.isVideo) "video videos movie clip" else "photo photos image picture").append(' ')
            if (photo.isFavorited) append("favorite favorites fav heart ").append(' ')
            if (photo.isProtectedOriginal) append("protected restored original")
        }.lowercase(Locale.ROOT)
        return tokens.all { hay.contains(it) }
    }

    fun build(
        photos: List<ServerPhoto>,
        filterMode: ServerGalleryFilter,
        mediaTypeFilter: ServerMediaTypeFilter,
        grouping: ServerTimelineGrouping,
        searchQuery: String = "",
        locallyProtectedHashes: Set<String> = emptySet(),
        nowMs: Long = System.currentTimeMillis()
    ): ServerTimelineData {
        val queryTokens = searchQuery.trim().lowercase(Locale.ROOT).split(Regex("\\s+")).filter { it.isNotEmpty() }
        val filtered = photos.filter { photo ->
            if (mediaTypeFilter != ServerMediaTypeFilter.TRASH && filterMode == ServerGalleryFilter.NEEDS_PROXY && !photo.needsProxy) {
                return@filter false
            }
            val passesMedia = when (mediaTypeFilter) {
                ServerMediaTypeFilter.ALL -> true
                ServerMediaTypeFilter.PHOTOS -> !photo.isVideo
                ServerMediaTypeFilter.VIDEOS -> photo.isVideo
                ServerMediaTypeFilter.FAVORITES -> photo.isFavorited
                ServerMediaTypeFilter.PROTECTED ->
                    photo.isProtectedOriginal || locallyProtectedHashes.contains(photo.hash.lowercase(Locale.ROOT))
                ServerMediaTypeFilter.TRASH -> true
            }
            if (!passesMedia) return@filter false
            if (queryTokens.isNotEmpty() && !matchesSmartQuery(photo, queryTokens)) return@filter false
            true
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

object DeviceStorageHelper {
    const val MINIMUM_HEADROOM_BYTES: Long = 512L * 1024L * 1024L // 512 MB

    fun availableBytes(): Long? = runCatching {
        val stat = android.os.StatFs(android.os.Environment.getDataDirectory().path)
        stat.availableBytes.takeIf { it > 0L }
    }.getOrNull()
}

data class BatchRestoreConfirmRequest(
    val title: String,
    val allTargets: List<ServerPhoto>,
    val unrestoredTargets: List<ServerPhoto>,
    val skippedCount: Int,
    val unrestoredBytes: Long,
    val allBytes: Long,
    val isRestoreAll: Boolean,
    val leftoverProxyHashes: Set<String> = emptySet(),
    val leftoverProxyCount: Int = 0,
    val deviceAvailableBytes: Long? = null,
    val willDisableAutoBackup: Boolean = false
) {
    val hasEnoughStorageForUnrestored: Boolean
        get() {
            val free = deviceAvailableBytes ?: return true
            if (unrestoredBytes <= 0L) return true
            return free >= unrestoredBytes + DeviceStorageHelper.MINIMUM_HEADROOM_BYTES
        }

    val hasEnoughStorageForAll: Boolean
        get() {
            val free = deviceAvailableBytes ?: return true
            if (allBytes <= 0L) return true
            return free >= allBytes + DeviceStorageHelper.MINIMUM_HEADROOM_BYTES
        }
}

object BatchRestorePlanner {
    fun buildConfirmRequest(
        title: String,
        targets: List<ServerPhoto>,
        locallyProtectedHashes: Set<String>,
        isRestoreAll: Boolean,
        leftoverProxyHashes: Set<String> = emptySet(),
        leftoverProxyCount: Int = 0,
        deviceAvailableBytes: Long? = DeviceStorageHelper.availableBytes(),
        willDisableAutoBackup: Boolean = false
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
            isRestoreAll = isRestoreAll,
            leftoverProxyHashes = leftoverProxyHashes,
            leftoverProxyCount = leftoverProxyCount.coerceAtLeast(0),
            deviceAvailableBytes = deviceAvailableBytes,
            willDisableAutoBackup = willDisableAutoBackup
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

data class BatchRestoreProgress(
    val completed: Int,
    val total: Int,
    val currentName: String,
    val updatedPhoto: ServerPhoto?
)

data class BatchRestoreResult(
    val succeeded: Int,
    val failed: Int,
    val cancelled: Boolean,
    val deletedProxyCount: Int = 0,
    val proxyDeletePending: com.photohub.compressor.media.CompressedProxyDeleteResult.NeedsSystemConfirmation? = null,
    val summaryMessage: String
)

object BatchRestoreExecutor {
    suspend fun restoreSinglePhotoToGallery(
        context: android.content.Context,
        client: PhotoHubApiClient,
        mediaService: MediaLibraryService,
        tracker: LocalProxyTracker,
        photo: ServerPhoto,
        commitGate: OrderedCommitGate? = null,
        commitIndex: Int? = null,
        onProgress: ((Long, Long?) -> Unit)? = null
    ): Pair<ServerPhoto?, Long> {
        var didCompleteTurn = false
        suspend fun releaseTurnIfNeeded() {
            if (!didCompleteTurn && commitGate != null && commitIndex != null) {
                didCompleteTurn = true
                commitGate.completeTurn(commitIndex)
            }
        }
        try {
            // Strict duplicate guard: if the full-resolution original ALREADY exists in Gallery,
            // link and protect it without writing a duplicate copy into MediaStore.
            val existingOrigUri = withContext(Dispatchers.IO) {
                mediaService.findExistingLiveOriginalUri(photo, tracker)
            }
            if (existingOrigUri != null) {
                releaseTurnIfNeeded()
                tracker.markRestoredOriginal(existingOrigUri, photo.hash)
                val updated = runCatching { client.setOriginalProtected(photo.hash, true) }.getOrNull()
                return updated to photo.size.coerceAtLeast(0L)
            }

            val (originalFile, _) = OriginalDownloadCache.getOrFetchOriginal(
                context = context,
                apiClient = client,
                masterHash = photo.hash,
                preferredFilename = photo.originalName,
                expectedSizeBytes = photo.size,
                onProgress = onProgress
            )
            val fileSize = originalFile.length()
            if (commitGate != null && commitIndex != null) {
                val canCommit = commitGate.waitForTurn(commitIndex)
                if (!canCommit) {
                    throw CancellationException("Ordered restore commit cancelled")
                }
            }
            val bgManager = BackgroundBackupManager.getInstance(context)
            val wasAlreadyRestored = tracker.isRestoredMasterHash(photo.hash)
            bgManager.beginRestorePause()
            // Pre-mark master hash before writing into MediaStore to eliminate any race window.
            tracker.markRestoredOriginal(null, photo.hash)
            val savedId = try {
                val id = mediaService.saveRestoredOriginalToGallery(
                    file = originalFile,
                    isVideo = photo.isVideo,
                    originalFilename = photo.originalName,
                    creationDateMs = photo.parsedCreationDateMs
                )
                tracker.markRestoredOriginal(id, photo.hash)
                id
            } catch (err: Exception) {
                if (!wasAlreadyRestored) {
                    tracker.clearRestoredProtection(photo.hash)
                }
                throw err
            } finally {
                releaseTurnIfNeeded()
                bgManager.endRestorePause()
            }
            val updated = runCatching { client.setOriginalProtected(photo.hash, true) }.getOrNull()
            return updated to fileSize
        } finally {
            releaseTurnIfNeeded()
        }
    }

    suspend fun runBatchRestore(
        context: android.content.Context,
        client: PhotoHubApiClient,
        mediaService: MediaLibraryService,
        tracker: LocalProxyTracker,
        targets: List<ServerPhoto>,
        deleteCompressedProxies: Boolean = false,
        additionalProxyCleanupHashes: Set<String> = emptySet(),
        autoBackupDisabled: Boolean = false,
        onPhaseChange: ((String) -> Unit)? = null,
        onItemComplete: (BatchRestoreProgress) -> Unit,
        onFinished: suspend (BatchRestoreResult) -> Unit
    ) {
        val bgManager = BackgroundBackupManager.getInstance(context)
        bgManager.beginRestorePause()
        // Insert restored originals chronologically oldest-first and newest LAST so third-party
        // share pickers (WhatsApp, Telegram, Instagram, Android Photo Picker) show the newest photo first.
        val orderedTargets = PhotoBackupPipeline.sortServerPhotosOldestFirst(targets)
        val queue = Channel<Pair<Int, ServerPhoto>>(Channel.UNLIMITED)
        orderedTargets.forEachIndexed { idx, photo -> queue.trySend(idx to photo) }
        queue.close()
        val commitGate = OrderedCommitGate()

        val succeeded = AtomicInteger(0)
        val failed = AtomicInteger(0)
        val completed = AtomicInteger(0)
        val lowStorageHit = java.util.concurrent.atomic.AtomicBoolean(false)
        val succeededHashes = java.util.Collections.synchronizedList(mutableListOf<String>())
        var cancelled = false

        try {
            coroutineScope {
                val workerCount = minOf(3, orderedTargets.size)
                val workers = List(workerCount) {
                    launch(Dispatchers.IO) {
                        for ((workIndex, item) in queue) {
                            if (!isActive || lowStorageHit.get()) {
                                commitGate.completeTurn(workIndex)
                                break
                            }
                            val freeBytes = DeviceStorageHelper.availableBytes()
                            val neededBytes = maxOf(250L * 1024L * 1024L, maxOf(0L, item.size) + 150L * 1024L * 1024L)
                            if (freeBytes != null && freeBytes < neededBytes) {
                                lowStorageHit.set(true)
                                commitGate.cancelAll()
                                break
                            }
                            var updatedPhoto: ServerPhoto? = null
                            try {
                                updatedPhoto = restoreSinglePhotoToGallery(
                                    context = context,
                                    client = client,
                                    mediaService = mediaService,
                                    tracker = tracker,
                                    photo = item,
                                    commitGate = commitGate,
                                    commitIndex = workIndex
                                ).first
                                succeeded.incrementAndGet()
                                succeededHashes.add(item.hash)
                            } catch (c: CancellationException) {
                                commitGate.cancelAll()
                                throw c
                            } catch (_: Exception) {
                                commitGate.completeTurn(workIndex)
                                failed.incrementAndGet()
                            }
                            val done = completed.incrementAndGet()
                            onItemComplete(
                                BatchRestoreProgress(
                                    completed = done,
                                    total = orderedTargets.size,
                                    currentName = item.originalName,
                                    updatedPhoto = updatedPhoto
                                )
                            )
                        }
                    }
                }
                workers.joinAll()
            }
        } catch (c: CancellationException) {
            cancelled = true
            commitGate.cancelAll()
            throw c
        } finally {
            commitGate.cancelAll()
            val ok = succeeded.get()
            val errCount = failed.get()
            val stoppedLowStorage = lowStorageHit.get()
            var deletedProxyCount = 0
            var pendingPrompt: com.photohub.compressor.media.CompressedProxyDeleteResult.NeedsSystemConfirmation? = null

            withContext(NonCancellable) {
                if (deleteCompressedProxies) {
                    val cleanupHashes = succeededHashes
                        .map { it.trim().lowercase(Locale.ROOT) }
                        .filter { it.isNotEmpty() }
                        .toMutableSet()
                    if (!cancelled && !stoppedLowStorage) {
                        additionalProxyCleanupHashes
                            .map { it.trim().lowercase(Locale.ROOT) }
                            .filter { it.isNotEmpty() }
                            .let { cleanupHashes.addAll(it) }
                    }
                    if (cleanupHashes.isNotEmpty()) {
                        onPhaseChange?.invoke("Deleting compressed copies…")
                        val proxyIds = mediaService.findCompressedProxyAssetIds(tracker, cleanupHashes)
                        if (proxyIds.isNotEmpty()) {
                            when (val delRes = mediaService.deleteCompressedProxiesAfterRestore(tracker, proxyIds)) {
                                is com.photohub.compressor.media.CompressedProxyDeleteResult.Deleted -> {
                                    deletedProxyCount = delRes.deletedIds.size
                                }
                                is com.photohub.compressor.media.CompressedProxyDeleteResult.NeedsSystemConfirmation -> {
                                    deletedProxyCount = delRes.alreadyDeletedIds.size
                                    if (!cancelled) {
                                        pendingPrompt = delRes
                                    }
                                }
                            }
                        }
                    }
                }

                val msg = if (stoppedLowStorage) {
                    val proxyNote = if (deletedProxyCount > 0) " · Deleted $deletedProxyCount proxies" else ""
                    val autoNote = if (autoBackupDisabled) " · Auto Backup off" else ""
                    "Stopped: low phone storage (restored $ok$proxyNote)$autoNote."
                } else {
                    formatSummaryMessage(
                        ok = ok,
                        errCount = errCount,
                        cancelled = cancelled,
                        deletedProxyCount = deletedProxyCount,
                        awaitingDeleteConfirm = pendingPrompt != null,
                        autoBackupDisabled = autoBackupDisabled
                    )
                }
                bgManager.endRestorePause()
                onFinished(
                    BatchRestoreResult(
                        succeeded = ok,
                        failed = errCount,
                        cancelled = cancelled || stoppedLowStorage,
                        deletedProxyCount = deletedProxyCount,
                        proxyDeletePending = pendingPrompt,
                        summaryMessage = msg
                    )
                )
            }
        }
    }

    fun formatSummaryMessage(
        ok: Int,
        errCount: Int,
        cancelled: Boolean,
        deletedProxyCount: Int = 0,
        awaitingDeleteConfirm: Boolean = false,
        autoBackupDisabled: Boolean = false
    ): String {
        val proxyNote = when {
            awaitingDeleteConfirm && deletedProxyCount > 0 ->
                ", deleted $deletedProxyCount compressed copy(s), awaiting system confirm for remaining"
            awaitingDeleteConfirm ->
                "; confirm system prompt to delete compressed copies"
            deletedProxyCount > 0 ->
                " and deleted $deletedProxyCount compressed copy(s)"
            else -> ""
        }
        val base = when {
            cancelled -> "Stopped after restoring $ok original(s)$proxyNote."
            errCount > 0 && ok == 0 -> "Restore failed for $errCount item(s)."
            errCount > 0 -> "Restored $ok original(s) & protected them$proxyNote; $errCount failed."
            else -> "Restored $ok original(s) to Gallery & protected them$proxyNote."
        }
        return if (autoBackupDisabled) {
            "${base.removeSuffix(".")} · Auto Backup off."
        } else {
            base
        }
    }
}

data class ServerGalleryUiState(
    val photos: List<ServerPhoto> = emptyList(),
    val trashPhotos: List<ServerPhoto> = emptyList(),
    val trashCount: Int = 0,
    val trashBytes: Long = 0L,
    val isLoadingTrash: Boolean = false,
    val timeline: ServerTimelineData = ServerTimelineData(),
    val thumbnailCacheVersion: Long = 0L,
    val failedPreviewHashes: Set<String> = emptySet(),
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
    val filterMode: ServerGalleryFilter = ServerGalleryFilter.ALL,
    val mediaTypeFilter: ServerMediaTypeFilter = ServerMediaTypeFilter.ALL,
    val timelineGrouping: ServerTimelineGrouping = ServerTimelineGrouping.DAY,
    val searchQuery: String = "",
    val selectedYearAnchor: String? = null,
    val userName: String = "",
    val serverStorage: ServerStorageInfo? = null,
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
    val isBatchDeleting: Boolean = false,
    val deleteBannerMessage: String? = null,
    val deleteConfirmTargets: List<ServerPhoto>? = null,
    val deleteConfirmIsPermanent: Boolean = false,
    val isResolvingPick: Boolean = false,
    val pickStatusText: String = "Preparing original…",
    val pickerErrorMessage: String? = null,
    val shareFileReady: File? = null
) {
    val isViewingTrash: Boolean get() = mediaTypeFilter == ServerMediaTypeFilter.TRASH
    val activeSourcePhotos: List<ServerPhoto> get() = if (isViewingTrash) trashPhotos else photos
    val unproxiedCount: Int get() = photos.count { it.needsProxy }
    val videoCount: Int get() = photos.count { it.isVideo }
    val photoCount: Int get() = (photos.size - videoCount).coerceAtLeast(0)
    val favoriteCount: Int get() = photos.count { it.isFavorited }
    val protectedCount: Int get() = photos.count { isRestoredOrProtected(it) }
    val totalServerBytes: Long get() = photos.sumOf { maxOf(0L, it.size) }
    val hasActiveFilter: Boolean
        get() = filterMode != ServerGalleryFilter.ALL ||
            mediaTypeFilter != ServerMediaTypeFilter.ALL ||
            searchQuery.trim().isNotEmpty()
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
    val videoUri: Uri? = null,
    val isLoadingVideo: Boolean = false,
    val videoUnavailableNote: String? = null,
    val isBusy: Boolean = false,
    val busyLabel: String = "",
    val saveMessage: String? = null,
    val shareFileReady: File? = null,
    val createdShareLink: ShareLinkResult? = null
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

    // Bounded LRU thumbnail cache (max 1/8 JVM heap, capped at 48 MB) to prevent OOM on large libraries.
    private val thumbnailLruCache: LruCache<String, Bitmap> = run {
        val maxKb = (Runtime.getRuntime().maxMemory() / 1024L).toInt()
        val cacheKb = minOf(maxKb / 8, 48 * 1024).coerceAtLeast(8 * 1024)
        object : LruCache<String, Bitmap>(cacheKb) {
            override fun sizeOf(key: String, value: Bitmap): Int =
                (value.allocationByteCount / 1024).coerceAtLeast(1)
        }
    }

    fun getCachedThumbnail(hash: String): Bitmap? = thumbnailLruCache.get(hash.lowercase(Locale.ROOT))

    private fun putCachedThumbnail(hash: String, bmp: Bitmap) {
        thumbnailLruCache.put(hash.lowercase(Locale.ROOT), bmp)
    }

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
        viewModelScope.launch {
            settings.state.collect { cfg ->
                _uiState.update { prev ->
                    prev.copy(
                        userName = cfg.userName,
                        serverStorage = cfg.serverStorage
                    )
                }
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
            // Grid thumbnails are decoded lazily per visible tile into thumbnailLruCache (48 MB cap),
            // avoiding decoding all library bitmaps into RAM at startup.
            val protectedSet = computeLocallyProtectedHashes(cached)
            withContext(Dispatchers.Main) {
                _uiState.update { prev ->
                    val nextPhotos = if (cached.isNotEmpty() || prev.photos.isEmpty()) cached else prev.photos
                    val nextProtected = if (nextPhotos === cached) protectedSet else computeLocallyProtectedHashes(nextPhotos)
                    val rebuilt = rebuildTimelineData(
                        nextPhotos,
                        prev.filterMode,
                        prev.mediaTypeFilter,
                        prev.timelineGrouping,
                        prev.selectedYearAnchor,
                        prev.searchQuery,
                        nextProtected
                    )
                    prev.copy(
                        photos = nextPhotos,
                        thumbnailCacheVersion = prev.thumbnailCacheVersion + 1L,
                        locallyProtectedHashes = nextProtected,
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
            val whoamiDeferred = async { runCatching { client.whoami() }.getOrNull() }
            try {
                var latestTrashCount = _uiState.value.trashCount
                val fetched = client.fetchAllServerPhotos(sync = true) { partial, trashCount ->
                    latestTrashCount = trashCount
                    if (partial.size >= 300) {
                        _uiState.update { prev ->
                            val source = if (prev.isViewingTrash) prev.trashPhotos else partial
                            val rebuilt = rebuildTimelineData(
                                source,
                                prev.filterMode,
                                prev.mediaTypeFilter,
                                prev.timelineGrouping,
                                prev.selectedYearAnchor,
                                prev.searchQuery,
                                prev.locallyProtectedHashes
                            )
                            prev.copy(
                                photos = partial,
                                trashCount = trashCount,
                                timeline = rebuilt.first,
                                selectedYearAnchor = rebuilt.second
                            )
                        }
                    }
                }
                val cur = settings.current
                store.savePhotos(fetched, cur.normalizedBaseUrl, cur.apiKeyCacheScope)
                val protectedSet = withContext(Dispatchers.IO) {
                    mediaService.reconcileExistingNativeGalleryAssets(fetched)
                    computeLocallyProtectedHashes(fetched)
                }
                whoamiDeferred.await()?.let { who ->
                    settings.updateServerCapabilities(who.storage, who.s3Enabled)
                    settings.updateResolvedNode(
                        serverUrl = "",
                        nodeId = who.nodeId,
                        folderName = who.userFolder,
                        email = who.email,
                        name = who.name
                    )
                }
                _uiState.update { prev ->
                    val source = if (prev.isViewingTrash) prev.trashPhotos else fetched
                    val rebuilt = rebuildTimelineData(
                        source,
                        prev.filterMode,
                        prev.mediaTypeFilter,
                        prev.timelineGrouping,
                        prev.selectedYearAnchor,
                        prev.searchQuery,
                        protectedSet
                    )
                    val clearedFailed = prev.failedPreviewHashes.filterNot { h ->
                        fetched.any { it.hash == h && !it.needsProxy } || tracker.hasAnyLiveGalleryAsset(h)
                    }.toSet()
                    prev.copy(
                        photos = fetched,
                        trashCount = latestTrashCount,
                        thumbnailCacheVersion = prev.thumbnailCacheVersion + 1L,
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
            val rebuilt = rebuildTimelineData(
                prev.photos,
                mode,
                prev.mediaTypeFilter,
                prev.timelineGrouping,
                prev.selectedYearAnchor,
                prev.searchQuery,
                prev.locallyProtectedHashes
            )
            prev.copy(filterMode = mode, timeline = rebuilt.first, selectedYearAnchor = rebuilt.second)
        }
    }

    fun setMediaTypeFilter(media: ServerMediaTypeFilter) {
        _uiState.update { prev ->
            val source = if (media == ServerMediaTypeFilter.TRASH) prev.trashPhotos else prev.photos
            val rebuilt = rebuildTimelineData(
                source,
                prev.filterMode,
                media,
                prev.timelineGrouping,
                prev.selectedYearAnchor,
                prev.searchQuery,
                prev.locallyProtectedHashes
            )
            prev.copy(
                mediaTypeFilter = media,
                selectedHashes = emptySet(),
                timeline = rebuilt.first,
                selectedYearAnchor = rebuilt.second
            )
        }
        if (media == ServerMediaTypeFilter.TRASH) {
            loadTrashPhotos()
        }
    }

    fun loadTrashPhotos() {
        if (_uiState.value.isLoadingTrash) return
        _uiState.update { it.copy(isLoadingTrash = true) }
        viewModelScope.launch {
            try {
                val res = PhotoHubApiClient(context, settings).fetchTrashPhotos()
                _uiState.update { prev ->
                    val rebuilt = if (prev.isViewingTrash) {
                        rebuildTimelineData(
                            res.photos,
                            prev.filterMode,
                            prev.mediaTypeFilter,
                            prev.timelineGrouping,
                            prev.selectedYearAnchor,
                            prev.searchQuery,
                            prev.locallyProtectedHashes
                        )
                    } else {
                        prev.timeline to prev.selectedYearAnchor
                    }
                    prev.copy(
                        trashPhotos = res.photos,
                        trashCount = res.total,
                        trashBytes = res.trashBytes,
                        isLoadingTrash = false,
                        timeline = rebuilt.first,
                        selectedYearAnchor = rebuilt.second
                    )
                }
            } catch (err: Exception) {
                _uiState.update {
                    it.copy(
                        isLoadingTrash = false,
                        deleteBannerMessage = "Could not load Trash: ${err.localizedMessage}"
                    )
                }
            }
        }
    }

    fun setTimelineGrouping(grouping: ServerTimelineGrouping) {
        _uiState.update { prev ->
            val rebuilt = rebuildTimelineData(
                prev.activeSourcePhotos,
                prev.filterMode,
                prev.mediaTypeFilter,
                grouping,
                prev.selectedYearAnchor,
                prev.searchQuery,
                prev.locallyProtectedHashes
            )
            prev.copy(timelineGrouping = grouping, timeline = rebuilt.first, selectedYearAnchor = rebuilt.second)
        }
    }

    fun setSearchQuery(query: String) {
        _uiState.update { prev ->
            val rebuilt = rebuildTimelineData(
                prev.activeSourcePhotos,
                prev.filterMode,
                prev.mediaTypeFilter,
                prev.timelineGrouping,
                prev.selectedYearAnchor,
                query,
                prev.locallyProtectedHashes
            )
            prev.copy(searchQuery = query, timeline = rebuilt.first, selectedYearAnchor = rebuilt.second)
        }
    }

    fun clearFilters() {
        _uiState.update { prev ->
            val rebuilt = rebuildTimelineData(
                prev.photos,
                ServerGalleryFilter.ALL,
                ServerMediaTypeFilter.ALL,
                prev.timelineGrouping,
                prev.selectedYearAnchor,
                "",
                prev.locallyProtectedHashes
            )
            prev.copy(
                filterMode = ServerGalleryFilter.ALL,
                mediaTypeFilter = ServerMediaTypeFilter.ALL,
                searchQuery = "",
                timeline = rebuilt.first,
                selectedYearAnchor = rebuilt.second
            )
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
        existingAnchor: String?,
        searchQuery: String = _uiState.value.searchQuery,
        locallyProtectedHashes: Set<String> = _uiState.value.locallyProtectedHashes
    ): Pair<ServerTimelineData, String?> {
        val data = ServerTimelineBuilder.build(
            photos = photos,
            filterMode = filterMode,
            mediaTypeFilter = mediaTypeFilter,
            grouping = grouping,
            searchQuery = searchQuery,
            locallyProtectedHashes = locallyProtectedHashes
        )
        val nextAnchor = if (existingAnchor != null && data.years.any { it.anchorId == existingAnchor }) {
            existingAnchor
        } else {
            data.years.firstOrNull()?.anchorId
        }
        return data to nextAnchor
    }

    fun loadCompressedPreviewIfNeeded(photo: ServerPhoto) {
        if (getCachedThumbnail(photo.hash) != null || !inFlightPreviews.add(photo.hash)) {
            return
        }
        viewModelScope.launch(Dispatchers.IO) {
            try {
                // 1. Check Native Android Gallery FIRST (zero network download, zero duplicate app cache!)
                val nativeBmp = mediaService.loadNativeGalleryThumbnail(photo.hash, photo.isVideo, maxPixelSize = 320)
                if (nativeBmp != null) {
                    putCachedThumbnail(photo.hash, nativeBmp)
                    withContext(Dispatchers.Main) {
                        _uiState.update { prev ->
                            prev.copy(
                                thumbnailCacheVersion = prev.thumbnailCacheVersion + 1L,
                                failedPreviewHashes = prev.failedPreviewHashes - photo.hash
                            )
                        }
                    }
                    return@launch
                }

                // 2. Check app disk preview cache
                val cachedBmp = store.decodeGridThumbnailBitmap(photo.hash, maxPixelSize = 320)
                if (cachedBmp != null) {
                    putCachedThumbnail(photo.hash, cachedBmp)
                    withContext(Dispatchers.Main) {
                        _uiState.update { prev ->
                            prev.copy(
                                thumbnailCacheVersion = prev.thumbnailCacheVersion + 1L,
                                failedPreviewHashes = prev.failedPreviewHashes - photo.hash
                            )
                        }
                    }
                    return@launch
                }

                if (photo.isVideo && photo.needsProxy) {
                    withContext(Dispatchers.Main) {
                        _uiState.update { prev ->
                            prev.copy(failedPreviewHashes = prev.failedPreviewHashes + photo.hash)
                        }
                    }
                    return@launch
                }

                // 3. On-demand fallback to server preview (only for cloud-only items not in phone Gallery)
                val client = PhotoHubApiClient(context, settings)
                val raw = runCatching { client.downloadPhotoPreviewData(photo.hash) }.getOrNull()
                val compressed = raw?.let { store.cacheDownloadedPreview(it, photo.hash) }
                val gridBmp = compressed?.let { (_, bytes) ->
                    store.decodeGridThumbnailFromBytes(bytes, maxPixelSize = 320) ?: compressed.first
                }
                if (compressed != null && gridBmp !== compressed.first) {
                    compressed.first.recycle()
                }
                withContext(Dispatchers.Main) {
                    if (gridBmp != null) {
                        putCachedThumbnail(photo.hash, gridBmp)
                        _uiState.update { prev ->
                            prev.copy(
                                thumbnailCacheVersion = prev.thumbnailCacheVersion + 1L,
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
        if (_uiState.value.isBatchProxying || _uiState.value.isBatchRestoring || _uiState.value.isBatchDeleting || targets.isEmpty()) return

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
                    val rebuilt = rebuildTimelineData(
                        prev.photos,
                        nextFilter,
                        prev.mediaTypeFilter,
                        prev.timelineGrouping,
                        prev.selectedYearAnchor,
                        prev.searchQuery,
                        prev.locallyProtectedHashes
                    )
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
            val previewBmp = store.decodeGridThumbnailBitmap(updated.hash, maxPixelSize = 320)
            if (previewBmp != null) {
                putCachedThumbnail(updated.hash, previewBmp)
            }
            val norm = normHash(updated.hash)
            val isLocProtected = tracker.isRestoredMasterHash(norm)
            withContext(Dispatchers.Main) {
                _uiState.update { prev ->
                    val nextPhotos = prev.photos.map {
                        if (it.hash.equals(updated.hash, ignoreCase = true)) updated else it
                    }
                    val nextLocallyProtected = if (isLocProtected) {
                        prev.locallyProtectedHashes + norm
                    } else {
                        prev.locallyProtectedHashes - norm
                    }
                    val rebuilt = rebuildTimelineData(
                        nextPhotos,
                        prev.filterMode,
                        prev.mediaTypeFilter,
                        prev.timelineGrouping,
                        prev.selectedYearAnchor,
                        prev.searchQuery,
                        nextLocallyProtected
                    )
                    prev.copy(
                        photos = nextPhotos,
                        thumbnailCacheVersion = prev.thumbnailCacheVersion + 1L,
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
        val initialBmp = getCachedThumbnail(photo.hash)
        _detailState.value = PhotoDetailUiState(
            photo = photo,
            isLocallyProtected = tracker.isRestoredMasterHash(photo.hash),
            previewBitmap = initialBmp
        )
        speculativePrefetchJob?.cancel()

        viewModelScope.launch(Dispatchers.IO) {
            // 1. Prefer crisp preview directly from Native Android Gallery (zero server fetch!)
            val nativeBmp = mediaService.loadNativeGalleryPreviewBitmap(photo.hash, photo.isVideo, maxPixelSize = 1600)
            if (nativeBmp != null) {
                _detailState.update { it?.copy(previewBitmap = nativeBmp) }
            } else if (!(photo.isVideo && photo.needsProxy)) {
                val cached = store.previewData(photo.hash)?.let {
                    BitmapFactory.decodeByteArray(it, 0, it.size)
                }
                val bmp = cached ?: if (initialBmp == null) {
                    runCatching {
                        val raw = PhotoHubApiClient(context, settings).downloadPhotoPreviewData(photo.hash)
                        store.cacheDownloadedPreview(raw, photo.hash)?.first
                    }.getOrNull()
                } else {
                    null
                }
                if (bmp != null) {
                    _detailState.update { it?.copy(previewBitmap = bmp) }
                }
            }

            if (photo.isVideo) {
                prepareDetailVideoProxy(photo)
            }
        }

        // Speculatively pre-fetch full-resolution originals for opened photos (<= 40 MB)
        // and short video clips (<= 15 MB) so Share Original or Restore completes immediately.
        val prefetchCap = if (photo.isVideo) SPECULATIVE_VIDEO_PREFETCH_MAX_BYTES else SPECULATIVE_PREFETCH_MAX_BYTES
        if (photo.size in 1L..prefetchCap) {
            speculativePrefetchJob = viewModelScope.launch(Dispatchers.IO) {
                runCatching {
                    OriginalDownloadCache.getOrFetchOriginal(
                        context = context,
                        apiClient = PhotoHubApiClient(context, settings),
                        masterHash = photo.hash,
                        preferredFilename = photo.originalName,
                        expectedSizeBytes = photo.size,
                        isVideo = photo.isVideo
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

    fun clearCreatedShareLink() {
        _detailState.update { it?.copy(createdShareLink = null) }
    }

    fun toggleFavoriteFromDetail() {
        val photo = _detailState.value?.photo ?: return
        val nextFav = !photo.isFavorited
        viewModelScope.launch {
            try {
                val updated = PhotoHubApiClient(context, settings).setPhotoFavorite(photo.hash, nextFav)
                applyUpdatedPhoto(updated)
                _detailState.update { cur ->
                    if (cur?.photo?.hash.equals(updated.hash, ignoreCase = true)) {
                        cur?.copy(
                            photo = updated,
                            saveMessage = if (nextFav) "Added to Favorites ♥" else "Removed from Favorites"
                        )
                    } else {
                        cur
                    }
                }
            } catch (err: Exception) {
                _detailState.update {
                    it?.copy(saveMessage = "Favorite update failed: ${err.localizedMessage}")
                }
            }
        }
    }

    fun createShareLinkFromDetail(title: String, expiresInHours: Int, passcode: String) {
        val photo = _detailState.value?.photo ?: return
        _detailState.update { it?.copy(isBusy = true, busyLabel = "Creating share link…", saveMessage = null, createdShareLink = null) }
        viewModelScope.launch {
            try {
                val link = PhotoHubApiClient(context, settings).createShareLink(
                    hashes = listOf(photo.hash),
                    title = title.ifBlank { photo.originalName },
                    expiresInHours = expiresInHours,
                    passcode = passcode
                )
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", createdShareLink = link)
                }
            } catch (err: Exception) {
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", saveMessage = "Share link failed: ${err.localizedMessage}")
                }
            }
        }
    }

    fun restorePhotoFromTrashDetail() {
        val photo = _detailState.value?.photo ?: return
        _detailState.update { it?.copy(isBusy = true, busyLabel = "Restoring from Trash…", saveMessage = null) }
        viewModelScope.launch {
            try {
                PhotoHubApiClient(context, settings).restoreServerPhotosFromTrash(listOf(photo.hash))
                _detailState.value = null
                _uiState.update { prev ->
                    val nextTrash = prev.trashPhotos.filterNot { it.hash.equals(photo.hash, ignoreCase = true) }
                    val rebuilt = if (prev.isViewingTrash) {
                        rebuildTimelineData(
                            nextTrash, prev.filterMode, prev.mediaTypeFilter, prev.timelineGrouping,
                            prev.selectedYearAnchor, prev.searchQuery, prev.locallyProtectedHashes
                        )
                    } else {
                        prev.timeline to prev.selectedYearAnchor
                    }
                    prev.copy(
                        trashPhotos = nextTrash,
                        trashCount = nextTrash.size,
                        timeline = rebuilt.first,
                        selectedYearAnchor = rebuilt.second,
                        deleteBannerMessage = "Restored ${photo.originalName} to Cloud library."
                    )
                }
                loadPhotos()
            } catch (err: Exception) {
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", saveMessage = "Restore failed: ${err.localizedMessage}")
                }
            }
        }
    }

    private suspend fun prepareDetailVideoProxy(photo: ServerPhoto) {
        // 1. Play straight from Native Android Gallery if already on device (zero server video download!)
        val nativeVideoUri = mediaService.findLiveNativeVideoUri(photo.hash)
        if (nativeVideoUri != null) {
            _detailState.update { it?.copy(videoUri = nativeVideoUri) }
            return
        }

        val existing = store.videoProxyFileIfExists(photo.hash)
        if (existing != null) {
            _detailState.update { it?.copy(videoFile = existing) }
            return
        }
        if (photo.needsProxy) return
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
                    isVideo = photo.isVideo,
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
            val alreadyInNativeGallery = withContext(Dispatchers.IO) {
                if (tracker.hasAnyLiveGalleryAsset(photo.hash)) return@withContext true
                val prefix = ProxyGenerator.proxyPrefixTag(photo.hash)
                val existingProxy = if (prefix.isNotEmpty()) mediaService.scanExistingProxyPrefixesInGallery()[prefix] else null
                if (existingProxy != null) {
                    tracker.markAsProxy(
                        assetId = existingProxy,
                        proxySha256 = photo.proxyHash.orEmpty(),
                        masterHash = photo.hash,
                        originalName = photo.originalName
                    )
                    return@withContext true
                }
                val existingOrig = mediaService.findMatchingOriginalAssetIdInGallery(photo)
                if (existingOrig != null) {
                    tracker.markUploadedOriginal(existingOrig, photo.hash)
                    return@withContext true
                }
                false
            }
            if (alreadyInNativeGallery) {
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", saveMessage = "Already in phone Gallery (duplicate avoided).")
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
        if (prev.isBatchRestoring || prev.isBatchProxying || prev.isBatchDeleting || prev.activeSourcePhotos.isEmpty()) return
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

    fun requestRestoreSelected() {
        val state = _uiState.value
        if (state.isBatchRestoring || state.isBatchProxying || state.isBatchDeleting || state.selectedHashes.isEmpty()) return
        val targets = state.photos.filter { normHash(it.hash) in state.selectedHashes }
        if (targets.isEmpty()) return
        openRestoreConfirm(
            title = "Restore Selected Originals",
            targets = targets,
            isRestoreAll = false
        )
    }

    fun requestDeleteSelected() {
        val state = _uiState.value
        if (state.isBatchRestoring || state.isBatchProxying || state.isBatchDeleting || state.selectedHashes.isEmpty()) return
        val targets = state.activeSourcePhotos.filter { normHash(it.hash) in state.selectedHashes }
        if (targets.isEmpty()) return
        _uiState.update {
            it.copy(
                deleteConfirmTargets = targets,
                deleteConfirmIsPermanent = state.isViewingTrash
            )
        }
    }

    fun requestEmptyTrashAll() {
        val trash = _uiState.value.trashPhotos
        if (trash.isEmpty() || _uiState.value.isBatchDeleting) return
        _uiState.update {
            it.copy(
                deleteConfirmTargets = trash,
                deleteConfirmIsPermanent = true
            )
        }
    }

    fun restoreSelectedFromTrash() {
        val state = _uiState.value
        if (!state.isViewingTrash || state.selectedHashes.isEmpty() || state.isBatchDeleting) return
        val hashes = state.selectedHashes.toList()
        _uiState.update { it.copy(isBatchDeleting = true, isSelectionMode = false, selectedHashes = emptySet()) }
        viewModelScope.launch {
            try {
                val restored = PhotoHubApiClient(context, settings).restoreServerPhotosFromTrash(hashes)
                val restoredSet = restored.map { normHash(it) }.toSet()
                _uiState.update { prev ->
                    val nextTrash = prev.trashPhotos.filterNot { normHash(it.hash) in restoredSet }
                    val rebuilt = rebuildTimelineData(
                        nextTrash, prev.filterMode, prev.mediaTypeFilter, prev.timelineGrouping,
                        prev.selectedYearAnchor, prev.searchQuery, prev.locallyProtectedHashes
                    )
                    prev.copy(
                        trashPhotos = nextTrash,
                        trashCount = nextTrash.size,
                        isBatchDeleting = false,
                        timeline = rebuilt.first,
                        selectedYearAnchor = rebuilt.second,
                        deleteBannerMessage = "Restored ${restored.size} item(s) to Cloud library."
                    )
                }
                loadPhotos()
            } catch (err: Exception) {
                _uiState.update {
                    it.copy(isBatchDeleting = false, deleteBannerMessage = "Restore failed: ${err.localizedMessage}")
                }
            }
        }
    }

    fun dismissDeleteConfirm() {
        _uiState.update { it.copy(deleteConfirmTargets = null, deleteConfirmIsPermanent = false) }
    }

    fun dismissDeleteBanner() {
        _uiState.update { it.copy(deleteBannerMessage = null) }
    }

    fun executeDeleteSelected() {
        val targets = _uiState.value.deleteConfirmTargets ?: return
        val permanent = _uiState.value.deleteConfirmIsPermanent
        if (_uiState.value.isBatchDeleting || _uiState.value.isBatchRestoring || _uiState.value.isBatchProxying) return
        _uiState.update {
            it.copy(
                deleteConfirmTargets = null,
                deleteConfirmIsPermanent = false,
                isBatchDeleting = true,
                deleteBannerMessage = null,
                isSelectionMode = false,
                selectedHashes = emptySet()
            )
        }

        viewModelScope.launch {
            try {
                val api = PhotoHubApiClient(context, settings)
                if (permanent) {
                    val result = api.emptyServerTrash(targets.map { it.hash })
                    val removedSet = result.deleted.map { normHash(it) }.toSet()
                    val freedStr = android.text.format.Formatter.formatFileSize(context, result.freedBytes)
                    _uiState.update { prev ->
                        val nextTrash = prev.trashPhotos.filterNot { normHash(it.hash) in removedSet }
                        val rebuilt = if (prev.isViewingTrash) {
                            rebuildTimelineData(
                                nextTrash, prev.filterMode, prev.mediaTypeFilter, prev.timelineGrouping,
                                prev.selectedYearAnchor, prev.searchQuery, prev.locallyProtectedHashes
                            )
                        } else {
                            prev.timeline to prev.selectedYearAnchor
                        }
                        prev.copy(
                            trashPhotos = nextTrash,
                            trashCount = nextTrash.size,
                            isBatchDeleting = false,
                            timeline = rebuilt.first,
                            selectedYearAnchor = rebuilt.second,
                            deleteBannerMessage = "Permanently deleted ${result.deleted.size} item(s) (freed ~$freedStr)."
                        )
                    }
                } else {
                    val result = api.moveServerPhotosToTrash(targets.map { it.hash })
                    val removedSet = (result.deleted + result.missing).map { normHash(it) }.toSet()
                    applyDeletedHashes(removedSet)
                    val count = result.deleted.size
                    _uiState.update { prev ->
                        prev.copy(
                            trashCount = prev.trashCount + count,
                            isBatchDeleting = false,
                            deleteBannerMessage = "Moved $count item(s) to Trash (kept 30 days)."
                        )
                    }
                }
            } catch (err: ApiHttpException) {
                if (err.statusCode == 401) {
                    syncManager.cancel()
                    settings.signOut()
                }
                _uiState.update {
                    it.copy(isBatchDeleting = false, deleteBannerMessage = "Delete failed: ${err.message}")
                }
            } catch (err: Exception) {
                _uiState.update {
                    it.copy(
                        isBatchDeleting = false,
                        deleteBannerMessage = "Delete failed: ${err.localizedMessage ?: "Unknown error"}"
                    )
                }
            }
        }
    }

    fun deletePhotoFromDetail() {
        val photo = _detailState.value?.photo ?: return
        val isTrash = _uiState.value.isViewingTrash || photo.isTrashed
        _detailState.update {
            it?.copy(
                isBusy = true,
                busyLabel = if (isTrash) "Deleting permanently…" else "Moving to Trash…",
                saveMessage = null
            )
        }
        speculativePrefetchJob?.cancel()

        viewModelScope.launch {
            try {
                val api = PhotoHubApiClient(context, settings)
                if (isTrash) {
                    api.emptyServerTrash(listOf(photo.hash))
                    _detailState.value = null
                    _uiState.update { prev ->
                        val nextTrash = prev.trashPhotos.filterNot { it.hash.equals(photo.hash, ignoreCase = true) }
                        val rebuilt = if (prev.isViewingTrash) {
                            rebuildTimelineData(
                                nextTrash, prev.filterMode, prev.mediaTypeFilter, prev.timelineGrouping,
                                prev.selectedYearAnchor, prev.searchQuery, prev.locallyProtectedHashes
                            )
                        } else {
                            prev.timeline to prev.selectedYearAnchor
                        }
                        prev.copy(
                            trashPhotos = nextTrash,
                            trashCount = nextTrash.size,
                            timeline = rebuilt.first,
                            selectedYearAnchor = rebuilt.second,
                            deleteBannerMessage = "Permanently deleted ${photo.originalName}."
                        )
                    }
                } else {
                    api.moveServerPhotosToTrash(listOf(photo.hash))
                    applyDeletedHashes(setOf(normHash(photo.hash)))
                    _detailState.value = null
                    _uiState.update { prev ->
                        prev.copy(
                            trashCount = prev.trashCount + 1,
                            deleteBannerMessage = "Moved ${photo.originalName} to Trash (kept 30 days)."
                        )
                    }
                }
            } catch (err: ApiHttpException) {
                if (err.statusCode == 401) {
                    syncManager.cancel()
                    settings.signOut()
                }
                _detailState.update {
                    it?.copy(isBusy = false, busyLabel = "", saveMessage = "Delete failed: ${err.message}")
                }
            } catch (err: Exception) {
                _detailState.update {
                    it?.copy(
                        isBusy = false,
                        busyLabel = "",
                        saveMessage = "Delete failed: ${err.localizedMessage ?: "Unknown error"}"
                    )
                }
            }
        }
    }

    private fun applyDeletedHashes(removedHashes: Set<String>) {
        if (removedHashes.isEmpty()) return
        for (h in removedHashes) {
            thumbnailLruCache.remove(h.lowercase(Locale.ROOT))
        }
        _uiState.update { prev ->
            val nextPhotos = prev.photos.filterNot { normHash(it.hash) in removedHashes }
            val nextFailed = prev.failedPreviewHashes.filterNot { normHash(it) in removedHashes }.toSet()
            val nextSelected = prev.selectedHashes.filterNot { normHash(it) in removedHashes }.toSet()
            val nextProtected = prev.locallyProtectedHashes - removedHashes
            val rebuilt = rebuildTimelineData(
                nextPhotos,
                prev.filterMode,
                prev.mediaTypeFilter,
                prev.timelineGrouping,
                prev.selectedYearAnchor,
                prev.searchQuery,
                nextProtected
            )
            prev.copy(
                photos = nextPhotos,
                thumbnailCacheVersion = prev.thumbnailCacheVersion + 1L,
                failedPreviewHashes = nextFailed,
                selectedHashes = nextSelected,
                locallyProtectedHashes = nextProtected,
                timeline = rebuilt.first,
                selectedYearAnchor = rebuilt.second
            )
        }
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
        if (curState.isBatchRestoring || curState.isBatchProxying || curState.isBatchDeleting || targets.isEmpty()) return
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
            BatchRestoreExecutor.runBatchRestore(
                context = context,
                client = client,
                mediaService = mediaService,
                tracker = tracker,
                targets = targets,
                onItemComplete = { progress ->
                    progress.updatedPhoto?.let { applyUpdatedPhoto(it) }
                    _uiState.update {
                        it.copy(restoreCompleted = progress.completed, restoreStatusText = progress.currentName)
                    }
                },
                onFinished = { result ->
                    val protectedSet = computeLocallyProtectedHashes(_uiState.value.photos)
                    _uiState.update { prev ->
                        prev.copy(
                            isBatchRestoring = false,
                            restoreStatusText = "",
                            locallyProtectedHashes = protectedSet,
                            restoreBannerMessage = result.summaryMessage
                        )
                    }
                }
            )
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
        val (updated, fileSize) = BatchRestoreExecutor.restoreSinglePhotoToGallery(
            context = context,
            client = client,
            mediaService = mediaService,
            tracker = tracker,
            photo = photo,
            onProgress = onProgress
        )
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
        private const val SPECULATIVE_VIDEO_PREFETCH_MAX_BYTES = 15L * 1024L * 1024L
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
