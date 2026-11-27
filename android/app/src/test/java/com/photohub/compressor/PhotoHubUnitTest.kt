package com.photohub.compressor

import com.photohub.compressor.background.AssetUploadCoordinator
import com.photohub.compressor.background.UploadOwner
import com.photohub.compressor.data.*
import com.photohub.compressor.media.MediaLibraryService
import com.photohub.compressor.media.OrderedCommitGate
import com.photohub.compressor.media.PhotoBackupPipeline
import com.photohub.compressor.media.ProxyGenerator
import com.photohub.compressor.media.ShareUtils
import kotlinx.coroutines.delay
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import com.photohub.compressor.network.ContentRangeInfo
import com.photohub.compressor.network.DownloadRangePlanner
import com.photohub.compressor.provider.PhotoHubDocumentIdParser
import com.photohub.compressor.viewmodel.BatchRestoreExecutor
import com.photohub.compressor.viewmodel.BatchRestorePlanner
import com.photohub.compressor.viewmodel.ServerGalleryFilter
import com.photohub.compressor.viewmodel.ServerMediaTypeFilter
import com.photohub.compressor.viewmodel.ServerTimelineBuilder
import com.photohub.compressor.viewmodel.ServerTimelineGrouping
import org.junit.Assert.*
import org.junit.Test

class PhotoHubUnitTest {

    @Test
    fun `proxy filename prefix extraction matches cross-platform convention`() {
        val prefix = ProxyGenerator.extractMasterHashPrefix("PHOTOHUB_PROXY_0123456789ABCDEF.jpg")
        assertEquals("0123456789abcdef", prefix)
        assertNull(ProxyGenerator.extractMasterHashPrefix("IMG_1234.HEIC"))
    }

    @Test
    fun `coordinator prevents manual and background claiming same asset or master hash`() {
        val assetId = "content://media/external/images/media/999"
        val hash = "a".repeat(64)

        assertTrue(AssetUploadCoordinator.tryClaimAsset(assetId, UploadOwner.BACKGROUND))
        assertFalse(AssetUploadCoordinator.tryClaimAsset(assetId, UploadOwner.MANUAL))
        assertTrue(AssetUploadCoordinator.isClaimedByBackground(assetId))

        AssetUploadCoordinator.releaseAsset(assetId, UploadOwner.MANUAL) // wrong owner must not release
        assertTrue(AssetUploadCoordinator.isAssetActive(assetId))

        AssetUploadCoordinator.releaseAsset(assetId, UploadOwner.BACKGROUND)
        assertFalse(AssetUploadCoordinator.isAssetActive(assetId))

        assertTrue(AssetUploadCoordinator.tryClaimMasterHash(hash))
        assertFalse(AssetUploadCoordinator.tryClaimMasterHash(hash.uppercase()))
        AssetUploadCoordinator.releaseMasterHash(hash)
        assertTrue(AssetUploadCoordinator.tryClaimMasterHash(hash))
        AssetUploadCoordinator.releaseMasterHash(hash)
    }

    @Test
    fun `largest videos first sort puts videos ahead of larger or newer images`() {
        val candidates = listOf(
            PhotoCandidate("1", 1L, false, 0L, "IMG_1.jpg", "image/jpeg", 4000, 3000, 2000L, 12_000_000L),
            PhotoCandidate("2", 2L, true, 15000L, "VID_2.mp4", "video/mp4", 3840, 2160, 1000L, 50_000_000L),
            PhotoCandidate("3", 3L, true, 5000L, "VID_3.mp4", "video/mp4", 1920, 1080, 3000L, 10_000_000L)
        )
        val sorted = PhotoBackupPipeline.sortCandidates(candidates, CandidateSortMode.LARGEST_VIDEOS_FIRST)
        assertEquals(listOf("2", "3", "1"), sorted.map { it.id })
    }

