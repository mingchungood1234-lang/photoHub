package com.photohub.compressor.sync

import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import org.json.JSONArray
import org.json.JSONObject

data class MasterMatch(
    val masterHash: String,
    val originalName: String?
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
    private val uploadedOriginalMasterToAsset = loadMap(KEY_UPLOADED_ORIGINAL_MASTER_TO_ASSET)
    private val uploadedOriginalAssetIds = uploadedOriginalMasterToAsset.values
        .filter { it.isNotBlank() }
        .toMutableSet()

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
            restoredAssetToMaster.filterValues { it == normMaster }.keys.toList()
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

    /**
     * Returns the best live MediaStore content URI currently in the phone's native Gallery for [masterHash],
     * preferring restored original -> still-present uploaded original -> local compressed proxy.
     */
    fun liveGalleryAssetUri(masterHash: String): Uri? {
        val normMaster = masterHash.trim().lowercase()
        if (normMaster.isEmpty()) return null
        val orderedCandidates = synchronized(lock) {
            val list = linkedSetOf<String>()
            for ((assetId, mapped) in restoredAssetToMaster) {
                if (mapped == normMaster && assetId.isNotBlank()) list.add(assetId)
            }
            uploadedOriginalMasterToAsset[normMaster]?.takeIf { it.isNotBlank() }?.let { list.add(it) }
            masterToAssetId[normMaster]?.takeIf { it.isNotBlank() }?.let { list.add(it) }
            list.toList()
        }
        for (raw in orderedCandidates) {
            if (isLiveMediaStoreUri(raw)) {
                return Uri.parse(raw)
            }
        }
        return null
    }

    fun hasAnyLiveGalleryAsset(masterHash: String): Boolean = liveGalleryAssetUri(masterHash) != null

    fun clearRestoredProtection(masterHash: String) {
        val normMaster = masterHash.trim().lowercase()
        if (normMaster.isEmpty()) return
        synchronized(lock) {
            restoredMasterHashes.remove(normMaster)
            val matching = restoredAssetToMaster.filterValues { it == normMaster }.keys.toList()
            for (assetId in matching) {
                restoredAssetIds.remove(assetId)
                restoredAssetToMaster.remove(assetId)
            }
            saveSet(KEY_RESTORED_MASTERS, restoredMasterHashes)
            saveSet(KEY_RESTORED_IDS, restoredAssetIds)
            saveMap(KEY_RESTORED_ASSET_TO_MASTER, restoredAssetToMaster)
        }
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

        @Volatile
        private var instance: LocalProxyTracker? = null

        fun getInstance(context: Context): LocalProxyTracker =
            instance ?: synchronized(this) {
                instance ?: LocalProxyTracker(context).also { instance = it }
            }
    }
}
