import 'dart:async';
import 'dart:io';

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

Future<void>? _adsReady;

/// Completes once the App Tracking Transparency prompt (iOS) has been
/// answered and the Mobile Ads SDK has been initialized. Every ad request
/// awaits this, so no ad — and thus no tracking data — goes out before the
/// user has made their ATT choice.
Future<void> get adsReady => _adsReady ??= _initAds();

Future<void> _initAds() async {
  if (Platform.isIOS) {
    // iOS 15以降、アプリがアクティブになる前に要求するとダイアログが出ずに
    // notDeterminedのまま返るため、resumedになるまで待ってから要求する。
    await _waitUntilResumed();
    try {
      if (await AppTrackingTransparency.trackingAuthorizationStatus ==
          TrackingStatus.notDetermined) {
        await AppTrackingTransparency.requestTrackingAuthorization();
      }
    } catch (_) {
      // ATTの取得に失敗しても広告自体は(非パーソナライズで)出せるので続行する。
    }
  }
  await MobileAds.instance.initialize();
}

Future<void> _waitUntilResumed() async {
  final binding = WidgetsBinding.instance;
  if (binding.lifecycleState == AppLifecycleState.resumed) return;
  final completer = Completer<void>();
  final listener = AppLifecycleListener(onResume: completer.complete);
  await completer.future;
  listener.dispose();
}