    @Test
    fun `timeline builder groups sections by year and applies needsProxy filter`() {
        val photos = listOf(
            ServerPhoto("h1", "A.jpg", 1000L, "2026-11-20", null, "2026-11-20T10:00:00Z", "2026/2026-11-20/A.jpg", true, true, "p1", 100L, false, null, false),
            ServerPhoto("h2", "B.mp4", 5000L, "2025-07-04", null, "2025-07-04T10:00:00Z", "2025/2025-07-04/B.mp4", false, false, null, null, false, null, false)
        )
        val all = ServerTimelineBuilder.build(photos, ServerGalleryFilter.ALL, ServerMediaTypeFilter.ALL, ServerTimelineGrouping.YEAR)
        assertEquals(2, all.years.size)
        assertEquals(listOf("2026", "2025"), all.years.map { it.label })

        val onlyNeedsProxy = ServerTimelineBuilder.build(photos, ServerGalleryFilter.NEEDS_PROXY, ServerMediaTypeFilter.ALL, ServerTimelineGrouping.DAY)
        assertEquals(1, onlyNeedsProxy.sections.size)
        assertEquals("h2", onlyNeedsProxy.sections.first().photos.first().hash)
    }

    @Test
    fun `proxy prefix and full sha256 helpers handle gallery duplicates and hex validation`() {
        val fullHash = "0123456789abcdef".repeat(4)
        assertTrue(ProxyGenerator.isFullSha256Hex(fullHash))
        assertFalse(ProxyGenerator.isFullSha256Hex(fullHash.take(16)))
        assertFalse(ProxyGenerator.isFullSha256Hex("zzzz" + fullHash.drop(4)))

        assertEquals(
            "0123456789abcdef",
            ProxyGenerator.extractMasterHashPrefix("PHOTOHUB_PROXY_0123456789ABCDEF (1).jpg")
        )
        assertEquals(
            "fedcba9876543210",
            ProxyGenerator.extractMasterHashPrefix("PHOTOHUB_PROXY_fedcba9876543210.mp4")
        )
    }

    @Test
    fun `share mime computation and document id parser behave consistently`() {
        assertEquals("image/heic", ShareUtils.computeCombinedShareMimeType(listOf("image/heic")))
        assertEquals("image/*", ShareUtils.computeCombinedShareMimeType(listOf("image/jpeg", "image/png")))
        assertEquals("video/*", ShareUtils.computeCombinedShareMimeType(listOf("video/mp4", "video/quicktime")))
        assertEquals("*/*", ShareUtils.computeCombinedShareMimeType(listOf("image/jpeg", "video/mp4")))

        val yearId = PhotoHubDocumentIdParser.yearDirId(2026)
        assertEquals(2026, PhotoHubDocumentIdParser.parseYearDir(yearId))
        assertNull(PhotoHubDocumentIdParser.parseYearDir("dir:all"))

        val docId = PhotoHubDocumentIdParser.photoDocId("ABCD1234EFGH5678")
        assertEquals("abcd1234efgh5678", PhotoHubDocumentIdParser.parsePhotoHash(docId))
        assertNull(PhotoHubDocumentIdParser.parsePhotoHash("dir:year:2026"))
    }

    @Test
    fun `content range planner parses headers and shards remaining bytes cleanly`() {
        assertEquals(
            ContentRangeInfo(0L, 2097151L, 10485760L),
            DownloadRangePlanner.parseContentRangeInfo("bytes 0-2097151/10485760")
        )
        assertNull(DownloadRangePlanner.parseContentRangeInfo("bytes */10485760"))
        assertNull(DownloadRangePlanner.parseContentRangeInfo(null))

        val ranges = DownloadRangePlanner.buildRemainingByteRanges(
            startOffset = 2_000_000L,
            totalSize = 11_000_000L,
            maxSegments = 3
        )
        assertEquals(3, ranges.size)
        assertEquals(2_000_000L, ranges.first().first)
        assertEquals(10_999_999L, ranges.last().last)
        for (i in 0 until ranges.lastIndex) {
            assertEquals(ranges[i].last + 1L, ranges[i + 1].first)
        }
        assertEquals(11_000_000L - 2_000_000L, ranges.sumOf { (it.last - it.first) + 1L })
    }

