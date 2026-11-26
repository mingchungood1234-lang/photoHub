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
import kotlinx.coroutines.sync.Semaphore

class PhotoUploadWorker(
    appContext: Context,
    params: WorkerParameters
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val context = applicationContext
        val settings = AppSettings.getInstance(context)
        val cur = settings.current
        val bgManager = BackgroundBackupManager.getInstance(context)

        if (!cur.nightlyAutoBackupEnabled || !cur.isSignedIn || cur.normalizedBaseUrl == null) {
            return Result.success()
        }

        val mediaService = MediaLibraryService(context)
        if (mediaService.currentAccessLevel() == MediaAccessLevel.DENIED) {
            return Result.success()
        }

        val apiClient = PhotoHubApiClient(context, settings)
        val reachable = runCatching { apiClient.whoami() }.isSuccess
        if (!reachable) {
            return Result.retry()
        }

        val isOvernight = inputData.getBoolean(KEY_IS_OVERNIGHT, false)
        val maxItems = if (isOvernight) 40 else 12
        val scanCap = if (isOvernight) 250 else 40
        val inspectCap = if (isOvernight) 2500 else 400

        val tracker = LocalProxyTracker.getInstance(context)
        val cachedPhotos = LocalProxyStore.getInstance(context)
            .cachedPhotos(cur.normalizedBaseUrl, cur.apiKeyCacheScope)
        val rawCandidates = mediaService.scanCandidates(
            tracker = tracker,
            knownServerPhotos = cachedPhotos,
            maxResults = scanCap,
            maxInspect = inspectCap
        )

        val stagedIds = bgManager.state.value.stagedItems.map { it.id }.toSet()
        val activeIds = AssetUploadCoordinator.activeAssetIds()
        val allEligible = PhotoBackupPipeline
            .sortCandidates(rawCandidates, CandidateSortMode.LARGEST_VIDEOS_FIRST)
            .filter { it.id !in stagedIds && it.id !in activeIds }
        val hasMoreBatches = allEligible.size > maxItems
        val prioritized = allEligible.take(maxItems)

        val videoSem = Semaphore(1)
        val gallerySem = Semaphore(1)
        val newStaged = mutableListOf<StagedCleanupItem>()
        var silentDeletedCount = 0
        var silentDeletedBytes = 0L
        var quotaHit = false

        try {
            for (candidate in prioritized) {
                if (isStopped) break
                if (!AssetUploadCoordinator.tryClaimAsset(candidate.id, UploadOwner.BACKGROUND)) {
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
                        uploadMode = cur.uploadMode,
                        keepLocalProxy = cur.keepLocalProxyInPhotos,
                        normalizedBaseUrl = cur.normalizedBaseUrl,
                        cacheScopeKey = cur.apiKeyCacheScope,
                        videoSemaphore = videoSem,
                        gallerySaveSemaphore = gallerySem,
                        onStageChange = {}
                    )
                    if (res is BackupPipelineResult.BackedUp) {
                        val deletedSilently = bgManager.tryHandleBackedUpSilentDelete(
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
                    if (err.statusCode == 507) {
                        quotaHit = true
                        break
                    }
                } catch (_: Exception) {
                    // Continue remaining candidates silently
                } finally {
                    AssetUploadCoordinator.releaseAsset(candidate.id, UploadOwner.BACKGROUND)
                }
            }

            if (!isStopped) {
                LocalProxySyncManager.getInstance(context).syncFromServerOnLaunch()
            }

            bgManager.appendStagedItems(newStaged)
            bgManager.pruneMissingAssetsFromStaged()
            val prevSilentCleaned = bgManager.silentlyCleanStagedItemsIfAllowed()

            val stagedCount = bgManager.state.value.stagedItems.size
            val stagedBytes = bgManager.state.value.stagedSavedBytes
            val sizeStr = android.text.format.Formatter.formatFileSize(context, stagedBytes)
            val totalSilent = silentDeletedCount + prevSilentCleaned

            if (quotaHit) {
                bgManager.updateSummary("Storage full")
            } else if (stagedCount > 0) {
                bgManager.updateSummary("$stagedCount ready to delete (~$sizeStr)")
                if ((newStaged.isNotEmpty() || isOvernight) && cur.notifyWhenBackgroundUploadFinishes) {
                    bgManager.sendDeleteOriginalsNotification(
                        count = stagedCount,
                        savedBytes = stagedBytes,
                        immediate = !isOvernight,
                        morningHour = cur.morningReminderHour
                    )
                }
            } else if (totalSilent > 0) {
                val freedStr = android.text.format.Formatter.formatFileSize(context, silentDeletedBytes)
                val spaceNote = if (silentDeletedBytes > 0L) " · ~$freedStr" else ""
                bgManager.updateSummary("Backed up $totalSilent$spaceNote")
            } else {
                bgManager.updateSummary("All synced")
            }

            if (hasMoreBatches && !isStopped && !quotaHit) {
                bgManager.scheduleBatchContinuationIfEnabled(isOvernight = isOvernight)
            }

            return Result.success()
        } finally {
            // Re-arm MediaStore content trigger so Android wakes this worker automatically on future photos.
            bgManager.scheduleMediaContentTriggerIfEnabled(replaceExisting = true)
        }
    }

    companion object {
        const val KEY_IS_OVERNIGHT = "is_overnight"
    }
}
