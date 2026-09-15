package com.eonlineservice.hdr_converter

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Gainmap
import android.graphics.Matrix
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileOutputStream
import java.nio.ByteBuffer
import kotlin.math.ln
import kotlin.math.roundToInt

class HdrConverterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel

    // Video decode session state (one at a time).
    private var retriever: MediaMetadataRetriever? = null
    private var videoWidth = 0
    private var videoHeight = 0
    private var videoRotation = 0
    private var videoFps = 30
    private var videoFrameCount = 0
    private var videoFrameIdx = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "hdr_converter/methods")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        closeVideo()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "videoOpen" -> videoOpen(call, result)
                "videoReadFrame" -> videoReadFrame(result)
                "videoClose" -> { closeVideo(); result.success(null) }
                "probeVideoSource" -> probeVideoSource(call, result)
                "probeImage" -> result.success(probeImage())
                "probeImageSource" -> probeImageSource(call, result)
                "convertImage" -> convertImage(call, result)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("hdrConverter", e.message, e.stackTraceToString())
        }
    }

    // ------------------------------------------------------------------
    // Video: SDR frame source (frame-accurate seek via MediaMetadataRetriever
    // — simple and works uniformly across API levels; not a streaming
    // decode, so throughput is seek-bound rather than decode-bound).
    // ------------------------------------------------------------------

    private fun videoOpen(call: MethodCall, result: MethodChannel.Result) {
        closeVideo()
        val path = call.argument<String>("path")!!

        val mmr = MediaMetadataRetriever()
        mmr.setDataSource(path)

        val rawWidth =
            mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
        val rawHeight =
            mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
        val rotation =
            mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        val durationMs =
            mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        if (rawWidth <= 0 || rawHeight <= 0) {
            mmr.release()
            result.error("badDimensions", "could not determine video size", null)
            return
        }

        val fps = probeFps(path)
        val swapped = rotation == 90 || rotation == 270

        retriever = mmr
        // HEVC Main10 needs even dimensions (hdr_video_encoder asserts this).
        videoWidth = (if (swapped) rawHeight else rawWidth).let { it - it % 2 }
        videoHeight = (if (swapped) rawWidth else rawHeight).let { it - it % 2 }
        videoRotation = rotation
        videoFps = fps
        videoFrameCount = ((durationMs * fps) / 1000L).toInt().coerceAtLeast(0)
        videoFrameIdx = 0

        result.success(
            mapOf(
                "width" to videoWidth,
                "height" to videoHeight,
                "fps" to videoFps,
                "frameCount" to videoFrameCount,
            ),
        )
    }

    private fun probeFps(path: String): Int {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/")) continue
                if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                    val fps = format.getInteger(MediaFormat.KEY_FRAME_RATE)
                    if (fps > 0) return fps
                }
                break
            }
        } catch (_: Exception) {
            // fall through to default
        } finally {
            extractor.release()
        }
        return 30
    }

    // Checks the video track's own colour-transfer tag — the exact tag our
    // own encoder writes (COLOR_TRANSFER_HLG / _ST2084), so this also
    // reliably catches our own HDR output.
    private fun probeVideoSource(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        var isHdr = false
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/")) continue
                if (format.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
                    val transfer = format.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
                    isHdr = transfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
                        transfer == MediaFormat.COLOR_TRANSFER_HLG
                }
                break
            }
        } catch (_: Exception) {
            // fall through: treat as not-HDR rather than blocking the user
        } finally {
            extractor.release()
        }
        result.success(
            mapOf("isHdr" to isHdr, "reason" to if (isHdr) "Already an HDR (HLG/PQ) video." else null),
        )
    }

    private fun videoReadFrame(result: MethodChannel.Result) {
        val mmr = retriever
        if (mmr == null || videoFrameIdx >= videoFrameCount) {
            result.success(null)
            return
        }
        val timeUs = videoFrameIdx.toLong() * 1_000_000L / videoFps
        // OPTION_CLOSEST_SYNC only snaps to the nearest keyframe, so most
        // in-between timestamps returned a repeated keyframe — a jerky,
        // "flipbook" result instead of smooth playback. OPTION_CLOSEST
        // actually decodes forward to the exact requested frame (slower per
        // call, but every frame is genuinely distinct).
        var bmp = mmr.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
        if (bmp == null) {
            result.success(null)
            return
        }
        if (videoRotation != 0) {
            val matrix = Matrix()
            matrix.postRotate(videoRotation.toFloat())
            val rotated = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, matrix, true)
            if (rotated !== bmp) bmp.recycle()
            bmp = rotated
        }
        if (bmp.config != Bitmap.Config.ARGB_8888) {
            val converted = bmp.copy(Bitmap.Config.ARGB_8888, false)
            bmp.recycle()
            bmp = converted
        }
        if (bmp.width != videoWidth || bmp.height != videoHeight) {
            val cropped = Bitmap.createBitmap(bmp, 0, 0, videoWidth, videoHeight)
            if (cropped !== bmp) bmp.recycle()
            bmp = cropped
        }

        val buffer = ByteBuffer.allocate(bmp.width * bmp.height * 4)
        bmp.copyPixelsToBuffer(buffer)
        bmp.recycle()
        videoFrameIdx++
        result.success(buffer.array())
    }

    private fun closeVideo() {
        retriever?.release()
        retriever = null
        videoWidth = 0
        videoHeight = 0
        videoRotation = 0
        videoFps = 30
        videoFrameCount = 0
        videoFrameIdx = 0
    }

    // ------------------------------------------------------------------
    // Image: SDR -> Ultra HDR JPEG (gainmap). Requires Android 14 (API 34);
    // older devices (or maxBoost == 1, i.e. no glow requested) get a plain
    // SDR JPEG instead.
    // ------------------------------------------------------------------

    private fun probeImage(): Map<String, Any?> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            mapOf("supported" to true, "reason" to null)
        } else {
            mapOf("supported" to false, "reason" to "Ultra HDR requires Android 14 (API 34) or later")
        }
    }

    // Ultra HDR JPEGs (ours included) carry an embedded gainmap that
    // BitmapFactory exposes via Bitmap.hasGainmap() (API 34+). Devices below
    // API 34 have no way to produce or read that gainmap, so they can't have
    // picked an Ultra HDR source either — treated as not-HDR.
    private fun probeImageSource(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        var isHdr = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val bmp = BitmapFactory.decodeFile(path)
            if (bmp != null) {
                isHdr = bmp.hasGainmap()
                bmp.recycle()
            }
        }
        result.success(
            mapOf("isHdr" to isHdr, "reason" to if (isHdr) "Already an HDR (Ultra HDR) image." else null),
        )
    }

    private fun convertImage(call: MethodCall, result: MethodChannel.Result) {
        val inputPath = call.argument<String>("inputPath")!!
        val outputPath = call.argument<String>("outputPath")!!
        val maxBoost = (call.argument<Double>("maxBoost") ?: 2.0).toFloat().coerceAtLeast(1.0f)
        val glowKnee = (call.argument<Double>("glowKnee") ?: 0.7).toFloat()

        val sdrBitmap = BitmapFactory.decodeFile(inputPath)
            ?: throw IllegalArgumentException("cannot decode image at $inputPath")
        val width = sdrBitmap.width
        val height = sdrBitmap.height

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE || maxBoost <= 1.0f) {
            FileOutputStream(outputPath).use { out -> sdrBitmap.compress(Bitmap.CompressFormat.JPEG, 92, out) }
            sdrBitmap.recycle()
            result.success(null)
            return
        }

        buildAndAttachGainmap(sdrBitmap, width, height, maxBoost, glowKnee)

        FileOutputStream(outputPath).use { out -> sdrBitmap.compress(Bitmap.CompressFormat.JPEG, 92, out) }
        sdrBitmap.recycle()
        result.success(null)
    }

    private fun buildAndAttachGainmap(
        sdrBitmap: Bitmap,
        width: Int,
        height: Int,
        maxBoost: Float,
        glowKnee: Float,
    ) {
        val argb = IntArray(width * height)
        sdrBitmap.getPixels(argb, 0, width, 0, 0, width, height)

        // Single-channel (ALPHA_8) gain map: normalized [0,1] where the
        // framework applies appliedRatio = ratioMin * (ratioMax/ratioMin)^value.
        // Our glow factor k is exactly the whole-pixel HDR/SDR ratio, so pick
        // value = ln(k) / ln(maxBoost) to reproduce k exactly (ratioMin == 1).
        val gain = ByteArray(width * height)
        val logMaxBoost = ln(maxBoost.toDouble()).toFloat()
        for (i in argb.indices) {
            val p = argb[i]
            val r = (p shr 16) and 0xFF
            val g = (p shr 8) and 0xFF
            val b = p and 0xFF
            val whiteness = minOf(r, minOf(g, b)) / 255f
            val k = glowFactor(whiteness, glowKnee, maxBoost)
            val normalized =
                if (logMaxBoost > 0f) (ln(k.toDouble()).toFloat() / logMaxBoost).coerceIn(0f, 1f) else 0f
            gain[i] = (normalized * 255f).roundToInt().coerceIn(0, 255).toByte()
        }

        val gainmapBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ALPHA_8)
        gainmapBitmap.copyPixelsFromBuffer(ByteBuffer.wrap(gain))

        val gainmap = Gainmap(gainmapBitmap)
        gainmap.setRatioMin(1f, 1f, 1f)
        gainmap.setRatioMax(maxBoost, maxBoost, maxBoost)
        gainmap.setGamma(1f, 1f, 1f)
        sdrBitmap.gainmap = gainmap
    }

    // KEEP IN SYNC with hdr_video_encoder's colour maths (glowFactor).
    private companion object {
        fun smoothstep(e0: Float, e1: Float, x: Float): Float {
            if (e1 <= e0) return if (x < e0) 0f else 1f
            val t = ((x - e0) / (e1 - e0)).coerceIn(0f, 1f)
            return t * t * (3f - 2f * t)
        }

        fun glowFactor(whiteness: Float, knee: Float, maxBoost: Float): Float =
            1f + smoothstep(knee, 1f, whiteness) * (maxBoost - 1f)
    }
}