    @Test
    fun `silent delete filename guard protects compressed proxies and blank names`() {
        assertTrue(MediaLibraryService.isSafeSilentDeleteFilename("IMG_20261121_120000.HEIC"))
        assertTrue(MediaLibraryService.isSafeSilentDeleteFilename("/storage/emulated/0/DCIM/Camera/VID_0001.mp4"))
        assertFalse(MediaLibraryService.isSafeSilentDeleteFilename("PHOTOHUB_PROXY_0123456789abcdef.jpg"))
        assertFalse(MediaLibraryService.isSafeSilentDeleteFilename("/storage/emulated/0/Movies/PhotoHub/PHOTOHUB_PROXY_fedcba9876543210 (1).mp4"))
        assertFalse(MediaLibraryService.isSafeSilentDeleteFilename(""))
    }

    @Test
    fun `batch restore planner skips already protected or locally restored originals by default`() {
        val p1 = ServerPhoto("HashOne", "A.jpg", 1000L, "2026-11-20", null, "2026-11-20T10:00:00Z", "2026/2026-11-20/A.jpg", true, true, "p1", 100L, false, null, true)
        val p2 = ServerPhoto("HashTwo", "B.jpg", 2500L, "2026-11-20", null, "2026-11-20T10:01:00Z", "2026/2026-11-20/B.jpg", true, true, "p2", 150L, false, null, false)
        val p3 = ServerPhoto("HashThree", "C.mp4", 5000L, "2026-11-21", null, "2026-11-21T10:00:00Z", "2026/2026-11-21/C.mp4", true, true, "p3", 300L, true, 200L, false)

        val req = BatchRestorePlanner.buildConfirmRequest(
            title = "Restore All Originals",
            targets = listOf(p1, p2, p3),
            locallyProtectedHashes = setOf("hashtwo"),
            isRestoreAll = true,
            leftoverProxyHashes = setOf("hashone", "hashtwo"),
            leftoverProxyCount = 2
        )

        assertEquals(3, req.allTargets.size)
        assertEquals(listOf("HashThree"), req.unrestoredTargets.map { it.hash })
        assertEquals(2, req.skippedCount)
        assertEquals(5000L, req.unrestoredBytes)
        assertEquals(8500L, req.allBytes)
        assertEquals(2, req.leftoverProxyCount)
        assertEquals(setOf("hashone", "hashtwo"), req.leftoverProxyHashes)

        assertEquals(
            "Restored 5 original(s) to Gallery & protected them and deleted 5 compressed copy(s).",
            BatchRestoreExecutor.formatSummaryMessage(
                ok = 5,
                errCount = 0,
                cancelled = false,
                deletedProxyCount = 5
            )
        )

        assertEquals(
            listOf("HashThree"),
            BatchRestorePlanner.resolveExecutionTargets(req, includeAlreadyRestored = false).map { it.hash }
        )
        assertEquals(
            listOf("HashOne", "HashTwo", "HashThree"),
            BatchRestorePlanner.resolveExecutionTargets(req, includeAlreadyRestored = true).map { it.hash }
        )

        val allRestoredReq = BatchRestorePlanner.buildConfirmRequest(
            title = "Restore Selected Originals",
            targets = listOf(p1, p2),
            locallyProtectedHashes = setOf("HASHTWO"),
            isRestoreAll = false
        )
        assertTrue(allRestoredReq.unrestoredTargets.isEmpty())
        assertEquals(2, allRestoredReq.skippedCount)
        assertEquals(
            listOf("HashOne", "HashTwo"),
            BatchRestorePlanner.resolveExecutionTargets(allRestoredReq, includeAlreadyRestored = false).map { it.hash }
        )
    }

