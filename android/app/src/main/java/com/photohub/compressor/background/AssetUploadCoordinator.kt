package com.photohub.compressor.background

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

enum class UploadOwner {
    MANUAL,
    BACKGROUND
}

/**
 * Shared thread-safe coordinator across manual UI uploads, silent ContentObserver runs,
 * and WorkManager background workers so the same photo/video or master SHA-256
 * is never uploaded, compressed, or saved as a duplicate proxy concurrently.
 */
object AssetUploadCoordinator {
    private val lock = Any()
    private val activeByAssetId = mutableMapOf<String, UploadOwner>()
    private val activeMasterHashes = mutableSetOf<String>()

    private val _changes = MutableSharedFlow<Unit>(extraBufferCapacity = 32)
    val changes: SharedFlow<Unit> = _changes.asSharedFlow()

    fun tryClaimAsset(assetId: String, owner: UploadOwner): Boolean {
        val claimed = synchronized(lock) {
            if (activeByAssetId.containsKey(assetId)) {
                false
            } else {
                activeByAssetId[assetId] = owner
                true
            }
        }
        if (claimed) _changes.tryEmit(Unit)
        return claimed
    }

    fun releaseAsset(assetId: String, owner: UploadOwner? = null) {
        val removed = synchronized(lock) {
            val current = activeByAssetId[assetId]
            if (current != null && (owner == null || current == owner)) {
                activeByAssetId.remove(assetId)
                true
            } else {
                false
            }
        }
        if (removed) _changes.tryEmit(Unit)
    }

    fun isAssetActive(assetId: String): Boolean = synchronized(lock) {
        activeByAssetId.containsKey(assetId)
    }

    fun isClaimedByBackground(assetId: String): Boolean = synchronized(lock) {
        activeByAssetId[assetId] == UploadOwner.BACKGROUND
    }

    fun activeAssetIds(): Set<String> = synchronized(lock) {
        activeByAssetId.keys.toSet()
    }

    fun backgroundActiveAssetIds(): Set<String> = synchronized(lock) {
        activeByAssetId.filterValues { it == UploadOwner.BACKGROUND }.keys.toSet()
    }

    fun tryClaimMasterHash(sha256: String): Boolean {
        val norm = sha256.trim().lowercase()
        if (norm.isEmpty()) return true
        return synchronized(lock) {
            activeMasterHashes.add(norm)
        }
    }

    fun releaseMasterHash(sha256: String) {
        val norm = sha256.trim().lowercase()
        if (norm.isEmpty()) return
        synchronized(lock) {
            activeMasterHashes.remove(norm)
        }
    }
}
