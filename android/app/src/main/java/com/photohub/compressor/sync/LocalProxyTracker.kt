package com.photohub.compressor.sync

import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import org.json.JSONArray
import org.json.JSONObject
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap

data class MasterMatch(
    val masterHash: String,
    val originalName: String?
)

data class ReconciledProxyLink(
    val assetId: String,
    val proxySha256: String,
    val masterHash: String,
    val originalName: String
)

/**
 * Persists locally compressed proxy URIs, SHA-256 hashes, master-hash mappings,
 * and restored-original protection so proxies are never re-uploaded and Share Original always works.
 */
class LocalProxyTracker private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("photohub_local_proxy_tracker", Context.MODE_PRIVATE)
    private val lock = Any()

    private val assetIds = loadSet(KEY_ASSET_IDS)
    private val proxyHashes = loadSet(KEY_PROXY_HASHES)
    private val assetToMaster = loadMap(KEY_ASSET_TO_MASTER)
    private val assetToFilename = loadMap(KEY_ASSET_TO_FILENAME)
    private val proxyHashToMaster = loadMap(KEY_PROXY_HASH_TO_MASTER)
    private val masterToAssetId = loadMap(KEY_MASTER_TO_ASSET)
    private val autoHandledPhotosMasters = loadSet(KEY_AUTO_HANDLED)
    private val restoredAssetIds = loadSet(KEY_RESTORED_IDS)
    private val restoredMasterHashes = loadSet(KEY_RESTORED_MASTERS)
    private val restoredAssetToMaster = loadMap(KEY_RESTORED_ASSET_TO_MASTER)
    private val restoredMasterToAssetIds: MutableMap<String, MutableSet<String>> = HashMap<String, MutableSet<String>>().apply {
        for ((assetId, master) in restoredAssetToMaster) {
            val norm = master.trim().lowercase()
            if (assetId.isNotBlank() && norm.isNotEmpty()) {
                getOrPut(norm) { linkedSetOf() }.add(assetId)
            }
        }
    }
    private val uploadedOriginalMasterToAsset = loadMap(KEY_UPLOADED_ORIGINAL_MASTER_TO_ASSET)
    private val uploadedOriginalAssetIds = uploadedOriginalMasterToAsset.values
        .filter { it.isNotBlank() }
        .toMutableSet()
    private val pendingProtectionSyncMasters = loadSet(KEY_PENDING_PROTECTION_SYNC)

    // Lock-free hot-path caches for smooth Cloud grid scrolling (zero Binder IPC per tile).
    private val resolvedLiveUriCache = ConcurrentHashMap<String, Uri>()
    private val missingLiveUriHashes: MutableSet<String> = Collections.synchronizedSet(HashSet())

    fun isKnownProxy(assetId: String): Boolean = synchronized(lock) {
        assetIds.contains(assetId)
    }

    fun isKnownProxySha256(sha256: String): Boolean = synchronized(lock) {
        proxyHashes.contains(sha256.lowercase())
    }

    fun masterLookup(assetId: String): MasterMatch? = synchronized(lock) {
        val master = assetToMaster[assetId]?.takeIf { it.isNotEmpty() } ?: return null
        MasterMatch(master, assetToFilename[assetId])
    }

    fun anyMasterHash(assetId: String): String? = synchronized(lock) {
        assetToMaster[assetId]?.takeIf { it.isNotEmpty() }
            ?: restoredAssetToMaster[assetId]?.takeIf { it.isNotEmpty() }
            ?: if (uploadedOriginalAssetIds.contains(assetId)) {
                uploadedOriginalMasterToAsset.entries.firstOrNull { it.value == assetId }?.key
            } else {
                null
            }
    }

    fun masterHashForProxySha256(sha256: String): String? = synchronized(lock) {
        proxyHashToMaster[sha256.lowercase()]
    }

    fun isMasterHandledForPhotos(masterHash: String): Boolean = synchronized(lock) {
        autoHandledPhotosMasters.contains(masterHash.lowercase())
    }

    fun markMasterHandledForPhotos(masterHash: String) {
        val norm = masterHash.lowercase()
        if (norm.isEmpty()) return
        synchronized(lock) {
            autoHandledPhotosMasters.add(norm)
            saveSet(KEY_AUTO_HANDLED, autoHandledPhotosMasters)
        }
    }

    fun liveProxyAssetId(masterHash: String): String? {
        val savedId = synchronized(lock) { masterToAssetId[masterHash.lowercase()] } ?: return null
        val uri = Uri.parse(savedId)
        return try {
            appContext.contentResolver.query(
                uri,
                arrayOf(MediaStore.MediaColumns._ID),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) savedId else null
            }
        } catch (_: Exception) {
            null
        }
    }

    fun markAsProxy(
        assetId: String,
        proxySha256: String,
        masterHash: String? = null,
        originalName: String? = null,
        additionalProxyHashes: List<String> = emptyList()
    ) {
        synchronized(lock) {
            val allProxyHashes = (listOf(proxySha256) + additionalProxyHashes)
                .map { it.trim().lowercase() }
                .filter { it.isNotEmpty() }
                .distinct()

            assetIds.add(assetId)
            saveSet(KEY_ASSET_IDS, assetIds)

            if (allProxyHashes.isNotEmpty()) {
                proxyHashes.addAll(allProxyHashes)
                saveSet(KEY_PROXY_HASHES, proxyHashes)
            }

            if (!masterHash.isNullOrBlank()) {
                val normMaster = masterHash.lowercase()
                assetToMaster[assetId] = normMaster
                masterToAssetId[normMaster] = assetId
                autoHandledPhotosMasters.add(normMaster)
                missingLiveUriHashes.remove(normMaster)
                runCatching { Uri.parse(assetId) }.getOrNull()?.let { uri ->
                    resolvedLiveUriCache.putIfAbsent(normMaster, uri)
                }
                saveMap(KEY_ASSET_TO_MASTER, assetToMaster)
                saveMap(KEY_MASTER_TO_ASSET, masterToAssetId)
                saveSet(KEY_AUTO_HANDLED, autoHandledPhotosMasters)
                if (allProxyHashes.isNotEmpty()) {
                    for (pHash in allProxyHashes) {
                        proxyHashToMaster[pHash] = normMaster
                    }
                    saveMap(KEY_PROXY_HASH_TO_MASTER, proxyHashToMaster)
                }
            }

            if (!originalName.isNullOrBlank()) {
                assetToFilename[assetId] = originalName
                saveMap(KEY_ASSET_TO_FILENAME, assetToFilename)
            }
        }
    }

    fun trackedProxyAssetIds(masterHashes: Set<String>): List<String> {
        val normHashes = masterHashes
            .map { it.trim().lowercase() }
            .filter { it.isNotEmpty() }
            .toSet()
        if (normHashes.isEmpty()) return emptyList()
        return synchronized(lock) {
            val result = linkedSetOf<String>()
            for (h in normHashes) {
                val direct = masterToAssetId[h]
                if (!direct.isNullOrBlank() && !restoredAssetIds.contains(direct)) {
                    result.add(direct)
                }
            }
            for ((assetId, mappedMaster) in assetToMaster) {
                if (mappedMaster.trim().lowercase() in normHashes && !restoredAssetIds.contains(assetId)) {
                    result.add(assetId)
                }
            }
            result.toList()
        }
    }

    fun clearProxyMappings(deletedAssetIds: Collection<String>) {
        val idSet = deletedAssetIds.filter { it.isNotBlank() }.toSet()
        if (idSet.isEmpty()) return
        synchronized(lock) {
            for (id in idSet) {
                assetIds.remove(id)
                assetToMaster.remove(id)
                assetToFilename.remove(id)
            }
            val mastersToRemove = masterToAssetId
                .filterValues { it in idSet }
                .keys
                .toList()
            for (master in mastersToRemove) {
                masterToAssetId.remove(master)
                resolvedLiveUriCache.remove(master)
                missingLiveUriHashes.remove(master)
            }
            saveSet(KEY_ASSET_IDS, assetIds)
            saveMap(KEY_ASSET_TO_MASTER, assetToMaster)
            saveMap(KEY_ASSET_TO_FILENAME, assetToFilename)
            saveMap(KEY_MASTER_TO_ASSET, masterToAssetId)
        }
    }

    fun isRestoredOriginal(assetId: String): Boolean = synchronized(lock) {
        restoredAssetIds.contains(assetId)
    }

    fun isRestoredMasterHash(masterHash: String): Boolean = synchronized(lock) {
        restoredMasterHashes.contains(masterHash.lowercase())
    }

    fun liveRestoredAssetId(masterHash: String): String? {
        val normMaster = masterHash.trim().lowercase()
        if (normMaster.isEmpty()) return null
        val candidateIds = synchronized(lock) {
            restoredMasterToAssetIds[normMaster]?.toList().orEmpty()
        }
        if (candidateIds.isEmpty()) return null
        for (raw in candidateIds) {
            val exists = runCatching {
                appContext.contentResolver.query(
                    Uri.parse(raw),
                    arrayOf(MediaStore.MediaColumns._ID),
                    null,
                    null,
                    null
                )?.use { it.moveToFirst() } ?: false
            }.getOrDefault(false)
            if (exists) return raw
        }
        return null
    }

    fun markRestoredOriginal(assetId: String?, masterHash: String) {
        val normMaster = masterHash.trim().lowercase()
        synchronized(lock) {
            if (!assetId.isNullOrBlank()) {
                restoredAssetIds.add(assetId)
                saveSet(KEY_RESTORED_IDS, restoredAssetIds)
                if (normMaster.isNotEmpty()) {
                    restoredAssetToMaster[assetId] = normMaster
                    restoredMasterToAssetIds.getOrPut(normMaster) { linkedSetOf() }.add(assetId)
                    missingLiveUriHashes.remove(normMaster)
                    runCatching { Uri.parse(assetId) }.getOrNull()?.let { resolvedLiveUriCache[normMaster] = it }
                    saveMap(KEY_RESTORED_ASSET_TO_MASTER, restoredAssetToMaster)
                }
            }
            if (normMaster.isNotEmpty()) {
                restoredMasterHashes.add(normMaster)
                saveSet(KEY_RESTORED_MASTERS, restoredMasterHashes)
            }
        }
    }

    fun markUploadedOriginal(assetId: String, masterHash: String) {
        val normMaster = masterHash.trim().lowercase()
        val cleanId = assetId.trim()
        if (normMaster.isEmpty() || cleanId.isEmpty()) return
        synchronized(lock) {
            uploadedOriginalAssetIds.add(cleanId)
            missingLiveUriHashes.remove(normMaster)
            runCatching { Uri.parse(cleanId) }.getOrNull()?.let { resolvedLiveUriCache.putIfAbsent(normMaster, it) }
            if (uploadedOriginalMasterToAsset[normMaster] != cleanId) {
                uploadedOriginalMasterToAsset[normMaster] = cleanId
                saveMap(KEY_UPLOADED_ORIGINAL_MASTER_TO_ASSET, uploadedOriginalMasterToAsset)
            }
        }
    }

    /**
     * Returns true if [assetId] is a full-resolution original already verified/uploaded to the server.
     * Used in Backup Only mode so originals kept on the phone are not repeatedly queued for upload.
     */
    fun isUploadedOriginal(assetId: String): Boolean = synchronized(lock) {
        uploadedOriginalAssetIds.contains(assetId)
    }

    private fun isLiveMediaStoreUri(rawUri: String): Boolean {
        if (rawUri.isBlank()) return false
        val uri = runCatching { Uri.parse(rawUri) }.getOrNull() ?: return false
        return runCatching {
            val cols = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.IS_TRASHED)
            } else {
                arrayOf(MediaStore.MediaColumns._ID)
            }
            appContext.contentResolver.query(uri, cols, null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) return@use false
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                    val trashedIdx = cursor.getColumnIndex(MediaStore.MediaColumns.IS_TRASHED)
                    if (trashedIdx >= 0 && cursor.getInt(trashedIdx) != 0) return@use false
                }
                true
            } ?: false
        }.getOrDefault(false)
    }

    fun liveUploadedOriginalAssetId(masterHash: String): String? {
        val normMaster = masterHash.trim().lowercase()
        if (normMaster.isEmpty()) return null
        val savedId = synchronized(lock) { uploadedOriginalMasterToAsset[normMaster] } ?: return null
        return if (isLiveMediaStoreUri(savedId)) savedId else null
    }

    private fun candidateGalleryUriStringsLocked(normMaster: String): List<String> {
        val list = linkedSetOf<String>()
        restoredMasterToAssetIds[normMaster]?.forEach { assetId ->
            if (assetId.isNotBlank()) list.add(assetId)
        }
        uploadedOriginalMasterToAsset[normMaster]?.takeIf { it.isNotBlank() }?.let { list.add(it) }
        masterToAssetId[normMaster]?.takeIf { it.isNotBlank() }?.let { list.add(it) }
        return list.toList()
    }

    /**
     * Pure in-memory O(1) candidate URI lookup (zero Binder IPC) ordered by:
     * restored original -> still-present uploaded original -> local compressed proxy.
     */
    fun candidateGalleryAssetUris(masterHash: String): List<Uri> {
        val normMaster = masterHash.trim().lowercase()
        if (normMaster.isEmpty()) return emptyList()
        val rawList = synchronized(lock) { candidateGalleryUriStringsLocked(normMaster) }
        return rawList.mapNotNull { runCatching { Uri.parse(it) }.getOrNull() }
    }

    fun cachedLiveGalleryUri(masterHash: String): Uri? {
        val norm = masterHash.trim().lowercase()
        if (norm.isEmpty()) return null
        return resolvedLiveUriCache[norm]
    }

    fun isKnownMissingLiveGalleryUri(masterHash: String): Boolean {
        val norm = masterHash.trim().lowercase()
        return norm.isNotEmpty() && missingLiveUriHashes.contains(norm)
    }

    fun markLiveUriConfirmed(masterHash: String, uri: Uri) {
        val norm = masterHash.trim().lowercase()
        if (norm.isEmpty()) return
        resolvedLiveUriCache[norm] = uri
        missingLiveUriHashes.remove(norm)
    }

    fun markLiveUriMissing(masterHash: String) {
        val norm = masterHash.trim().lowercase()
        if (norm.isEmpty()) return
        resolvedLiveUriCache.remove(norm)
        missingLiveUriHashes.add(norm)
    }

    fun invalidateLiveUri(masterHash: String, failedUri: Uri? = null) {
        val norm = masterHash.trim().lowercase()
        if (norm.isEmpty()) return
        if (failedUri == null) {
            resolvedLiveUriCache.remove(norm)
        } else {
            resolvedLiveUriCache.remove(norm, failedUri)
        }
        missingLiveUriHashes.remove(norm)
    }

    /**
     * Verifies all tracked URIs for [masterHashes] against a single-pass MediaStore [liveUriSet]
     * in pure O(1) RAM (eliminating thousands of per-photo Binder IPC queries).
     * Returns the set of normalized master hashes confirmed live in native Gallery.
     */
    fun primeLiveUriCacheFromLiveSet(masterHashes: Collection<String>, liveUriSet: Set<String>): Set<String> {
        val confirmed = HashSet<String>(masterHashes.size)
        synchronized(lock) {
            for (rawHash in masterHashes) {
                val norm = rawHash.trim().lowercase()
                if (norm.isEmpty()) continue
                val candidates = candidateGalleryUriStringsLocked(norm)
                val liveMatch = candidates.firstOrNull { it in liveUriSet }
                if (liveMatch != null) {
                    runCatching { Uri.parse(liveMatch) }.getOrNull()?.let {
                        resolvedLiveUriCache[norm] = it
                    }
                    missingLiveUriHashes.remove(norm)
                    confirmed.add(norm)
                } else {
                    resolvedLiveUriCache.remove(norm)
                    missingLiveUriHashes.add(norm)
                }
            }
        }
        return confirmed
    }

    /**
     * Batch-commits reconciled proxy & uploaded-original links with ONE SharedPreferences JSON write
     * instead of O(N²) per-item serialization inside reconcile/sync loops.
     */
    fun batchRecordReconciledLinks(
        proxies: List<ReconciledProxyLink>,
        uploadedOriginals: List<Pair<String, String>>
    ) {
        if (proxies.isEmpty() && uploadedOriginals.isEmpty()) return
        synchronized(lock) {
            var dirtyAssetIds = false
            var dirtyProxyHashes = false
            var dirtyAssetToMaster = false
            var dirtyMasterToAsset = false
            var dirtyAutoHandled = false
            var dirtyProxyHashToMaster = false
            var dirtyAssetToFilename = false
            var dirtyUploadedOriginals = false

            for (item in proxies) {
                val cleanId = item.assetId.trim()
                val normMaster = item.masterHash.trim().lowercase()
                val normProxy = item.proxySha256.trim().lowercase()
                if (cleanId.isEmpty()) continue

                if (assetIds.add(cleanId)) dirtyAssetIds = true
                if (normProxy.isNotEmpty() && proxyHashes.add(normProxy)) dirtyProxyHashes = true
                if (normMaster.isNotEmpty()) {
                    if (assetToMaster[cleanId] != normMaster) {
                        assetToMaster[cleanId] = normMaster
                        dirtyAssetToMaster = true
                    }
                    if (masterToAssetId[normMaster] != cleanId) {
                        masterToAssetId[normMaster] = cleanId
                        dirtyMasterToAsset = true
                    }
                    if (autoHandledPhotosMasters.add(normMaster)) dirtyAutoHandled = true
                    if (normProxy.isNotEmpty() && proxyHashToMaster[normProxy] != normMaster) {
                        proxyHashToMaster[normProxy] = normMaster
                        dirtyProxyHashToMaster = true
                    }
                    missingLiveUriHashes.remove(normMaster)
                    runCatching { Uri.parse(cleanId) }.getOrNull()?.let {
                        resolvedLiveUriCache.putIfAbsent(normMaster, it)
                    }
                }
                if (item.originalName.isNotBlank() && assetToFilename[cleanId] != item.originalName) {
                    assetToFilename[cleanId] = item.originalName
                    dirtyAssetToFilename = true
                }
            }

            for ((assetId, masterHash) in uploadedOriginals) {
                val cleanId = assetId.trim()
                val normMaster = masterHash.trim().lowercase()
                if (cleanId.isEmpty() || normMaster.isEmpty()) continue
                uploadedOriginalAssetIds.add(cleanId)
                missingLiveUriHashes.remove(normMaster)
                runCatching { Uri.parse(cleanId) }.getOrNull()?.let {
                    resolvedLiveUriCache.putIfAbsent(normMaster, it)
                }
                if (uploadedOriginalMasterToAsset[normMaster] != cleanId) {
                    uploadedOriginalMasterToAsset[normMaster] = cleanId
                    dirtyUploadedOriginals = true
                }
            }

            if (dirtyAssetIds) saveSet(KEY_ASSET_IDS, assetIds)
            if (dirtyProxyHashes) saveSet(KEY_PROXY_HASHES, proxyHashes)
            if (dirtyAssetToMaster) saveMap(KEY_ASSET_TO_MASTER, assetToMaster)
            if (dirtyMasterToAsset) saveMap(KEY_MASTER_TO_ASSET, masterToAssetId)
            if (dirtyAutoHandled) saveSet(KEY_AUTO_HANDLED, autoHandledPhotosMasters)
            if (dirtyProxyHashToMaster) saveMap(KEY_PROXY_HASH_TO_MASTER, proxyHashToMaster)
            if (dirtyAssetToFilename) saveMap(KEY_ASSET_TO_FILENAME, assetToFilename)
            if (dirtyUploadedOriginals) saveMap(KEY_UPLOADED_ORIGINAL_MASTER_TO_ASSET, uploadedOriginalMasterToAsset)
        }
    }

    /**
     * Returns the best live MediaStore content URI currently in the phone's native Gallery for [masterHash],
     * preferring restored original -> still-present uploaded original -> local compressed proxy.
     */
    fun liveGalleryAssetUri(masterHash: String): Uri? {
        val normMaster = masterHash.trim().lowercase()
        if (normMaster.isEmpty()) return null
        val orderedCandidates = synchronized(lock) {
            candidateGalleryUriStringsLocked(normMaster)
        }
        for (raw in orderedCandidates) {
            if (isLiveMediaStoreUri(raw)) {
                val parsed = Uri.parse(raw)
                resolvedLiveUriCache[normMaster] = parsed
                missingLiveUriHashes.remove(normMaster)
                return parsed
            }
        }
        resolvedLiveUriCache.remove(normMaster)
        missingLiveUriHashes.add(normMaster)
        return null
    }

    fun hasAnyLiveGalleryAsset(masterHash: String): Boolean = liveGalleryAssetUri(masterHash) != null

    fun clearRestoredProtection(masterHash: String) {
        val normMaster = masterHash.trim().lowercase()
        if (normMaster.isEmpty()) return
        synchronized(lock) {
            restoredMasterHashes.remove(normMaster)
            pendingProtectionSyncMasters.remove(normMaster)
            val matching = restoredMasterToAssetIds.remove(normMaster)?.toList()
                ?: restoredAssetToMaster.filterValues { it == normMaster }.keys.toList()
            var dirtyUploaded = false
            for (assetId in matching) {
                restoredAssetIds.remove(assetId)
                restoredAssetToMaster.remove(assetId)
                // Preserve asset link as uploaded original so Cloud browsing remains zero-download while Optimize can re-proxy it.
                if (assetId.isNotBlank() && !assetIds.contains(assetId) && uploadedOriginalMasterToAsset[normMaster].isNullOrBlank()) {
                    uploadedOriginalMasterToAsset[normMaster] = assetId
                    uploadedOriginalAssetIds.add(assetId)
                    dirtyUploaded = true
                }
            }
            resolvedLiveUriCache.remove(normMaster)
            missingLiveUriHashes.remove(normMaster)
            saveSet(KEY_RESTORED_MASTERS, restoredMasterHashes)
            saveSet(KEY_RESTORED_IDS, restoredAssetIds)
            saveMap(KEY_RESTORED_ASSET_TO_MASTER, restoredAssetToMaster)
            saveSet(KEY_PENDING_PROTECTION_SYNC, pendingProtectionSyncMasters)
            if (dirtyUploaded) {
                saveMap(KEY_UPLOADED_ORIGINAL_MASTER_TO_ASSET, uploadedOriginalMasterToAsset)
            }
        }
    }

    fun markPendingProtectionSync(masterHashes: Collection<String>) {
        val cleaned = masterHashes.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
        if (cleaned.isEmpty()) return
        synchronized(lock) {
            var dirty = false
            for (h in cleaned) {
                if (pendingProtectionSyncMasters.add(h)) dirty = true
            }
            if (dirty) saveSet(KEY_PENDING_PROTECTION_SYNC, pendingProtectionSyncMasters)
        }
    }

    fun clearPendingProtectionSync(masterHashes: Collection<String>) {
        val cleaned = masterHashes.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
        if (cleaned.isEmpty()) return
        synchronized(lock) {
            var dirty = false
            for (h in cleaned) {
                if (pendingProtectionSyncMasters.remove(h)) dirty = true
            }
            if (dirty) saveSet(KEY_PENDING_PROTECTION_SYNC, pendingProtectionSyncMasters)
        }
    }

    fun isPendingProtectionSync(masterHash: String): Boolean {
        val norm = masterHash.trim().lowercase()
        if (norm.isEmpty()) return false
        return synchronized(lock) { pendingProtectionSyncMasters.contains(norm) }
    }

    fun pendingProtectionSyncHashes(): List<String> = synchronized(lock) {
        pendingProtectionSyncMasters.toList()
    }

    /**
     * Reconciles local restored-original locks with the server's authoritative `keepOriginalOnDevice` set:
     * - Items unlocked on the webpage (`keepOriginalOnDevice == false`) are unlocked locally so they vanish
     *   from Protected and become immediately eligible for re-proxying in Backup/Compress.
     * - Items protected on the webpage (`keepOriginalOnDevice == true`) are protected locally too.
     */
    fun syncProtectedMasterHashesFromServer(
        serverProtectedHashes: Set<String>,
        scopedToHashes: Set<String>? = null
    ): Boolean {
        val normalizedProtected = serverProtectedHashes
            .map { it.trim().lowercase() }
            .filter { it.isNotEmpty() }
            .toSet()

        return synchronized(lock) {
            var dirtyRestoredMasters = false
            var dirtyRestoredAssets = false
            var dirtyRestoredMap = false
            var dirtyUploaded = false

            // 1. Unlock locally protected items no longer protected on the server (e.g. Allow Re-Proxy from webpage)
            for (h in restoredMasterHashes.toList()) {
                if (scopedToHashes != null && h !in scopedToHashes) continue
                if (h in pendingProtectionSyncMasters) continue
                if (h !in normalizedProtected) {
                    restoredMasterHashes.remove(h)
                    dirtyRestoredMasters = true
                    val linkedIds = restoredMasterToAssetIds.remove(h)?.toList()
                        ?: restoredAssetToMaster.filterValues { it == h }.keys.toList()
                    for (assetId in linkedIds) {
                        if (restoredAssetIds.remove(assetId)) dirtyRestoredAssets = true
                        if (restoredAssetToMaster.remove(assetId) != null) dirtyRestoredMap = true
                        if (assetId.isNotBlank() && !assetIds.contains(assetId) && uploadedOriginalMasterToAsset[h].isNullOrBlank()) {
                            uploadedOriginalMasterToAsset[h] = assetId
                            uploadedOriginalAssetIds.add(assetId)
                            dirtyUploaded = true
                        }
                    }
                    resolvedLiveUriCache.remove(h)
                    missingLiveUriHashes.remove(h)
                }
            }

            // Sweep orphaned restoredAssetToMaster entries whose master was unlocked on server
            for ((assetId, mappedMaster) in restoredAssetToMaster.entries.toList()) {
                val norm = mappedMaster.trim().lowercase()
                if (scopedToHashes != null && norm !in scopedToHashes) continue
                if (norm in pendingProtectionSyncMasters) continue
                if (norm !in normalizedProtected) {
                    restoredAssetToMaster.remove(assetId)
                    restoredMasterToAssetIds[norm]?.remove(assetId)
                    if (restoredMasterToAssetIds[norm]?.isEmpty() == true) {
                        restoredMasterToAssetIds.remove(norm)
                    }
                    if (restoredAssetIds.remove(assetId)) dirtyRestoredAssets = true
                    dirtyRestoredMap = true
                    if (assetId.isNotBlank() && !assetIds.contains(assetId) && uploadedOriginalMasterToAsset[norm].isNullOrBlank()) {
                        uploadedOriginalMasterToAsset[norm] = assetId
                        uploadedOriginalAssetIds.add(assetId)
                        dirtyUploaded = true
                    }
                }
            }

            // 2. Protect locally any items marked protected on the server (e.g. protected from webpage or another phone)
            for (h in normalizedProtected) {
                if (restoredMasterHashes.add(h)) dirtyRestoredMasters = true
                val knownOrigAsset = uploadedOriginalMasterToAsset[h]
                if (!knownOrigAsset.isNullOrBlank() && !assetIds.contains(knownOrigAsset)) {
                    if (restoredAssetIds.add(knownOrigAsset)) dirtyRestoredAssets = true
                    if (restoredAssetToMaster[knownOrigAsset] != h) {
                        restoredAssetToMaster[knownOrigAsset] = h
                        dirtyRestoredMap = true
                    }
                    restoredMasterToAssetIds.getOrPut(h) { linkedSetOf() }.add(knownOrigAsset)
                }
            }

            if (dirtyRestoredMasters) saveSet(KEY_RESTORED_MASTERS, restoredMasterHashes)
            if (dirtyRestoredAssets) saveSet(KEY_RESTORED_IDS, restoredAssetIds)
            if (dirtyRestoredMap) saveMap(KEY_RESTORED_ASSET_TO_MASTER, restoredAssetToMaster)
            if (dirtyUploaded) saveMap(KEY_UPLOADED_ORIGINAL_MASTER_TO_ASSET, uploadedOriginalMasterToAsset)

            dirtyRestoredMasters || dirtyRestoredAssets || dirtyRestoredMap
        }
    }

    fun syncProtectionStateFromServer(photos: List<com.photohub.compressor.data.ServerPhoto>): Boolean {
        val serverProtected = HashSet<String>()
        val allServerHashes = HashSet<String>(photos.size * 2)
        for (photo in photos) {
            val norm = photo.hash.trim().lowercase()
            if (norm.isEmpty()) continue
            allServerHashes.add(norm)
            if (photo.isProtectedOriginal) {
                serverProtected.add(norm)
            }
        }
        return syncProtectedMasterHashesFromServer(serverProtected, scopedToHashes = allServerHashes)
    }

    private fun loadSet(key: String): MutableSet<String> {
        val raw = prefs.getString(key, null) ?: return mutableSetOf()
        return try {
            val arr = JSONArray(raw)
            val set = mutableSetOf<String>()
            for (i in 0 until arr.length()) {
                arr.optString(i)?.takeIf { it.isNotEmpty() }?.let { set.add(it) }
            }
            set
        } catch (_: Exception) {
            mutableSetOf()
        }
    }

    private fun saveSet(key: String, set: Set<String>) {
        val arr = JSONArray()
        for (item in set) arr.put(item)
        prefs.edit().putString(key, arr.toString()).apply()
    }

    private fun loadMap(key: String): MutableMap<String, String> {
        val raw = prefs.getString(key, null) ?: return mutableMapOf()
        return try {
            val obj = JSONObject(raw)
            val map = mutableMapOf<String, String>()
            val iter = obj.keys()
            while (iter.hasNext()) {
                val k = iter.next()
                map[k] = obj.optString(k, "")
            }
            map
        } catch (_: Exception) {
            mutableMapOf()
        }
    }

    private fun saveMap(key: String, map: Map<String, String>) {
        val obj = JSONObject()
        for ((k, v) in map) obj.put(k, v)
        prefs.edit().putString(key, obj.toString()).apply()
    }

    companion object {
        private const val KEY_ASSET_IDS = "photohub_proxy_asset_ids"
        private const val KEY_PROXY_HASHES = "photohub_proxy_sha256_hashes"
        private const val KEY_ASSET_TO_MASTER = "photohub_proxy_asset_to_master"
        private const val KEY_ASSET_TO_FILENAME = "photohub_proxy_asset_to_filename"
        private const val KEY_PROXY_HASH_TO_MASTER = "photohub_proxy_hash_to_master"
        private const val KEY_MASTER_TO_ASSET = "photohub_master_to_proxy_asset"
        private const val KEY_AUTO_HANDLED = "photohub_auto_handled_photos_masters"
        private const val KEY_RESTORED_IDS = "photohub_restored_asset_ids"
        private const val KEY_RESTORED_MASTERS = "photohub_restored_master_hashes"
        private const val KEY_RESTORED_ASSET_TO_MASTER = "photohub_restored_asset_to_master"
        private const val KEY_UPLOADED_ORIGINAL_MASTER_TO_ASSET = "photohub_uploaded_original_master_to_asset"
        private const val KEY_PENDING_PROTECTION_SYNC = "photohub_pending_protection_sync_masters"

        @Volatile
        private var instance: LocalProxyTracker? = null

        fun getInstance(context: Context): LocalProxyTracker =
            instance ?: synchronized(this) {
                instance ?: LocalProxyTracker(context).also { instance = it }
            }
    }
}