    @Test
    fun `proxy detection markers and candidate states identify compressed proxies cleanly`() {
        val fullHash = "abcdef0123456789".repeat(4)
        val simulatedMp4Metadata = ("\u0000\u0000\u0018udtaPhotoHubProxy:$fullHash\u0000").toByteArray(Charsets.ISO_8859_1)
        assertEquals(fullHash, ProxyGenerator.findProxyMarkerInByteArray(simulatedMp4Metadata))
        assertNull(ProxyGenerator.findProxyMarkerInByteArray("normal video metadata without tag".toByteArray()))

        val proxyCandidate = PhotoCandidate(
            id = "content://media/external/images/media/10",
            mediaStoreId = 10L,
            isVideo = false,
            durationMs = 0L,
            filename = "PHOTOHUB_PROXY_abcdef0123456789.jpg",
            mimeType = "image/jpeg",
            pixelWidth = 1440,
            pixelHeight = 1080,
            creationDateMs = 1000L,
            estimatedBytes = 250_000L,
            state = PhotoCompressionState.AlreadyProxy,
            isSelected = false,
            masterHash = fullHash,
            detectionSource = "Filename Tag",
            linkedOriginalName = "IMG_1001.HEIC",
            linkedOriginalBytes = 4_200_000L,
            isBackedUpOnServer = true
        )
        assertTrue(proxyCandidate.isDetectedProxy)
        assertTrue(proxyCandidate.state.isFinished)

        val originalCandidate = PhotoCandidate(
            id = "content://media/external/images/media/11",
            mediaStoreId = 11L,
            isVideo = false,
            durationMs = 0L,
            filename = "IMG_1002.HEIC",
            mimeType = "image/jpeg",
            pixelWidth = 4032,
            pixelHeight = 3024,
            creationDateMs = 2000L,
            estimatedBytes = 5_100_000L
        )
        assertFalse(originalCandidate.isDetectedProxy)
        assertFalse(originalCandidate.state.isFinished)
    }

    @Test
    fun `storage node normalization supports http without forcing https while gateway defaults to https`() {
        val httpNodeState = AppSettingsState(assignedServerUrl = "http://192.168.1.50:3000")
        assertEquals("http://192.168.1.50:3000", httpNodeState.normalizedBaseUrl)

        val schemelessNodeState = AppSettingsState(assignedServerUrl = "100.64.0.12:3000")
        assertEquals("http://100.64.0.12:3000", schemelessNodeState.normalizedBaseUrl)

        val httpsNodeState = AppSettingsState(assignedServerUrl = "https://photohub.mingchun.us.ci")
        assertEquals("https://photohub.mingchun.us.ci", httpsNodeState.normalizedBaseUrl)

        assertEquals(
            "https://photohub.mingchun.us.ci",
            AppSettingsState.normalizeUrl("photohub.mingchun.us.ci", defaultScheme = "https")
        )
    }

    @Test
    fun `proxy resolution and detail presets map legacy pixel sizes and quality cleanly`() {
        assertEquals(ProxyResolutionPreset.AUTO_SMART, ProxyResolutionPreset.fromStoredPixels(0))
        assertEquals(ProxyResolutionPreset.P480, ProxyResolutionPreset.fromStoredPixels(854))
        assertEquals(ProxyResolutionPreset.P720, ProxyResolutionPreset.fromStoredPixels(1280))
        assertEquals(ProxyResolutionPreset.P1080, ProxyResolutionPreset.fromStoredPixels(1920))
        assertEquals(ProxyResolutionPreset.P1080, ProxyResolutionPreset.fromStoredPixels(2048))
        assertEquals(ProxyResolutionPreset.P1440, ProxyResolutionPreset.fromStoredPixels(2560))

        assertEquals(ProxyDetailPreset.COMPACT, ProxyDetailPreset.fromStoredQuality(0.50f))
        assertEquals(ProxyDetailPreset.BALANCED, ProxyDetailPreset.fromStoredQuality(0.72f))
        assertEquals(ProxyDetailPreset.HIGH_DETAIL, ProxyDetailPreset.fromStoredQuality(0.85f))
    }

