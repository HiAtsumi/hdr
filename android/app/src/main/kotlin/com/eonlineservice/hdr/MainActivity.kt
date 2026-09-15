package com.eonlineservice.hdr

import android.os.Build
import android.os.Bundle
import android.content.pm.ActivityInfo
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // HDRプレビュー用のPlatform View(SurfaceView)がHDR輝度で出力
        // できるよう、ウィンドウをHDR対応のカラーモードにしておく。
        // SDRコンテンツの表示には影響しない。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            window.colorMode = ActivityInfo.COLOR_MODE_HDR
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.eonlineservice.hdr/hdr_video_player",
            HdrVideoPlayerViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.eonlineservice.hdr/hdr_image_view",
            HdrImageViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
    }
}
