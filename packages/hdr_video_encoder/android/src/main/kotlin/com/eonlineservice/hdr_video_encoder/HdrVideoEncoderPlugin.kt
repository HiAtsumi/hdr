package com.eonlineservice.hdr_video_encoder

import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CompletableFuture
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt

private const val TAG = "HdrVideoEncoder"
private const val MIME = MediaFormat.MIMETYPE_VIDEO_HEVC

// COLOR_FormatYUVP010 (added API 29). Hard-coded so we compile against lower.
private const val COLOR_FormatYUVP010 = 54

// Interpolated-LUT resolution for the per-pixel colour conversion (see buildLuts).
private const val OETF_LUT_N = 4096
private const val COMP_LUT_N = 4096
private const val COMP_LUT_MAX = 20f

private enum class Transfer { SDR709, HLG, PQ }
private enum class Primaries { REC709, P3, REC2020 }

private sealed class Job {
    class Frame(val sdr: ByteArray) : Job()
    object Stop : Job()
}

class HdrVideoEncoderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel

    private var width = 0
    private var height = 0
    private var fps = 30
    private var frameIdx = 0
    private var transfer = Transfer.HLG
    private var primaries = Primaries.REC2020
    private var maxBoost = 1.0f
    private var glowKnee = 0.7f
    private var saturation = 1.0f
    private var maxCllNits = 0.0f
    private var maxFallNits = 0.0f
    private var sdrWhiteNits = SDR_WHITE_NITS

    // Per-pixel conversion LUTs, (re)built by buildLuts() in setup() once the
    // colour params are known. Replace the per-pixel pow/ln/sqrt in
    // fillInputImage (~25M transcendental calls per 4K frame) — the worker has
    // to keep up with Dart or the frame queue backs up and pins memory.
    private val srgbLin = FloatArray(256) // sRGB byte 0..255 -> linear (exact)
    private val glowK = FloatArray(256) // min-channel byte -> glow factor (exact)
    private var oetfLut = FloatArray(0) // transfer OETF, domain per oetfSqrt
    private var oetfSqrt = false // true: LUT indexed by sqrt(signal) (PQ, steep near black)
    private var hlgCompLut = FloatArray(0) // HLG inverse-OOTF comp factor by BT.2020 luma

    private var encoder: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private var trackIndex = -1

    // Source audio track, copied through to the output muxer verbatim (no
    // decode/re-encode) once the video track's format is known — see setup()
    // and copyAudioTrack(). Null when the source has no audio track.
    private var audioExtractor: MediaExtractor? = null
    private var audioSourceTrackIndex = -1
    private var audioFormat: MediaFormat? = null
    private var muxAudioTrackIndex = -1

    // Holds at most 2 in-flight frames. Each Job.Frame carries a full uncompressed
    // RGBA byte[] (~33 MB at 4K); a deeper queue just pins that much more of the
    // Java heap and OOMs (the encoder is the bottleneck, not throughput).
    private val queue = ArrayBlockingQueue<Job>(2)
    private var worker: Thread? = null
    private var workerResult: CompletableFuture<Void>? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "hdr_video_encoder/methods")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "probe" -> result.success(probe())
                "setup" -> { setup(call); result.success(null) }
                "appendFrame" -> { appendFrame(call); result.success(null) }
                "finish" -> { finish(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "method ${call.method} failed", e)
            result.error("hdrEncoder", e.message, Log.getStackTraceString(e))
        }
    }

    private fun probe(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < 29) {
            return mapOf("supported" to false, "reason" to "requires Android 10 (API 29)")
        }
        val list = MediaCodecList(MediaCodecList.ALL_CODECS)
        for (info in list.codecInfos) {
            if (!info.isEncoder) continue
            if (info.supportedTypes.none { it.equals(MIME, true) }) continue
            val caps = try { info.getCapabilitiesForType(MIME) } catch (_: Exception) { continue }
            val hasMain10 = caps.profileLevels.any { it.profile == CodecProfileLevel.HEVCProfileMain10 }
            val hasP010 = caps.colorFormats.any { it == COLOR_FormatYUVP010 }
            if (hasMain10 && hasP010) {
                return mapOf("supported" to true, "reason" to null)
            }
        }
        return mapOf("supported" to false, "reason" to "no HEVC Main10 / P010 encoder")
    }

    private fun setup(call: MethodCall) {
        width = call.argument<Int>("width")!!
        height = call.argument<Int>("height")!!
        fps = call.argument<Int>("fps")!!
        frameIdx = 0
        val bitrate = call.argument<Int>("videoBitrate")!!
        val filepath = call.argument<String>("filepath")!!
        val inputPath = call.argument<String>("inputPath")
        maxBoost = (call.argument<Double>("maxBoost") ?: 1.0).toFloat().coerceAtLeast(1.0f)
        glowKnee = (call.argument<Double>("glowKnee") ?: 0.7).toFloat()
        saturation = (call.argument<Double>("saturation") ?: 1.0).toFloat()
            .coerceAtLeast(0.001f)
        maxCllNits = (call.argument<Double>("maxContentLightLevel") ?: 0.0).toFloat()
        maxFallNits = (call.argument<Double>("maxFrameAverageLightLevel") ?: 0.0).toFloat()
        sdrWhiteNits = (call.argument<Double>("sdrWhiteNits") ?: SDR_WHITE_NITS.toDouble()).toFloat()
        transfer = when (call.argument<String>("transfer")) {
            "sdrRec709" -> Transfer.SDR709
            "pq" -> Transfer.PQ
            else -> Transfer.HLG
        }
        primaries = when (call.argument<String>("primaries")) {
            "rec709" -> Primaries.REC709
            "displayP3" -> Primaries.P3
            else -> Primaries.REC2020
        }
        if (transfer == Transfer.SDR709) primaries = Primaries.REC709

        buildLuts()

        File(filepath).let { if (it.exists()) it.delete() }

        val format = MediaFormat.createVideoFormat(MIME, width, height).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_COLOR_FORMAT, COLOR_FormatYUVP010)
            setInteger(MediaFormat.KEY_PROFILE, CodecProfileLevel.HEVCProfileMain10)
            if (Build.VERSION.SDK_INT >= 24) {
                setInteger(
                    MediaFormat.KEY_COLOR_STANDARD,
                    when (primaries) {
                        Primaries.REC2020 -> MediaFormat.COLOR_STANDARD_BT2020
                        else -> MediaFormat.COLOR_STANDARD_BT709
                    },
                )
                setInteger(
                    MediaFormat.KEY_COLOR_TRANSFER,
                    when (transfer) {
                        Transfer.PQ -> MediaFormat.COLOR_TRANSFER_ST2084
                        Transfer.HLG -> MediaFormat.COLOR_TRANSFER_HLG
                        Transfer.SDR709 -> MediaFormat.COLOR_TRANSFER_SDR_VIDEO
                    },
                )
                setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            }
            // PQ is an absolute-luminance signal: without static metadata declaring
            // the content's actual peak/average brightness, players commonly assume
            // the nominal PQ ceiling (10000 nits) and apply a generic tone-map tuned
            // for that — crushing contrast on content that's actually only ~200-800
            // nits (washed-out/"foggy" look). HLG doesn't need this (its OOTF is
            // relative to a declared nominal peak, not absolute).
            if (transfer == Transfer.PQ) {
                setByteBuffer(
                    MediaFormat.KEY_HDR_STATIC_INFO,
                    buildHdrStaticInfo(
                        primaries,
                        if (maxCllNits > 0f) maxCllNits else sdrWhiteNits,
                        if (maxFallNits > 0f) maxFallNits else sdrWhiteNits,
                    ),
                )
            }
        }

        val enc = MediaCodec.createEncoderByType(MIME)
        enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        enc.start()
        encoder = enc

        muxer = MediaMuxer(filepath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        muxerStarted = false
        trackIndex = -1

        audioExtractor?.release()
        audioExtractor = null
        audioSourceTrackIndex = -1
        audioFormat = null
        muxAudioTrackIndex = -1
        if (inputPath != null) {
            try {
                val extractor = MediaExtractor()
                extractor.setDataSource(inputPath)
                for (i in 0 until extractor.trackCount) {
                    val fmt = extractor.getTrackFormat(i)
                    val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
                    if (mime.startsWith("audio/")) {
                        extractor.selectTrack(i)
                        audioSourceTrackIndex = i
                        audioFormat = fmt
                        audioExtractor = extractor
                        break
                    }
                }
                if (audioExtractor == null) extractor.release()
            } catch (e: Exception) {
                Log.w(TAG, "audio passthrough setup failed, output will be silent", e)
                audioExtractor?.release()
                audioExtractor = null
                audioFormat = null
            }
        }

        startWorker()
    }

    private fun appendFrame(call: MethodCall) {
        workerResult?.let { if (it.isDone) it.get() } // rethrow worker error
        val sdr = call.argument<ByteArray>("sdrRgba")!!
        // Convert on the worker thread (needs the encoder's own input Image so
        // we honour its plane strides — a tightly-packed buffer shears).
        queue.put(Job.Frame(sdr))
    }

    private fun finish() {
        workerResult?.let { if (it.isDone) it.get() }
        queue.put(Job.Stop)
        workerResult?.get()
    }

    // ----------------------------------------------------------------------
    // Worker: feeds P010 frames into the encoder and muxes the output.
    // ----------------------------------------------------------------------
    private fun startWorker() {
        val future = CompletableFuture<Void>()
        workerResult = future
        val t = Thread {
            try {
                val bufferInfo = MediaCodec.BufferInfo()
                loop@ while (true) {
                    when (val job = queue.take()) {
                        is Job.Stop -> {
                            signalEos()
                            drain(bufferInfo, endOfStream = true)
                            break@loop
                        }
                        is Job.Frame -> {
                            feed(job.sdr)
                            drain(bufferInfo, endOfStream = false)
                        }
                    }
                }
                encoder?.apply { stop(); release() }
                encoder = null
                muxer?.apply { if (muxerStarted) stop(); release() }
                muxer = null
                audioExtractor?.release()
                audioExtractor = null
                future.complete(null)
            } catch (e: Exception) {
                Log.e(TAG, "worker failed", e)
                queue.clear()
                audioExtractor?.release()
                audioExtractor = null
                future.completeExceptionally(e)
            }
        }
        t.isDaemon = true
        t.start()
        worker = t
    }

    // Copies every sample of the source audio track straight into the output
    // muxer (no decode/re-encode — the audio itself is never touched, only
    // remuxed alongside the HDR-converted video). Called once, synchronously
    // on the worker thread, right after the muxer starts: audio tracks are
    // small enough that doing the whole pass in one shot here is simpler than
    // interleaving it with the per-frame video loop.
    private fun copyAudioTrack() {
        val extractor = audioExtractor ?: return
        val mux = muxer ?: return
        val muxTrack = muxAudioTrackIndex
        if (muxTrack < 0) return
        val bufferSize = audioFormat?.let {
            if (it.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) it.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else null
        } ?: (1 shl 20)
        val buffer = java.nio.ByteBuffer.allocate(bufferSize)
        val info = MediaCodec.BufferInfo()
        while (true) {
            buffer.clear()
            val sampleSize = extractor.readSampleData(buffer, 0)
            if (sampleSize < 0) break
            info.offset = 0
            info.size = sampleSize
            info.presentationTimeUs = extractor.sampleTime
            info.flags = extractor.sampleFlags
            mux.writeSampleData(muxTrack, buffer, info)
            extractor.advance()
        }
        extractor.release()
        audioExtractor = null
    }

    private fun feed(sdr: ByteArray) {
        val enc = encoder ?: return
        val idx = enc.dequeueInputBuffer(-1)
        if (idx < 0) return
        val image = enc.getInputImage(idx)
            ?: throw IllegalStateException(
                "MediaCodec.getInputImage returned null for P010 input on this device",
            )
        val filledBytes = fillInputImage(image, sdr)
        // Prefer the codec's own linear input-buffer size; fall back to the span
        // fillInputImage actually wrote (never 0 — that queues an empty frame).
        val size = enc.getInputBuffer(idx)?.capacity()?.takeIf { it > 0 } ?: filledBytes
        val pts = frameIdx.toLong() * 1_000_000L / fps
        enc.queueInputBuffer(idx, 0, size, pts, 0)
        frameIdx++
    }

    private fun signalEos() {
        val enc = encoder ?: return
        val idx = enc.dequeueInputBuffer(-1)
        if (idx >= 0) {
            enc.queueInputBuffer(idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        }
    }

    private fun drain(info: MediaCodec.BufferInfo, endOfStream: Boolean) {
        val enc = encoder ?: return
        val mux = muxer ?: return
        val timeout = if (endOfStream) 10_000L else 0L
        while (true) {
            val status = enc.dequeueOutputBuffer(info, timeout)
            when {
                status == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                }
                status == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    trackIndex = mux.addTrack(enc.outputFormat)
                    val af = audioFormat
                    if (af != null) {
                        try {
                            muxAudioTrackIndex = mux.addTrack(af)
                        } catch (e: Exception) {
                            Log.w(TAG, "muxer rejected source audio format, output will be silent", e)
                            audioExtractor?.release()
                            audioExtractor = null
                            audioFormat = null
                        }
                    }
                    mux.start()
                    muxerStarted = true
                    if (audioFormat != null) {
                        try {
                            copyAudioTrack()
                        } catch (e: Exception) {
                            Log.w(TAG, "audio passthrough failed, output will be silent", e)
                            audioExtractor?.release()
                            audioExtractor = null
                        }
                    }
                }
                status >= 0 -> {
                    val out = enc.getOutputBuffer(status)!!
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                    if (info.size > 0 && muxerStarted) {
                        out.position(info.offset)
                        out.limit(info.offset + info.size)
                        mux.writeSampleData(trackIndex, out, info)
                    }
                    enc.releaseOutputBuffer(status, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    // Builds srgbLin / glowK / oetfLut / hlgCompLut from the current setup args.
    private fun buildLuts() {
        for (i in 0 until 256) {
            val c = i / 255f
            srgbLin[i] = srgbToLinear(c)
            glowK[i] = glowFactor(c, glowKnee, maxBoost)
        }
        oetfLut = FloatArray(OETF_LUT_N + 1)
        if (transfer == Transfer.PQ) {
            // Sample in sqrt(signal) space: the PQ curve is near-vertical near
            // black, so a uniform grid there costs ~10-bit codes of error.
            oetfSqrt = true
            for (i in 0..OETF_LUT_N) {
                val s = i.toFloat() / OETF_LUT_N
                oetfLut[i] = pqOetf(s * s)
            }
        } else {
            oetfSqrt = false
            for (i in 0..OETF_LUT_N) oetfLut[i] = hlgOetf(i.toFloat() / OETF_LUT_N)
        }
        hlgCompLut = if (transfer == Transfer.HLG) {
            FloatArray(COMP_LUT_N + 1) { i ->
                val yl = COMP_LUT_MAX * i / COMP_LUT_N
                minOf(
                    Math.pow(maxOf(yl, 1.0e-4f).toDouble(), -1.0 / 3.0).toFloat(),
                    2.5f,
                )
            }
        } else {
            FloatArray(0)
        }
    }

    // Interpolated OETF lookup (see buildLuts). `signal` is display/scene-linear
    // normalised to [0,1].
    private fun oetf(signal: Float): Float {
        val s = signal.coerceIn(0f, 1f)
        val pos = (if (oetfSqrt) sqrt(s) else s) * OETF_LUT_N
        val i = pos.toInt()
        if (i >= OETF_LUT_N) return oetfLut[OETF_LUT_N]
        return oetfLut[i] + (oetfLut[i + 1] - oetfLut[i]) * (pos - i)
    }

    // Interpolated HLG inverse-OOTF compensation factor for a BT.2020 luma.
    private fun hlgComp(luma: Float): Float {
        val pos = (luma.coerceIn(0f, COMP_LUT_MAX) / COMP_LUT_MAX) * COMP_LUT_N
        val i = pos.toInt()
        if (i >= COMP_LUT_N) return hlgCompLut[COMP_LUT_N]
        return hlgCompLut[i] + (hlgCompLut[i + 1] - hlgCompLut[i]) * (pos - i)
    }

    // ----------------------------------------------------------------------
    // Colour conversion: RGBA8 sRGB (+ boost) -> the encoder's own P010 input
    // Image (4:2:0 10-bit, value in the high 10 bits of each 16-bit LE sample,
    // limited range). Writes through each plane's rowStride/pixelStride so the
    // encoder's alignment padding is respected (a tightly-packed buffer shears
    // the picture and misplaces chroma). Returns the byte span written across
    // the planes (fallback for queueInputBuffer's size arg).
    // ----------------------------------------------------------------------
    private fun fillInputImage(image: Image, sdr: ByteArray): Int {
        val w = width
        val h = height
        val hdr = transfer != Transfer.SDR709

        val yPlane = image.planes[0]
        val yBuf = yPlane.buffer.order(ByteOrder.LITTLE_ENDIAN)
        val yBase = yBuf.position()
        val yRowStride = yPlane.rowStride
        val yPixStride = yPlane.pixelStride // 2 for P010

        // Address each chroma plane by Android's plane contract:
        // pixel (col,row) lives at row*rowStride + col*pixelStride from index 0
        // of that plane's own buffer (a slice starting at the plane's data —
        // for interleaved P010, planes[2] is already offset to Cr).
        val cbPlane = image.planes[1]
        val cbBuf = cbPlane.buffer.order(ByteOrder.LITTLE_ENDIAN)
        val cbBase = cbBuf.position()
        val cbRowStride = cbPlane.rowStride
        val cbPixStride = cbPlane.pixelStride
        val crPlane = image.planes[2]
        val crBuf = crPlane.buffer.order(ByteOrder.LITTLE_ENDIAN)
        val crBase = crBuf.position()
        val crRowStride = crPlane.rowStride
        val crPixStride = crPlane.pixelStride

        // Last writable byte per plane. Take the tighter of the buffer's own
        // limit() and a stride-derived plane size: if getInputImage hands back a
        // buffer whose limit overstates the mapped memory (seen on some P010
        // encoders), an in-bounds-looking putShort segfaults natively instead of
        // throwing. Clamp writes to the safe rectangle and warn.
        val ySafeEnd = minOf(yBuf.limit(), yBase + yRowStride * h)
        val cbSafeEnd = minOf(cbBuf.limit(), cbBase + cbRowStride * (h / 2))
        val crSafeEnd = minOf(crBuf.limit(), crBase + crRowStride * (h / 2))
        if (yBase + 2 > ySafeEnd || cbBase + 2 > cbSafeEnd || crBase + 2 > crSafeEnd) {
            throw IllegalStateException(
                "P010 input Image planes too small on this encoder " +
                    "(y=$yBase/$ySafeEnd cb=$cbBase/$cbSafeEnd cr=$crBase/$crSafeEnd, ${w}x$h)",
            )
        }
        if (sdr.size < w * h * 4) {
            throw IllegalArgumentException("sdrRgba ${sdr.size} < ${w * h * 4} (${w}x$h)")
        }

        var clipped = 0
        val rgb = FloatArray(3)
        for (y in 0 until h) {
            val yRowBase = yBase + y * yRowStride
            val cRow = y / 2
            val cbRowBase = cbBase + cRow * cbRowStride
            val crRowBase = crBase + cRow * crRowStride
            for (x in 0 until w) {
                val p = (y * w + x) * 4
                var r: Float
                var g: Float
                var b: Float
                if (hdr) {
                    val ir = sdr[p].toInt() and 0xFF
                    val ig = sdr[p + 1].toInt() and 0xFF
                    val ib = sdr[p + 2].toInt() and 0xFF
                    val k = glowK[minOf(ir, minOf(ig, ib))]
                    r = srgbLin[ir] * k
                    g = srgbLin[ig] * k
                    b = srgbLin[ib] * k
                    // Luma-preserving saturation nudge in linear light.
                    if (saturation != 1.0f) {
                        val yy = 0.2126f * r + 0.7152f * g + 0.0722f * b
                        r = yy + saturation * (r - yy)
                        g = yy + saturation * (g - yy)
                        b = yy + saturation * (b - yy)
                    }
                    when (primaries) {
                        Primaries.REC2020 -> { lin709to2020(r, g, b, rgb); r = rgb[0]; g = rgb[1]; b = rgb[2] }
                        Primaries.P3 -> { lin709toP3(r, g, b, rgb); r = rgb[0]; g = rgb[1]; b = rgb[2] }
                        Primaries.REC709 -> {}
                    }
                    if (transfer == Transfer.PQ) {
                        val lim = if (maxCllNits > 0f) maxCllNits else 10000f
                        r = oetf(minOf(r * sdrWhiteNits, lim) / 10000f)
                        g = oetf(minOf(g * sdrWhiteNits, lim) / 10000f)
                        b = oetf(minOf(b * sdrWhiteNits, lim) / 10000f)
                    } else { // HLG
                        // Inverse OOTF: a phone renders HLG through an effective
                        // system gamma that crushes mid-tones/shadows below
                        // their SDR appearance. Undo it with one luma-driven
                        // factor (white -> 1.0, hue untouched). exponent
                        // -(g-1)/g, g = 1.5 (-1/3) — tuned up from 1.2.
                        val yl = 0.2627f * r + 0.6780f * g + 0.0593f * b
                        val comp = hlgComp(yl)
                        r = oetf(r * comp * HLG_SDR_WHITE_SCENE)
                        g = oetf(g * comp * HLG_SDR_WHITE_SCENE)
                        b = oetf(b * comp * HLG_SDR_WHITE_SCENE)
                    }
                } else {
                    // SDR checkpoint: keep gamma-encoded sRGB as R'G'B'.
                    r = (sdr[p].toInt() and 0xFF) / 255f
                    g = (sdr[p + 1].toInt() and 0xFF) / 255f
                    b = (sdr[p + 2].toInt() and 0xFF) / 255f
                }

                val yp: Float
                if (primaries == Primaries.REC2020) {
                    yp = 0.2627f * r + 0.6780f * g + 0.0593f * b
                } else {
                    yp = 0.2126f * r + 0.7152f * g + 0.0722f * b
                }
                val y10 = (yp * 876f + 64f).roundToInt().coerceIn(0, 1023)
                val yIdx = yRowBase + x * yPixStride
                if (yIdx in 0..(ySafeEnd - 2)) {
                    yBuf.putShort(yIdx, (y10 shl 6).toShort())
                } else {
                    clipped++
                }

                if (x and 1 == 0 && y and 1 == 0) {
                    val cb: Float
                    val cr: Float
                    if (primaries == Primaries.REC2020) {
                        cb = (b - yp) / 1.8814f
                        cr = (r - yp) / 1.4746f
                    } else {
                        cb = (b - yp) / 1.8556f
                        cr = (r - yp) / 1.5748f
                    }
                    val cb10 = (cb * 896f + 512f).roundToInt().coerceIn(0, 1023)
                    val cr10 = (cr * 896f + 512f).roundToInt().coerceIn(0, 1023)
                    val hx = x / 2
                    val cbIdx = cbRowBase + hx * cbPixStride
                    val crIdx = crRowBase + hx * crPixStride
                    if (cbIdx in 0..(cbSafeEnd - 2)) cbBuf.putShort(cbIdx, (cb10 shl 6).toShort()) else clipped++
                    if (crIdx in 0..(crSafeEnd - 2)) crBuf.putShort(crIdx, (cr10 shl 6).toShort()) else clipped++
                }
            }
        }
        if (clipped > 0) {
            Log.w(
                TAG,
                "fillInputImage clipped $clipped writes past plane bounds " +
                    "(${w}x$h yStride=$yRowStride cbStride=$cbRowStride " +
                    "pix=$yPixStride/$cbPixStride/$crPixStride) — frame may shear; " +
                    "P010 plane layout on this encoder is unexpected",
            )
        }
        // Byte span across the planes (interleaved chroma shares one buffer, so
        // take the max extent, not a sum).
        return maxOf(
            yBase + (h - 1) * yRowStride + w * yPixStride,
            maxOf(
                cbBase + (h / 2 - 1) * cbRowStride + (w / 2) * cbPixStride,
                crBase + (h / 2 - 1) * crRowStride + (w / 2) * crPixStride,
            ),
        )
    }

    // KEEP IN SYNC with lib/src/hdr_color_math.dart (tested in
    // test/hdr_color_math_test.dart against BT.2100 reference points).
    private companion object {
        // Default PQ anchor (BT.2408 reference white), overridable per-export
        // via the "sdrWhiteNits" setup arg (see the sdrWhiteNits field above).
        const val SDR_WHITE_NITS = 203.0f
        // Above the BT.2408 reference-white value (0.26496 = signal 0.75) at
        // 0.5: non-glowing white lands HLG signal ~0.87 (~435 nits direct);
        // reads brighter in an ffmpeg-style HLG->SDR preview. The phone's
        // adaptive tone-map absorbs the anchor anyway.
        const val HLG_SDR_WHITE_SCENE = 0.5f

        fun srgbToLinear(c: Float): Float =
            if (c <= 0.04045f) c / 12.92f else ((c + 0.055f) / 1.055f).pow(2.4f)

        fun smoothstep(e0: Float, e1: Float, x: Float): Float {
            if (e1 <= e0) return if (x < e0) 0f else 1f
            val t = ((x - e0) / (e1 - e0)).coerceIn(0f, 1f)
            return t * t * (3f - 2f * t)
        }

        // HDR glow factor for a pixel, driven by its "whiteness" = the min of
        // its sRGB channels (0..1): 1.0 below knee, ramping to maxBoost at
        // white. The min channel means a saturated colour with one maxed
        // channel (pure amber, pure red) does NOT glow — only near-white pixels
        // do. One factor per pixel so the glow only changes brightness, never
        // hue.
        fun glowFactor(whiteness: Float, knee: Float, maxBoost: Float): Float =
            1f + smoothstep(knee, 1f, whiteness) * (maxBoost - 1f)

        // CIE 1931 xy chromaticity of each primaries set's own R/G/B/white point
        // (D65), used only to describe the "mastering display" in HDR static
        // metadata — not used in the pixel maths above.
        fun chromaticity(p: Primaries): FloatArray = when (p) {
            Primaries.REC709 -> floatArrayOf(0.640f, 0.330f, 0.300f, 0.600f, 0.150f, 0.060f, 0.3127f, 0.3290f)
            Primaries.P3 -> floatArrayOf(0.680f, 0.320f, 0.265f, 0.690f, 0.150f, 0.060f, 0.3127f, 0.3290f)
            Primaries.REC2020 -> floatArrayOf(0.708f, 0.292f, 0.170f, 0.797f, 0.131f, 0.046f, 0.3127f, 0.3290f)
        }

        // Builds the CTA-861.3 "HDR Static Metadata Data Block" payload expected
        // by MediaFormat.KEY_HDR_STATIC_INFO: 1 type byte (0) then 12
        // little-endian uint16s — R/G/B/white-point chromaticity (each x,y in
        // 0.00002 units), max/min display mastering luminance (max: whole
        // cd/m2; min: 0.0001 cd/m2 units), MaxCLL, MaxFALL (both whole cd/m2).
        // A nominal 1000/0.0001 nit mastering display is declared (we have no
        // real reference monitor); MaxCLL/MaxFALL reflect this export's actual
        // content.
        fun buildHdrStaticInfo(p: Primaries, maxCllNits: Float, maxFallNits: Float): java.nio.ByteBuffer {
            val c = chromaticity(p)
            fun chroma(v: Float) = (v * 50000f + 0.5f).toInt().coerceIn(0, 50000)
            val buf = java.nio.ByteBuffer.allocate(25).order(ByteOrder.LITTLE_ENDIAN)
            buf.put(0)
            for (i in 0 until 8) buf.putShort(chroma(c[i]).toShort())
            buf.putShort(1000) // max display mastering luminance, nits
            buf.putShort((0.0001f * 10000f).roundToInt().toShort()) // min, 0.0001 cd/m2 units
            buf.putShort(maxCllNits.roundToInt().coerceIn(0, 65535).toShort())
            buf.putShort(maxFallNits.roundToInt().coerceIn(0, 65535).toShort())
            buf.flip()
            return buf
        }

        fun lin709to2020(r: Float, g: Float, b: Float, out: FloatArray) {
            out[0] = 0.62740f * r + 0.32930f * g + 0.04330f * b
            out[1] = 0.06910f * r + 0.91950f * g + 0.01140f * b
            out[2] = 0.01640f * r + 0.08800f * g + 0.89560f * b
        }

        fun lin709toP3(r: Float, g: Float, b: Float, out: FloatArray) {
            out[0] = 0.822462f * r + 0.177538f * g
            out[1] = 0.033194f * r + 0.966806f * g
            out[2] = 0.017083f * r + 0.072397f * g + 0.910520f * b
        }

        fun pqOetf(l: Float): Float {
            val L = if (l < 0f) 0f else l
            val m1 = 0.1593017578125f
            val m2 = 78.84375f
            val c1 = 0.8359375f
            val c2 = 18.8515625f
            val c3 = 18.6875f
            val lp = L.pow(m1)
            return ((c1 + c2 * lp) / (1f + c3 * lp)).pow(m2)
        }

        fun hlgOetf(e: Float): Float {
            val E = e.coerceIn(0f, 1f)
            val a = 0.17883277f
            val b = 0.28466892f
            val c = 0.55991073f
            return if (E <= 1f / 12f) sqrt(3f * E) else a * ln(12f * E - b) + c
        }
    }
}
