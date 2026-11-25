package com.ronova.audio.scanner

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.provider.MediaStore
import android.util.LruCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Collections

/**
 * One row of the on-device music library. The map layout matches `AudioTrack.fromJson` on the
 * Dart side (timestamps are Unix seconds, exactly as MediaStore stores them).
 */
data class ScannedTrack(
    val mediaStoreId: Long,
    val title: String,
    val artist: String,
    val album: String,
    val filePath: String,
    val durationMs: Long,
    val dateAdded: Long,
    val dateModified: Long,
    val fileSize: Long,
) {
    fun toMap(): Map<String, Any?> = hashMapOf(
        "mediaStoreId" to mediaStoreId,
        "title" to title,
        "artist" to artist,
        "album" to album,
        "filePath" to filePath,
        "durationMs" to durationMs,
        "dateAdded" to dateAdded,
        "dateModified" to dateModified,
        "fileSize" to fileSize,
        "sampleRate" to 0,
        "bitDepth" to 0,
        "isFavorite" to false,
    )
}

/**
 * Single-pass MediaStore sweep (one cursor, one projection, no per-row queries) plus a lazy,
 * cached album-art extractor so the library scan itself never touches the files.
 */
class FastMediaStoreScanner(context: Context) {

    private val resolver = context.applicationContext.contentResolver

    private val artCache = object : LruCache<String, ByteArray>(ART_CACHE_BYTES) {
        override fun sizeOf(key: String, value: ByteArray): Int = value.size
    }
    private val knownMissingArt: MutableSet<String> = Collections.synchronizedSet(HashSet())

    /** Scans every real music track. Runs entirely on [Dispatchers.IO]. */
    @Suppress("DEPRECATION")
    suspend fun scanAllTracks(): List<ScannedTrack> = withContext(Dispatchers.IO) {
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.DATE_MODIFIED,
            MediaStore.Audio.Media.SIZE,
        )
        // Real music only: drops ringtones, notifications, alarms and sub-5-second clips.
        val selection =
            "${MediaStore.Audio.Media.IS_MUSIC} != 0 AND ${MediaStore.Audio.Media.DURATION} >= $MIN_DURATION_MS"
        val sortOrder = "${MediaStore.Audio.Media.DATE_ADDED} DESC"

        val cursor = resolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            null,
            sortOrder,
        ) ?: return@withContext emptyList<ScannedTrack>()

        cursor.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val dataCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
            val durationCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val addedCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_ADDED)
            val modifiedCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_MODIFIED)
            val sizeCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)

            val result = ArrayList<ScannedTrack>(c.count.coerceAtLeast(16))
            var row = 0
            while (c.moveToNext()) {
                if (++row % CANCEL_CHECK_INTERVAL == 0) ensureActive()

                val path = c.getString(dataCol)
                if (path.isNullOrBlank()) continue

                val rawTitle = c.getString(titleCol)
                val title = if (rawTitle.isNullOrBlank()) File(path).nameWithoutExtension else rawTitle

                result.add(
                    ScannedTrack(
                        mediaStoreId = c.getLong(idCol),
                        title = title,
                        artist = cleanTag(c.getString(artistCol)),
                        album = cleanTag(c.getString(albumCol)),
                        filePath = path,
                        durationMs = c.getLong(durationCol),
                        dateAdded = c.getLong(addedCol),
                        dateModified = c.getLong(modifiedCol),
                        fileSize = c.getLong(sizeCol),
                    ),
                )
            }
            result
        }
    }

    /**
     * Lazily extracts cover art for one file. Call from a background thread. Results (and misses)
     * are cached in memory, and large images are down-scaled to keep channel payloads small.
     */
    fun extractAlbumArtBytes(filePath: String): ByteArray? {
        if (filePath.isBlank()) return null
        artCache.get(filePath)?.let { return it }
        if (knownMissingArt.contains(filePath)) return null

        val bytes = readEmbeddedArt(filePath) ?: readFolderArt(filePath)
        if (bytes == null) {
            knownMissingArt.add(filePath)
        } else {
            artCache.put(filePath, bytes)
        }
        return bytes
    }

    fun clearArtCache() {
        artCache.evictAll()
        knownMissingArt.clear()
    }

    private fun readEmbeddedArt(filePath: String): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(filePath)
            val raw = retriever.embeddedPicture ?: return null
            return downscale(raw)
        } catch (_: Exception) {
            return null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
                // Nothing useful to do if release fails.
            }
        }
    }

    private fun readFolderArt(filePath: String): ByteArray? {
        val folder = File(filePath).parentFile ?: return null
        for (name in FOLDER_ART_NAMES) {
            val candidate = File(folder, name)
            try {
                if (candidate.isFile && candidate.length() in 1..MAX_FOLDER_ART_BYTES) {
                    return downscale(candidate.readBytes())
                }
            } catch (_: Exception) {
                // Unreadable candidate: try the next name.
            }
        }
        return null
    }

    /** Returns [raw] untouched when it is already small, otherwise a <= 600 px JPEG. */
    private fun downscale(raw: ByteArray): ByteArray? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(raw, 0, raw.size, bounds)
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width <= 0 || height <= 0) return null

        val longest = maxOf(width, height)
        if (raw.size <= SMALL_ART_BYTES && longest <= MAX_ART_PX) return raw

        var sample = 1
        while (longest / (sample * 2) >= MAX_ART_PX) sample *= 2
        val decodeOptions = BitmapFactory.Options().apply { inSampleSize = sample }
        var bitmap: Bitmap = BitmapFactory.decodeByteArray(raw, 0, raw.size, decodeOptions) ?: return raw
        val decodedLongest = maxOf(bitmap.width, bitmap.height)
        if (decodedLongest > MAX_ART_PX) {
            val factor = MAX_ART_PX.toFloat() / decodedLongest
            val scaled = Bitmap.createScaledBitmap(
                bitmap,
                (bitmap.width * factor).toInt().coerceAtLeast(1),
                (bitmap.height * factor).toInt().coerceAtLeast(1),
                true,
            )
            if (scaled !== bitmap) bitmap.recycle()
            bitmap = scaled
        }
        val out = ByteArrayOutputStream(64 * 1024)
        bitmap.compress(Bitmap.CompressFormat.JPEG, 88, out)
        bitmap.recycle()
        return out.toByteArray()
    }

    private fun cleanTag(value: String?): String =
        if (value.isNullOrBlank() || value == "<unknown>") "" else value

    private companion object {
        const val MIN_DURATION_MS = 5000
        const val CANCEL_CHECK_INTERVAL = 500
        const val ART_CACHE_BYTES = 8 * 1024 * 1024
        const val MAX_ART_PX = 600
        const val SMALL_ART_BYTES = 150_000
        const val MAX_FOLDER_ART_BYTES = 6L * 1024 * 1024
        val FOLDER_ART_NAMES = arrayOf(
            "cover.jpg", "cover.png", "folder.jpg", "folder.png",
            "album.jpg", "albumart.jpg", "front.jpg", "front.png",
        )
    }
}
