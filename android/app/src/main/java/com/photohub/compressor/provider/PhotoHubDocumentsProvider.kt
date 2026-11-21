package com.photohub.compressor.provider

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Point
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.text.format.Formatter
import com.photohub.compressor.R
import com.photohub.compressor.data.AppSettings
import com.photohub.compressor.data.ServerPhoto
import com.photohub.compressor.media.OriginalDownloadCache
import com.photohub.compressor.media.ShareUtils
import com.photohub.compressor.network.PhotoHubApiClient
import com.photohub.compressor.sync.LocalProxyStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import java.io.File
import java.io.FileNotFoundException
import java.util.Locale

/** Pure helper functions for encoding/decoding PhotoHub DocumentsProvider document IDs. */
object PhotoHubDocumentIdParser {
    const val ROOT_ID = "photohub_root"
    const val DOC_ROOT_DIR = "dir:root"
    const val DOC_ALL_DIR = "dir:all"
    const val DOC_UNDATED_DIR = "dir:undated"
    private const val DOC_YEAR_PREFIX = "dir:year:"
    private const val DOC_PHOTO_PREFIX = "photo:"

    fun yearDirId(year: Int): String = "$DOC_YEAR_PREFIX$year"
    fun photoDocId(masterHash: String): String = "$DOC_PHOTO_PREFIX${masterHash.trim().lowercase(Locale.ROOT)}"

    fun parseYearDir(documentId: String?): Int? {
        documentId ?: return null
        if (!documentId.startsWith(DOC_YEAR_PREFIX)) return null
        return documentId.removePrefix(DOC_YEAR_PREFIX).toIntOrNull()
    }

    fun parsePhotoHash(documentId: String?): String? {
        documentId ?: return null
        if (!documentId.startsWith(DOC_PHOTO_PREFIX)) return null
        val hash = documentId.removePrefix(DOC_PHOTO_PREFIX).trim().lowercase(Locale.ROOT)
        return hash.takeIf { it.length >= 8 }
    }

    fun extractYear(photo: ServerPhoto): Int? {
        val ms = photo.parsedCreationDateMs ?: return null
        val cal = java.util.Calendar.getInstance().apply { timeInMillis = ms }
        return cal.get(java.util.Calendar.YEAR)
    }
}

/**
 * Exposes backed-up PhotoHub server photos & videos in Android's System File Picker.
 * Opening any photo/video automatically fetches the full-resolution original from the server.
 */
class PhotoHubDocumentsProvider : DocumentsProvider() {
    @Volatile
    private var lastServerRefreshMs: Long = 0L

    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val ctx = context ?: return MatrixCursor(DEFAULT_ROOT_PROJECTION)
        val settings = AppSettings.getInstance(ctx).current
        val cols = projection ?: DEFAULT_ROOT_PROJECTION
        val cursor = MatrixCursor(cols)
        if (!settings.isSignedIn || settings.normalizedBaseUrl == null) {
            return cursor
        }