    @Test
    fun `batch restore executor formats summary messages consistently`() {
        assertEquals(
            "Stopped after restoring 3 original(s).",
            BatchRestoreExecutor.formatSummaryMessage(ok = 3, errCount = 1, cancelled = true)
        )
        assertEquals(
            "Restore failed for 4 item(s).",
            BatchRestoreExecutor.formatSummaryMessage(ok = 0, errCount = 4, cancelled = false)
        )
        assertEquals(
            "Restored 5 original(s) & protected them; 2 failed.",
            BatchRestoreExecutor.formatSummaryMessage(ok = 5, errCount = 2, cancelled = false)
        )
        assertEquals(
            "Restored 6 original(s) to Gallery & protected them.",
            BatchRestoreExecutor.formatSummaryMessage(ok = 6, errCount = 0, cancelled = false)
        )
        assertEquals(
            "Restored 6 original(s) to Gallery & protected them · Auto Backup off.",
            BatchRestoreExecutor.formatSummaryMessage(
                ok = 6,
                errCount = 0,
                cancelled = false,
                autoBackupDisabled = true
            )
        )
    }

    @Test
    fun `batch restore storage guard blocks restore when free space is below headroom and preserves auto-backup flag`() {
        val bigPhoto = ServerPhoto("HashBig", "BIG.mov", 2_000_000_000L, "2026-11-20", null, "2026-11-20T10:00:00Z", "2026/BIG.mov", true, true, "p1", 100L, true, 500L, false)
        val lowSpaceReq = BatchRestorePlanner.buildConfirmRequest(
            title = "Restore All Originals",
            targets = listOf(bigPhoto),
            locallyProtectedHashes = emptySet(),
            isRestoreAll = true,
            deviceAvailableBytes = 1_500_000_000L,
            willDisableAutoBackup = true
        )
        assertFalse(lowSpaceReq.hasEnoughStorageForUnrestored)
        assertFalse(lowSpaceReq.hasEnoughStorageForAll)
        assertTrue(lowSpaceReq.willDisableAutoBackup)

        val okSpaceReq = BatchRestorePlanner.buildConfirmRequest(
            title = "Restore All Originals",
            targets = listOf(bigPhoto),
            locallyProtectedHashes = emptySet(),
            isRestoreAll = true,
            deviceAvailableBytes = 4_000_000_000L,
            willDisableAutoBackup = true
        )
        assertTrue(okSpaceReq.hasEnoughStorageForUnrestored)
        assertTrue(okSpaceReq.hasEnoughStorageForAll)
        assertEquals(listOf("Smallest", "Balance", "High"), ProxyDetailPreset.entries.map { it.title })
        assertEquals(listOf("Auto", "480p", "720p", "1080p", "1440p"), ProxyResolutionPreset.entries.map { it.title })
    }

    @Test
    fun `share utils infer image, video, and mixed mime types cleanly`() {
        assertEquals("image/heic", ShareUtils.inferMimeType(java.io.File("IMG_001.HEIC")))
        assertEquals("video/mp4", ShareUtils.inferMimeType(java.io.File("VID_002.MP4")))
        assertEquals("video/quicktime", ShareUtils.inferMimeType(java.io.File("VID_003.MOV")))
        assertEquals(
            "image/*",
            ShareUtils.computeCombinedShareMimeType(listOf("image/jpeg", "image/heic"))
        )
        assertEquals(
            "video/*",
            ShareUtils.computeCombinedShareMimeType(listOf("video/mp4", "video/quicktime"))
        )
        assertEquals(
            "*/*",
            ShareUtils.computeCombinedShareMimeType(listOf("image/jpeg", "video/mp4"))
        )
    }

