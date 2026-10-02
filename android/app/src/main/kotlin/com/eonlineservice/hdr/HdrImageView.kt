package com.eonlineservice.hdr

import android.content.Context
import android.graphics.BitmapFactory
import android.view.View
import android.widget.ImageView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

private const val VIEW_TYPE_ID = "com.eonlineservice.hdr/hdr_image_view"

/**
 * Displays a still image (Ultra HDR JPEG or a plain JPEG) with its HDR
 * gainmap luminance shown as-is, via a plain [ImageView].
 *
 * Flutter's own `Image` widget renders through Skia's texture pipeline,
 * which doesn't apply an embedded Ultra HDR gainmap — a native View is
 * required, same reasoning as [HdrVideoPlayerView]. The window is already
 * switched to ActivityInfo.COLOR_MODE_HDR in MainActivity.onCreate.
 */
class HdrImageViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val creationParams = args as? Map<String, Any?>
        return HdrImageView(context, creationParams)
    }
}

class HdrImageView(context: Context, creationParams: Map<String, Any?>?) : PlatformView {
    private val imageView = ImageView(context).apply {
        scaleType = ImageView.ScaleType.FIT_CENTER
    }

    init {
        val path = creationParams?.get("path") as? String
        if (path != null) {
            // decodeFile preserves an embedded Ultra HDR gainmap (API 34+),
            // scaled along with the base image by inSampleSize; on older
            // devices it just decodes the SDR base layer.
            val options = BitmapFactory.Options().apply {
                inSampleSize = previewSampleSize(context, path)
            }
            imageView.setImageBitmap(BitmapFactory.decodeFile(path, options))
        }
    }

    // Full-resolution camera photos (e.g. 50MP ≈ 200MB as ARGB_8888) waste
    // memory and can exceed the ~100MB limit RecordingCanvas enforces,
    // crashing on draw. Downsample by a power of two while the result stays
    // at least 2x the screen's long side (the preview can be pinch-zoomed),
    // and always until it fits within MAX_PREVIEW_PIXELS.
    private fun previewSampleSize(context: Context, path: String): Int {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width <= 0 || height <= 0) return 1

        val metrics = context.resources.displayMetrics
        val targetLongSide = maxOf(metrics.widthPixels, metrics.heightPixels) * 2
        val longSide = maxOf(width, height)
        var sampleSize = 1
        while (longSide / (sampleSize * 2) >= targetLongSide ||
            width.toLong() * height / (sampleSize.toLong() * sampleSize) > MAX_PREVIEW_PIXELS
        ) {
            sampleSize *= 2
        }
        return sampleSize
    }

    private companion object {
        // 16M pixels = 64MB as ARGB_8888.
        const val MAX_PREVIEW_PIXELS = 16_000_000L
    }

    override fun getView(): View = imageView

    override fun dispose() {}
}
