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
            // decodeFile preserves an embedded Ultra HDR gainmap (API 34+);
            // on older devices it just decodes the SDR base layer.
            imageView.setImageBitmap(BitmapFactory.decodeFile(path))
        }
    }

    override fun getView(): View = imageView

    override fun dispose() {}
}
