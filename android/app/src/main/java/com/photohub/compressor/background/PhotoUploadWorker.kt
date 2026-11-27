package com.photohub.compressor.background

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.photohub.compressor.data.AppSettings
import com.photohub.compressor.data.CandidateSortMode
import com.photohub.compressor.data.StagedCleanupItem
import com.photohub.compressor.media.BackupPipelineResult
import com.photohub.compressor.media.MediaAccessLevel
import com.photohub.compressor.media.MediaLibraryService
import com.photohub.compressor.media.PhotoBackupPipeline
import com.photohub.compressor.network.ApiHttpException
import com.photohub.compressor.network.PhotoHubApiClient
import com.photohub.compressor.sync.LocalProxyStore
import com.photohub.compressor.sync.LocalProxySyncManager
import com.photohub.compressor.sync.LocalProxyTracker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.isActive
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

class PhotoUploadWorker(
    appContext: Context,
    params: WorkerParameters
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val context = applicationContext
        val settings = AppSettings.getInstance(context)
        val cur = settings.current
        val bgManager = BackgroundBackupManager.getInstance(context)

        if (bgManager.isPausedForRestore() || !cur.nightlyAutoBackupEnabled || !cur.isSignedIn || cur.normalizedBaseUrl == null) {
            return Result.success()
        }
        if (!bgManager.isNetworkAllowedForAutoBackup()) {
            return Result.retry()
        }

        val mediaService = MediaLibraryService(context)
        if (mediaService.currentAccessLevel() == MediaAccessLevel.DENIED) {
            return Result.success()
        }

        val apiClient = PhotoHubApiClient(context, settings)
        val whoami = runCatching { apiClient.whoami() }.getOrNull() ?: return Result.retry()
        settings.updateServerCapabilities(whoami.storage, whoami.s3Enabled)
        val effectiveUploadMode = if (whoami.s3Enabled == true) {
            com.photohub.compressor.data.UploadMode.S3_PRESIGNED
        } else {
            com.photohub.compressor.data.UploadMode.DIRECT_VPS
        }

        val isOvernight = inputData.getBoolean(KEY_IS_OVERNIGHT, false)
        val maxItems = if (isOvernight) 60 else 24
        val scanCap = if (isOvernight) 500 else 80
        val inspectCap = if (isOvernight) 10000 else 3000

        val tracker = LocalProxyTracker.getInstance(context)
        val cachedPhotos = LocalProxyStore.getInstance(context)
            .cachedPhotos(cur.normalizedBaseUrl, cur.apiKeyCacheScope)
        val backupOnly = cur.isBackupOnlyMode
        val effectiveKeepLocal = !backupOnly && cur.keepLocalProxyInPhotos
        val rawCandidates = mediaService.scanCandidates(
            tracker = tracker,
            knownServerPhotos = cachedPhotos,
            maxResults = scanCap,
            maxInspect = inspectCap,
            oldestFirst = effectiveKeepLocal,
            skipBackedUpOriginals = backupOnly
        )

        val stagedIds = bgManager.state.value.stagedItems.map { it.id }.toSet()
        val activeIds = AssetUploadCoordinator.activeAssetIds()
        val sortedCandidates = if (effectiveKeepLocal) {
            PhotoBackupPipeline.sortCandidatesOldestFirst(rawCandidates)
        } else {
            PhotoBackupPipeline.sortCandidates(rawCandidates, CandidateSortMode.LARGEST_VIDEOS_FIRST)
        }
        val allEligible = sortedCandidates.filter { it.id !in stagedIds && it.id !in activeIds }
        val hasMoreBatches = allEligible.size > maxItems
        val prioritized = allEligible.take(maxItems)

        val videoSem = Semaphore(1)
        val gallerySem = Semaphore(1)
        val commitGate = if (effectiveKeepLocal) {
            com.photohub.compressor.media.OrderedCommitGate()
        } else {
            null
        }
        val newStaged = Collections.synchronizedList(mutableListOf<StagedCleanupItem>())
        val backedUpOnlyCount = AtomicInteger(0)
        val silentDeletedCount = AtomicInteger(0)
        val silentDeletedBytes = AtomicLong(0L)
        val quotaHit = AtomicBoolean(false)

        try {
            val queue = Channel<Pair<Int, com.photohub.compressor.data.PhotoCandidate>>(Channel.UNLIMITED)
            prioritized.forEachIndexed { idx, cand -> queue.trySend(idx to cand) }
            queue.close()

            coroutineScope {
                val workers = List(minOf(3, prioritized.size)) {
                    launch(Dispatchers.IO) {
                        for ((workIndex, candidate) in queue) {
                            if (isStopped || !isActive || quotaHit.get() || bgManager.isPausedForRestore()) {
                                commitGate?.cancelAll()
                                break
                            }
                            if (!AssetUploadCoordinator.tryClaimAsset(candidate.id, UploadOwner.BACKGROUND)) {
                                commitGate?.completeTurn(workIndex)
                                continue
                            }
                            try {
                                val res = PhotoBackupPipeline.backupAndProxyAsset(
                                    context = context,
                                    candidate = candidate,
                                    mediaService = mediaService,
                                    apiClient = apiClient,
                                    tracker = tracker,
                                    format = cur.proxyFormat,
                                    maxPixelSize = cur.proxyMaxPixelSize,
                                    quality = cur.proxyQuality,
                                    uploadMode = effectiveUploadMode,
                                    keepLocalProxy = effectiveKeepLocal,
                                    normalizedBaseUrl = cur.normalizedBaseUrl,
                                    cacheScopeKey = cur.apiKeyCacheScope,
                                    videoSemaphore = videoSem,
                                    gallerySaveSemaphore = gallerySem,
                                    commitGate = commitGate,
                                    commitIndex = workIndex,
                                    onStageChange = {}
                                )
                                if (res is BackupPipelineResult.BackedUp) {
                                    if (backupOnly) {
                                        backedUpOnlyCount.incrementAndGet()
                                    } else {
                                        val deletedSilently = bgManager.tryHandleBackedUpSilentDelete(
                                            candidateId = candidate.id,
                                            outcome = res.outcome,
                                            settingsState = cur,
                                            mediaService = mediaService,
                                            tracker = tracker
                                        )
                                        if (deletedSilently) {
                                            silentDeletedCount.incrementAndGet()
                                            silentDeletedBytes.addAndGet(res.outcome.savedBytes.coerceAtLeast(0L))
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
                                }
                            } catch (err: ApiHttpException) {
                                if (err.statusCode == 507) {
                                    quotaHit.set(true)
                                    commitGate?.cancelAll()
                                    break
                                }
                            } catch (_: Exception) {
                                // Continue remaining candidates silently
                            } finally {
                                commitGate?.completeTurn(workIndex)
                                AssetUploadCoordinator.releaseAsset(candidate.id, UploadOwner.BACKGROUND)
                            }
                        }
                    }
                }
                workers.joinAll()
            }
            commitGate?.cancelAll()

            if (!isStopped) {
                LocalProxySyncManager.getInstance(context).syncFromServerOnLaunch()
            }

            val quotaReached = quotaHit.get()
            if (backupOnly) {
                val uploadedCount = backedUpOnlyCount.get()
                when {
                    quotaReached -> bgManager.updateSummary("Storage full")
                    uploadedCount > 0 -> bgManager.updateSummary("Backed up $uploadedCount · Originals kept on phone")
                    else -> bgManager.updateSummary("All backed up · Originals kept")
                }
            } else {
                val stagedSnapshot = newStaged.toList()
                bgManager.appendStagedItems(stagedSnapshot)
                bgManager.pruneMissingAssetsFromStaged()
                val prevSilentCleaned = bgManager.silentlyCleanStagedItemsIfAllowed()

                val stagedCount = bgManager.state.value.stagedItems.size
                val stagedBytes = bgManager.state.value.stagedSavedBytes
                val sizeStr = android.text.format.Formatter.formatFileSize(context, stagedBytes)
                val totalSilent = silentDeletedCount.get() + prevSilentCleaned

                if (quotaReached) {
                    bgManager.updateSummary("Storage full")
                } else if (stagedCount > 0) {
                    bgManager.updateSummary("$stagedCount ready to delete (~$sizeStr)")
                    if ((stagedSnapshot.isNotEmpty() || isOvernight) && cur.notifyWhenBackgroundUploadFinishes) {
                        bgManager.sendDeleteOriginalsNotification(
                            count = stagedCount,
                            savedBytes = stagedBytes,
                            immediate = !isOvernight,
                            morningHour = cur.morningReminderHour
                        )
                    }
                } else if (totalSilent > 0) {
                    val freedStr = android.text.format.Formatter.formatFileSize(context, silentDeletedBytes.get())
                    val spaceNote = if (silentDeletedBytes.get() > 0L) " · ~$freedStr" else ""
                    bgManager.updateSummary("Backed up $totalSilent$spaceNote")
                } else {
                    bgManager.updateSummary("All synced")
                }
            }

            if (hasMoreBatches && !isStopped && !quotaReached && !bgManager.isPausedForRestore()) {
                bgManager.scheduleBatchContinuationIfEnabled(isOvernight = isOvernight)
            }

            return Result.success()
        } finally {
            // Re-arm MediaStore content trigger only when Auto Backup is active and not paused for restore.
            if (!bgManager.isPausedForRestore() && settings.current.nightlyAutoBackupEnabled) {
                bgManager.scheduleMediaContentTriggerIfEnabled(replaceExisting = true)
            }
        }
    }

    companion object {
        const val KEY_IS_OVERNIGHT = "is_overnight"
    }
}
