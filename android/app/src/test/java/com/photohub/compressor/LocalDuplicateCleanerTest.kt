package com.photohub.compressor

import android.net.Uri
import com.photohub.compressor.media.LocalDuplicateCleaner
import com.photohub.compressor.media.LocalDuplicateReason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalDuplicateCleanerTest {

    @Test
    fun buildGroupKeepsOriginalOverProxyAndComputesReclaimableBytes() {
        val original = LocalDuplicateCleaner.ScannedMediaMeta(
            id = "content://media/external/images/media/10",
            uri = null,
            filename = "IMG_2026.jpg",
            sizeBytes = 4_200_000L,
            dateTakenMs = 1_700_000_000_000L,
            width = 4032,
            height = 3024,
            isVideo = false,
            isFavorite = false,
            isProxy = false,
            proxyMasterPrefix = null,
            trackedMasterPrefix = "abcdef1234567890"
        )
        val proxy1 = LocalDuplicateCleaner.ScannedMediaMeta(
            id = "content://media/external/images/media/11",
            uri = null,
            filename = "PHOTOHUB_PROXY_abcdef1234567890.jpg",
            sizeBytes = 250_000L,
            dateTakenMs = 1_700_000_000_000L,
            width = 1440,
            height = 1080,
            isVideo = false,
            isFavorite = false,
            isProxy = true,
            proxyMasterPrefix = "abcdef1234567890",
            trackedMasterPrefix = null
        )

        val group = LocalDuplicateCleaner.buildGroup(
            id = "test_redundant",
            reason = LocalDuplicateReason.REDUNDANT_PROXY,
            members = listOf(proxy1, original),
            preferredKeepId = null
        )

        assertEquals(2, group.items.size)
        assertTrue(group.items.first().isKeep)
        assertEquals(original.id, group.items.first().id)
        assertFalse(group.items[1].isKeep)
        assertEquals(1, group.removableItems.size)
        assertEquals(250_000L, group.reclaimableBytes)
    }

    @Test
    fun buildGroupPrefersFavoriteThenHigherResolutionOriginal() {
        val copy1 = LocalDuplicateCleaner.ScannedMediaMeta(
            id = "content://media/external/images/media/20",
            uri = null,
            filename = "IMG_5555 (1).jpg",
            sizeBytes = 2_000_000L,
            dateTakenMs = 1_700_000_010_000L,
            width = 3000,
            height = 2000,
            isVideo = false,
            isFavorite = false,
            isProxy = false,
            proxyMasterPrefix = null,
            trackedMasterPrefix = null
        )
        val favOriginal = copy1.copy(
            id = "content://media/external/images/media/21",
            filename = "IMG_5555.jpg",
            isFavorite = true
        )

        val group = LocalDuplicateCleaner.buildGroup(
            id = "test_exact",
            reason = LocalDuplicateReason.EXACT_FILE,
            members = listOf(copy1, favOriginal),
            preferredKeepId = null
        )

        assertEquals(favOriginal.id, group.items.first().id)
        assertTrue(group.items.first().isKeep)
        assertEquals(listOf(copy1.id), group.removableItems.map { it.id })
    }

    @Test
    fun hammingDistance64CountsDifferingBitsAccurately() {
        assertEquals(0, LocalDuplicateCleaner.hammingDistance64(0x0123456789ABCDEFL, 0x0123456789ABCDEFL))
        assertEquals(2, LocalDuplicateCleaner.hammingDistance64(0b1010L, 0b1100L))
        assertEquals(64, LocalDuplicateCleaner.hammingDistance64(0L, -1L))
    }
}
