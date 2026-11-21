package com.photohub.compressor

import com.photohub.compressor.background.AssetUploadCoordinator
import com.photohub.compressor.background.UploadOwner
import com.photohub.compressor.data.*
import com.photohub.compressor.media.PhotoBackupPipeline
import com.photohub.compressor.media.ProxyGenerator
import com.photohub.compressor.media.ShareUtils
import com.photohub.compressor.network.ContentRangeInfo
import com.photohub.compressor.network.DownloadRangePlanner
import com.photohub.compressor.provider.PhotoHubDocumentIdParser
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
}
