package com.eonlineservice.hdr

import android.content.Context
import android.net.Uri
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File

private const val VIEW_TYPE_ID = "com.eonlineservice.hdr/hdr_video_player"

/**
 * 連結済みプレビュー動画をHDRの輝度のまま再生するためのPlatform View。
 *
 * Flutterのvideo_playerはデコードしたフレームを一旦SurfaceTexture(オフスクリーンの
 * テクスチャ)へ書き出してから合成するため、その過程でHDRがSDRへトーンマッピング
 * されてしまう。このViewはExoPlayerの出力先を素の[SurfaceView]にすることで、
 * SurfaceFlingerによる直接合成経路に乗せ、HDRの輝度をそのまま画面に反映させる。
 */
class HdrVideoPlayerViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val creationParams = args as? Map<String, Any?>
        return HdrVideoPlayerView(context, messenger, viewId, creationParams)
    }
}

class HdrVideoPlayerView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    creationParams: Map<String, Any?>?,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val frameLayout = FrameLayout(context)
    private val player = ExoPlayer.Builder(context).build()
    private val channel = MethodChannel(messenger, "${VIEW_TYPE_ID}_$viewId")

    init {
        val surfaceView = SurfaceView(context)
        frameLayout.addView(
            surfaceView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        player.setVideoSurfaceView(surfaceView)
        channel.setMethodCallHandler(this)
        player.addListener(
            object : Player.Listener {
                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    reportVideoSize(videoSize)
                }
            },
        )

        val path = creationParams?.get("path") as? String
        val looping = creationParams?.get("looping") as? Boolean ?: false
        val autoplay = creationParams?.get("autoplay") as? Boolean ?: false
        if (path != null) {
            player.setMediaItem(MediaItem.fromUri(Uri.fromFile(File(path))))
            player.repeatMode = if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
            player.playWhenReady = autoplay
            player.prepare()
        }
    }

    // ExoPlayerが実際にデコードしたサイズを都度Dart側へ伝える。
    // SurfaceViewは通常デコーダ側で回転が適用されunappliedRotationDegreesは0に
    // なるが、念のためunappliedRotationDegreesが90/270の場合は幅と高さを
    // 入れ替えて、常に画面表示上の向きのアスペクト比を送る。
    private fun reportVideoSize(videoSize: VideoSize) {
        if (videoSize.width <= 0 || videoSize.height <= 0) return
        val swapped =
            videoSize.unappliedRotationDegrees == 90 || videoSize.unappliedRotationDegrees == 270
        val width =
            (if (swapped) videoSize.height else videoSize.width) * videoSize.pixelWidthHeightRatio
        val height = (if (swapped) videoSize.width else videoSize.height).toFloat()
        channel.invokeMethod(
            "onVideoSize",
            mapOf("width" to width.toDouble(), "height" to height.toDouble()),
        )
    }

    override fun getView(): View = frameLayout

    override fun dispose() {
        channel.setMethodCallHandler(null)
        player.release()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "play" -> {
                player.play()
                result.success(null)
            }
            "pause" -> {
                player.pause()
                result.success(null)
            }
            "setLooping" -> {
                val looping = call.arguments as? Boolean ?: false
                player.repeatMode =
                    if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