        val summary = settings.userEmail.ifBlank { "Full-Resolution Originals" }
        cursor.newRow().apply {
            add(Root.COLUMN_ROOT_ID, PhotoHubDocumentIdParser.ROOT_ID)
            add(
                Root.COLUMN_FLAGS,
                Root.FLAG_SUPPORTS_RECENTS or Root.FLAG_SUPPORTS_SEARCH
            )
            add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
            add(Root.COLUMN_TITLE, ctx.getString(R.string.documents_provider_label))
            add(Root.COLUMN_SUMMARY, summary)
            add(Root.COLUMN_DOCUMENT_ID, PhotoHubDocumentIdParser.DOC_ROOT_DIR)
            add(Root.COLUMN_MIME_TYPES, "image/*\nvideo/*")
        }
        return cursor
    }

    override fun queryDocument(documentId: String?, projection: Array<out String>?): Cursor {
        val ctx = context ?: throw FileNotFoundException("Context unavailable")
        val cols = projection ?: DEFAULT_DOCUMENT_PROJECTION
        val cursor = MatrixCursor(cols)

        when (documentId) {
            PhotoHubDocumentIdParser.DOC_ROOT_DIR -> addFolderRow(cursor, documentId, "photoHub")
            PhotoHubDocumentIdParser.DOC_ALL_DIR -> addFolderRow(cursor, documentId, "All Photos & Videos")
            PhotoHubDocumentIdParser.DOC_UNDATED_DIR -> addFolderRow(cursor, documentId, "Undated")
            else -> {
                val yr = PhotoHubDocumentIdParser.parseYearDir(documentId)
                if (yr != null) {
                    addFolderRow(cursor, documentId!!, yr.toString())
                } else {
                    val hash = PhotoHubDocumentIdParser.parsePhotoHash(documentId)
                        ?: throw FileNotFoundException("Unknown documentId: $documentId")
                    val photo = loadCatalog(ctx, refreshIfEmpty = true)
                        .firstOrNull { it.hash.equals(hash, ignoreCase = true) }
                        ?: throw FileNotFoundException("Photo not found: $hash")
                    addPhotoRow(ctx, cursor, photo)
                }
            }
        }
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String?,
        projection: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val ctx = context ?: throw FileNotFoundException("Context unavailable")
        val cols = projection ?: DEFAULT_DOCUMENT_PROJECTION
        val cursor = MatrixCursor(cols)
        val settings = AppSettings.getInstance(ctx).current
        if (!settings.isSignedIn || settings.normalizedBaseUrl == null) {
            return cursor
        }

        val catalog = sortedByDateDesc(loadCatalog(ctx, refreshIfEmpty = true))

        when (parentDocumentId) {
            PhotoHubDocumentIdParser.DOC_ROOT_DIR -> {
                addFolderRow(cursor, PhotoHubDocumentIdParser.DOC_ALL_DIR, "All Photos & Videos (${catalog.size})")
                val years = catalog.mapNotNull { PhotoHubDocumentIdParser.extractYear(it) }
                    .distinct()
                    .sortedDescending()
                for (year in years) {
                    val count = catalog.count { PhotoHubDocumentIdParser.extractYear(it) == year }
                    addFolderRow(cursor, PhotoHubDocumentIdParser.yearDirId(year), "$year ($count)")
                }
                val undatedCount = catalog.count { PhotoHubDocumentIdParser.extractYear(it) == null }
                if (undatedCount > 0) {
                    addFolderRow(cursor, PhotoHubDocumentIdParser.DOC_UNDATED_DIR, "Undated ($undatedCount)")
                }
            }

            PhotoHubDocumentIdParser.DOC_ALL_DIR -> {
                for (photo in catalog) addPhotoRow(ctx, cursor, photo)
            }

            PhotoHubDocumentIdParser.DOC_UNDATED_DIR -> {
                for (photo in catalog) {
                    if (PhotoHubDocumentIdParser.extractYear(photo) == null) {
                        addPhotoRow(ctx, cursor, photo)
                    }
                }
            }

            else -> {
                val yr = PhotoHubDocumentIdParser.parseYearDir(parentDocumentId)
                if (yr != null) {
                    for (photo in catalog) {
                        if (PhotoHubDocumentIdParser.extractYear(photo) == yr) {
                            addPhotoRow(ctx, cursor, photo)
                        }
                    }
                }
            }
        }
        return cursor
    }

    override fun queryRecentDocuments(rootId: String?, projection: Array<out String>?): Cursor {
        val ctx = context ?: return MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val cols = projection ?: DEFAULT_DOCUMENT_PROJECTION
        val cursor = MatrixCursor(cols)
        if (!AppSettings.getInstance(ctx).current.isSignedIn) return cursor

        val recent = sortedByDateDesc(loadCatalog(ctx, refreshIfEmpty = true)).take(50)
        for (photo in recent) addPhotoRow(ctx, cursor, photo)
        return cursor
    }

    override fun querySearchDocuments(
        rootId: String?,
        query: String?,
        projection: Array<out String>?
    ): Cursor {
        val ctx = context ?: return MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val cols = projection ?: DEFAULT_DOCUMENT_PROJECTION
        val cursor = MatrixCursor(cols)
        if (!AppSettings.getInstance(ctx).current.isSignedIn) return cursor

        val needle = query.orEmpty().trim().lowercase(Locale.ROOT)
        val matches = sortedByDateDesc(loadCatalog(ctx, refreshIfEmpty = true)).filter {
            needle.isEmpty() ||
                it.originalName.lowercase(Locale.ROOT).contains(needle) ||
                it.photoDate.lowercase(Locale.ROOT).contains(needle) ||
                it.hash.lowercase(Locale.ROOT).startsWith(needle)
        }
        for (photo in matches.take(200)) addPhotoRow(ctx, cursor, photo)
        return cursor
    }

    override fun openDocumentThumbnail(
        documentId: String?,
        sizeHint: Point?,
        signal: CancellationSignal?
    ): AssetFileDescriptor {
        signal?.throwIfCanceled()
        val ctx = context ?: throw FileNotFoundException("Context unavailable")
        val hash = PhotoHubDocumentIdParser.parsePhotoHash(documentId)
            ?: throw FileNotFoundException("Not a photo document: $documentId")

        val store = LocalProxyStore.getInstance(ctx)
        var bytes = store.previewData(hash)
        if (bytes == null) {
            val photo = loadCatalog(ctx, refreshIfEmpty = false)
                .firstOrNull { it.hash.equals(hash, ignoreCase = true) }
            if (photo != null && photo.isVideo && photo.needsProxy) {
                throw FileNotFoundException("Video thumbnail not generated yet")
            }
            val settings = AppSettings.getInstance(ctx)
            if (settings.current.isSignedIn && settings.current.normalizedBaseUrl != null) {
                bytes = runBlocking {
                    runCatching {
                        val raw = PhotoHubApiClient(ctx, settings).downloadPhotoPreviewData(hash)
                        store.cacheDownloadedPreviewData(raw, hash) ?: raw
                    }.getOrNull()
                }
            }
        }

        val data = bytes ?: throw FileNotFoundException("Thumbnail unavailable")
        val thumbDir = File(ctx.cacheDir, "photohub_doc_thumbs").apply { mkdirs() }
        val thumbFile = File(thumbDir, "${hash.take(24)}.jpg")
        thumbFile.writeBytes(data)
        val pfd = ParcelFileDescriptor.open(thumbFile, ParcelFileDescriptor.MODE_READ_ONLY)
        return AssetFileDescriptor(pfd, 0L, AssetFileDescriptor.UNKNOWN_LENGTH)
    }

    override fun openDocument(
        documentId: String?,
        mode: String?,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        if (mode != null && mode.contains('w')) {
            throw FileNotFoundException("Write mode is not supported")
        }
        signal?.throwIfCanceled()
        val ctx = context ?: throw FileNotFoundException("Context unavailable")
        val settings = AppSettings.getInstance(ctx)
        if (!settings.current.isSignedIn || settings.current.normalizedBaseUrl == null) {
            throw FileNotFoundException("Sign in to photoHub first")
        }

        val hash = PhotoHubDocumentIdParser.parsePhotoHash(documentId)
            ?: throw FileNotFoundException("Unknown documentId: $documentId")

        val catalog = loadCatalog(ctx, refreshIfEmpty = false)
        val photo = catalog.firstOrNull { it.hash.equals(hash, ignoreCase = true) }
        val apiClient = PhotoHubApiClient(ctx, settings)

        val jobScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val deferred = jobScope.async {
            OriginalDownloadCache.getOrFetchOriginal(
                context = ctx,
                apiClient = apiClient,
                masterHash = hash,
                preferredFilename = photo?.originalName,
                expectedSizeBytes = photo?.size
            ).first
        }

        signal?.setOnCancelListener {
            deferred.cancel(CancellationException("Cancelled by DocumentsProvider client"))
        }

        val file = try {
            runBlocking { deferred.await() }
        } catch (err: CancellationException) {
            throw android.os.OperationCanceledException(err.message)
        } catch (err: Exception) {
            throw FileNotFoundException("Failed to fetch original from server: ${err.localizedMessage}")
        }

        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    private fun loadCatalog(context: Context, refreshIfEmpty: Boolean): List<ServerPhoto> {
        val settings = AppSettings.getInstance(context)
        val cur = settings.current
        if (!cur.isSignedIn || cur.normalizedBaseUrl == null) return emptyList()

        val store = LocalProxyStore.getInstance(context)
        val cached = store.cachedPhotos(cur.normalizedBaseUrl, cur.apiKeyCacheScope)
        val now = System.currentTimeMillis()
        val shouldRefresh = (cached.isEmpty() && refreshIfEmpty) ||
            (refreshIfEmpty && now - lastServerRefreshMs > 60_000L)

        if (!shouldRefresh) return cached

        val fresh = runBlocking {
            runCatching { PhotoHubApiClient(context, settings).fetchAllServerPhotos(sync = false) }.getOrNull()
        }
        if (fresh != null) {
            lastServerRefreshMs = now
            store.savePhotos(fresh, cur.normalizedBaseUrl, cur.apiKeyCacheScope)
            return fresh
        }
        return cached
    }

    private fun sortedByDateDesc(items: List<ServerPhoto>): List<ServerPhoto> =
        items.sortedWith { a, b ->
            val da = a.parsedCreationDateMs
            val db = b.parsedCreationDateMs
            when {
                da != null && db != null && da != db -> db.compareTo(da)
                da != null && db == null -> -1
                da == null && db != null -> 1
                else -> b.originalName.compareTo(a.originalName)
            }
        }

    private fun addFolderRow(cursor: MatrixCursor, docId: String, name: String) {
        cursor.newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, docId)
            add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR)
            add(Document.COLUMN_DISPLAY_NAME, name)
            add(Document.COLUMN_FLAGS, 0)
            add(Document.COLUMN_SIZE, null)
            add(Document.COLUMN_LAST_MODIFIED, null)
            add(Document.COLUMN_SUMMARY, "Full-resolution server folder")
        }
    }

    private fun addPhotoRow(context: Context, cursor: MatrixCursor, photo: ServerPhoto) {
        val mime = ShareUtils.inferMimeType(File(photo.originalName), fallbackName = photo.originalName)
            .let { if (it == "video/*") "video/mp4" else if (it == "image/*") "image/jpeg" else it }
        val sizeStr = Formatter.formatFileSize(context, photo.size.coerceAtLeast(0L))
        cursor.newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, PhotoHubDocumentIdParser.photoDocId(photo.hash))
            add(Document.COLUMN_MIME_TYPE, mime)
            add(Document.COLUMN_DISPLAY_NAME, photo.originalName)
            add(Document.COLUMN_SIZE, photo.size)
            add(Document.COLUMN_LAST_MODIFIED, photo.parsedCreationDateMs)
            add(Document.COLUMN_FLAGS, Document.FLAG_SUPPORTS_THUMBNAIL)
            add(Document.COLUMN_SUMMARY, "Original · $sizeStr")
        }
    }

    companion object {
        private val DEFAULT_ROOT_PROJECTION = arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_FLAGS,
            Root.COLUMN_ICON,
            Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_MIME_TYPES
        )

        private val DEFAULT_DOCUMENT_PROJECTION = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
            Document.COLUMN_SIZE,
            Document.COLUMN_SUMMARY
        )
    }
}