    @Test
    fun `oldest first sorting orders photos chronologically so newest commits last to gallery`() {
        val newest = ServerPhoto("h3", "NEW.jpg", 1000L, "2026-11-25", "2026-11-25T10:00:00Z", "2026-11-25T10:00:00Z", "2026/NEW.jpg", true, true, null, null, false, null, false)
        val oldest = ServerPhoto("h1", "OLD.jpg", 1000L, "2023-01-10", "2023-01-10T08:00:00Z", "2023-01-10T08:00:00Z", "2023/OLD.jpg", true, true, null, null, false, null, false)
        val middle = ServerPhoto("h2", "MID.jpg", 1000L, "2025-06-15", "2025-06-15T12:00:00Z", "2025-06-15T12:00:00Z", "2025/MID.jpg", true, true, null, null, false, null, false)

        val orderedServer = PhotoBackupPipeline.sortServerPhotosOldestFirst(listOf(newest, middle, oldest))
        assertEquals(listOf("h1", "h2", "h3"), orderedServer.map { it.hash })

        val cNewest = PhotoCandidate("c3", 3L, false, 0L, "NEW.jpg", "image/jpeg", 4000, 3000, 3000L, 1_000_000L)
        val cUndated = PhotoCandidate("c0", 0L, false, 0L, "NO_DATE.jpg", "image/jpeg", 4000, 3000, null, 1_000_000L)
        val cOldest = PhotoCandidate("c1", 1L, false, 0L, "OLD.jpg", "image/jpeg", 4000, 3000, 1000L, 1_000_000L)
        val orderedCandidates = PhotoBackupPipeline.sortCandidatesOldestFirst(listOf(cNewest, cOldest, cUndated))
        assertEquals(listOf("c0", "c1", "c3"), orderedCandidates.map { it.id })
    }

    @Test
    fun `ordered commit gate enforces oldest-to-newest gallery writes across out-of-order workers and skips`() = runBlocking {
        val gate = OrderedCommitGate()
        val committed = java.util.Collections.synchronizedList(mutableListOf<Int>())

        val jobs = listOf(
            // Index 3 finishes downloading first (5ms) -> must wait for 0, 1(skip), 2
            launch {
                delay(5)
                assertTrue(gate.waitForTurn(3))
                committed.add(3)
                gate.completeTurn(3)
            },
            // Index 2 finishes second (15ms) -> must wait for 0, 1(skip)
            launch {
                delay(15)
                assertTrue(gate.waitForTurn(2))
                committed.add(2)
                gate.completeTurn(2)
            },
            // Index 1 fails download (10ms) and skips without calling waitForTurn
            launch {
                delay(10)
                gate.completeTurn(1)
            },
            // Index 0 finishes last (40ms, e.g. large old video) -> still commits FIRST!
            launch {
                delay(40)
                assertTrue(gate.waitForTurn(0))
                committed.add(0)
                gate.completeTurn(0)
            }
        )
        jobs.joinAll()

        assertEquals(listOf(0, 2, 3), committed)
    }

    @Test
    fun `backup storage mode parsing and onboarding defaults behave consistently`() {
        assertEquals(BackupStorageMode.OPTIMIZE_STORAGE, BackupStorageMode.fromRaw("optimize_storage"))
        assertEquals(BackupStorageMode.BACKUP_ONLY, BackupStorageMode.fromRaw("backup_only"))
        assertEquals(BackupStorageMode.OPTIMIZE_STORAGE, BackupStorageMode.fromRaw("unknown_or_null"))
        assertEquals(BackupStorageMode.OPTIMIZE_STORAGE, BackupStorageMode.fromRaw(null))

        val freshState = AppSettingsState()
        assertFalse(freshState.hasCompletedOnboarding)
        assertFalse(freshState.isBackupOnlyMode)

        val backupOnlyState = freshState.copy(
            backupStorageMode = BackupStorageMode.BACKUP_ONLY,
            hasCompletedOnboarding = true
        )
        assertTrue(backupOnlyState.hasCompletedOnboarding)
        assertTrue(backupOnlyState.isBackupOnlyMode)
    }
}
