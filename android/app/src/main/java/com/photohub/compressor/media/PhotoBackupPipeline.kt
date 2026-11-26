package com.photohub.compressor.media

import android.content.Context
import com.photohub.compressor.background.AssetUploadCoordinator
import com.photohub.compressor.data.*
import com.photohub.compressor.network.PhotoHubApiClient
import com.photohub.compressor.sync.LocalProxyStore
import com.photohub.compressor.sync.LocalProxyTracker
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.io.File
import java.time.Instant
import java.time.format.DateTimeFormatter

data class BackupPipelineOutcome(
    val masterSha256: String,
    val masterBytes: Long,
    val proxyBytes: Long,
    val savedBytes: Long,
    val filename: String
)

sealed class BackupPipelineResult {
    data class BackedUp(val outcome: BackupPipelineOutcome) : BackupPipelineResult()
    data class SkippedExistingProxy(val masterHash: String?) : BackupPipelineResult()
    data class SkippedProtectedOriginal(val masterHash: String?) : BackupPipelineResult()
    data object SkippedInFlight : BackupPipelineResult()
}

object PhotoBackupPipeline {

    fun sortCandidates(items: List<PhotoCandidate>, mode: CandidateSortMode): List<PhotoCandidate> {
        return items.sortedWith { lhs, rhs ->
            when (mode) {
                CandidateSortMode.LARGEST_VIDEOS_FIRST -> {
                    if (lhs.isVideo != rhs.isVideo) {
                        if (lhs.isVideo) -1 else 1
                    } else if (lhs.estimatedBytes != rhs.estimatedBytes) {
                        rhs.estimatedBytes.compareTo(lhs.estimatedBytes)
                    } else {
                        compareDatesDesc(lhs.creationDateMs, rhs.creationDateMs, lhs.id, rhs.id)
                    }
                }
                CandidateSortMode.LARGEST_FIRST -> {
                    if (lhs.estimatedBytes != rhs.estimatedBytes) {
                        rhs.estimatedBytes.compareTo(lhs.estimatedBytes)
                    } else {
                        compareDatesDesc(lhs.creationDateMs, rhs.creationDateMs, lhs.id, rhs.id)
                    }
                }
                CandidateSortMode.NEWEST_FIRST -> {
                    compareDatesDesc(lhs.creationDateMs, rhs.creationDateMs, lhs.id, rhs.id)
                }
            }
        }
    }

    private fun compareDatesDesc(lhsMs: Long?, rhsMs: Long?, lhsId: String, rhsId: String): Int {
        return when {
            lhsMs != null && rhsMs != null && lhsMs != rhsMs -> rhsMs.compareTo(lhsMs)
            lhsMs != null && rhsMs == null -> -1
            lhsMs == null && rhsMs != null -> 1
            else -> rhsId.compareTo(lhsId)
        }
    }

    suspend fun backupAndProxyAsset(
        context: Context,
        candidate: PhotoCandidate,
        mediaService: MediaLibraryService,
        apiClient: PhotoHubApiClient,
        tracker: LocalProxyTracker,
        format: ProxyFormat,
        maxPixelSize: Int,
        quality: Float,
        uploadMode: UploadMode,
        keepLocalProxy: Boolean,
        normalizedBaseUrl: String?,
        cacheScopeKey: String,
        videoSemaphore: Semaphore,
        gallerySaveSemaphore: Semaphore,
        onStageChange: (PhotoCompressionState) -> Unit
    ): BackupPipelineResult {
        val prefixFromName = ProxyGenerator.extractMasterHashPrefix(candidate.filename)
        if (prefixFromName != null) {
            tracker.markAsProxy(
                assetId = candidate.id,
                proxySha256 = "",
                masterHash = null,
                originalName = candidate.filename
            )
            return BackupPipelineResult.SkippedExistingProxy(null)
        }
        if (tracker.isRestoredOriginal(candidate.id)) {
            return BackupPipelineResult.SkippedProtectedOriginal(null)
        }

        val master = mediaService.exportOriginalMaster(candidate)
        var masterDeleted = false
        try {
            val embeddedHash = ProxyGenerator.extractEmbeddedProxyMasterHash(master.file, candidate.isVideo)
            if (embeddedHash != null) {
                tracker.markAsProxy(
                    assetId = candidate.id,
                    proxySha256 = master.sha256,
                    masterHash = embeddedHash,
                    originalName = master.filename
                )
                return BackupPipelineResult.SkippedExistingProxy(embeddedHash)
            }

            val check = apiClient.checkHash(master.sha256)
            if (check.isProxy) {
                tracker.markAsProxy(
                    assetId = candidate.id,
                    proxySha256 = master.sha256,
                    masterHash = check.masterHash,
                    originalName = master.filename
                )
                return BackupPipelineResult.SkippedExistingProxy(check.masterHash)
            }

            val resolvedMasterHash = check.masterHash ?: master.sha256
            if (!AssetUploadCoordinator.tryClaimMasterHash(resolvedMasterHash)) {
                return BackupPipelineResult.SkippedInFlight
            }

            try {
                val isProtected = check.keepOriginalOnDevice ||
                    check.isProtectedOriginal ||
                    tracker.isRestoredMasterHash(master.sha256) ||
                    tracker.isRestoredMasterHash(resolvedMasterHash)
                if (isProtected) {
                    tracker.markRestoredOriginal(candidate.id, resolvedMasterHash)
                    return BackupPipelineResult.SkippedProtectedOriginal(resolvedMasterHash)
                }

                val needsUpload = !(check.exists && check.isMaster && check.canReplaceWithProxy)
                val serverHasProxy = check.hasProxy
                val localProxyPresent = tracker.liveProxyAssetId(resolvedMasterHash) != null ||
                    tracker.isMasterHandledForPhotos(resolvedMasterHash)

                if (!needsUpload && serverHasProxy && (!keepLocalProxy || localProxyPresent)) {
                    val knownProxyBytes = check.proxySize ?: 0L
                    val savedBytes = if (keepLocalProxy) (master.sizeBytes - knownProxyBytes).coerceAtLeast(0L) else master.sizeBytes
                    return BackupPipelineResult.BackedUp(
                        BackupPipelineOutcome(
                            masterSha256 = master.sha256,
                            masterBytes = master.sizeBytes,
                            proxyBytes = knownProxyBytes,
                            savedBytes = savedBytes,
                            filename = master.filename
                        )
                    )
                }

                if (needsUpload) {
                    onStageChange(PhotoCompressionState.Uploading(0.0))
                    val progressHandler: (Double) -> Unit = { p ->
                        onStageChange(PhotoCompressionState.Uploading(p))
                    }
                    when (uploadMode) {
                        UploadMode.DIRECT_VPS -> apiClient.uploadMasterDirect(
                            file = master.file,
                            filename = master.filename,
                            mimeType = master.mimeType,
                            createdAtMs = candidate.creationDateMs,
                            expectedSha256 = master.sha256,
                            onProgress = progressHandler
                        )
                        UploadMode.S3_PRESIGNED -> try {
                            apiClient.uploadMasterPresigned(
                                file = master.file,
                                filename = master.filename,
                                mimeType = master.mimeType,
                                createdAtMs = candidate.creationDateMs,
                                expectedSha256 = master.sha256,
                                onProgress = progressHandler
                            )
                        } catch (httpErr: com.photohub.compressor.network.ApiHttpException) {
                            if (httpErr.statusCode == 501) {
                                apiClient.uploadMasterDirect(
                                    file = master.file,
                                    filename = master.filename,
                                    mimeType = master.mimeType,
                                    createdAtMs = candidate.creationDateMs,
                                    expectedSha256 = master.sha256,
                                    onProgress = progressHandler
                                )
                            } else {
                                throw httpErr
                            }
                        }
                    }
                }

                onStageChange(PhotoCompressionState.CreatingProxy)
                val proxy: GeneratedProxy
                val previewFileForServer: File?
                val previewFmtForServer: String
                val videoProxyFileForServer: File?

                if (candidate.isVideo) {
                    proxy = videoSemaphore.withPermit {
                        ProxyGenerator.createVideoProxy(
                            context = context,
                            masterFile = master.file,
                            maxPixelSize = maxPixelSize,
                            quality = quality,
                            masterHash = master.sha256
                        )
                    }
                    previewFileForServer = proxy.posterFile
                    previewFmtForServer = "jpeg"
                    videoProxyFileForServer = proxy.file
                } else {
                    proxy = ProxyGenerator.createImageProxy(
                        context = context,
                        masterFile = master.file,
                        format = format,
                        maxPixelSize = maxPixelSize,
                        quality = quality,
                        masterHash = master.sha256
                    )
                    previewFileForServer = proxy.file
                    previewFmtForServer = "jpeg"
                    videoProxyFileForServer = null
                }

                master.file.delete()
                masterDeleted = true

                try {
                    runCatching {
                        apiClient.registerProxy(
                            masterHash = master.sha256,
                            proxyHash = proxy.sha256,
                            assetId = candidate.id,
                            proxyFile = previewFileForServer,
                            proxyFormat = previewFmtForServer,
                            videoProxyFile = videoProxyFileForServer
                        )
                    }

                    val store = LocalProxyStore.getInstance(context)
                    if (previewFileForServer != null) store.copyPreviewFile(previewFileForServer, master.sha256)
                    if (candidate.isVideo) store.copyVideoProxy(proxy.file, master.sha256)

                    val nowIso = DateTimeFormatter.ISO_INSTANT.format(Instant.now())
                    val photoIso = candidate.creationDateMs?.let {
                        DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(it))
                    } ?: nowIso
                    val posterBytes = previewFileForServer?.takeIf { it.exists() }?.length()

                    store.upsertPhoto(
                        ServerPhoto(
                            hash = master.sha256,
                            originalName = master.filename,
                            size = master.sizeBytes,
                            photoDate = photoIso,
                            takenAt = photoIso,
                            uploadedAt = nowIso,
                            savedPath = check.savedPath ?: master.filename,
                            hasProxy = true,
                            hasPreview = previewFileForServer != null,
                            proxyHash = proxy.sha256,
                            proxySize = if (candidate.isVideo) posterBytes else proxy.sizeBytes,
                            hasVideoProxy = candidate.isVideo,
                            videoProxySize = if (candidate.isVideo) proxy.sizeBytes else null,
                            keepOriginalOnDevice = false
                        ),
                        baseUrl = normalizedBaseUrl,
                        scopeKey = cacheScopeKey
                    )

                    val savedBytes = if (keepLocalProxy) {
                        (master.sizeBytes - proxy.sizeBytes).coerceAtLeast(0L)
                    } else {
                        master.sizeBytes
                    }

                    if (keepLocalProxy) {
                        onStageChange(PhotoCompressionState.ReplacingInPhotos)
                        val newAssetId = gallerySaveSemaphore.withPermit {
                            mediaService.saveCompressedProxyToGallery(candidate, proxy.file)
                        }
                        if (newAssetId != candidate.id) {
                            tracker.markAsProxy(
                                assetId = newAssetId,
                                proxySha256 = proxy.sha256,
                                masterHash = master.sha256,
                                originalName = master.filename
                            )
                        }
                    } else {
                        tracker.markMasterHandledForPhotos(master.sha256)
                    }

                    return BackupPipelineResult.BackedUp(
                        BackupPipelineOutcome(
                            masterSha256 = master.sha256,
                            masterBytes = master.sizeBytes,
                            proxyBytes = proxy.sizeBytes,
                            savedBytes = savedBytes,
                            filename = master.filename
                        )
                    )
                } finally {
                    ProxyGenerator.cleanupTempFile(proxy.file)
                    ProxyGenerator.cleanupTempFile(proxy.posterFile)
                }
            } finally {
                AssetUploadCoordinator.releaseMasterHash(resolvedMasterHash)
            }
        } finally {
            if (!masterDeleted) {
                runCatching { master.file.delete() }
            }
        }
    }
}
