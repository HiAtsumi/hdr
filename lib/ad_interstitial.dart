import 'dart:io';

import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_banner.dart' show isAdsSupportedPlatform;

// Google公式のインタースティシャル広告ユニットID。上がテスト用で下が実ID。
// https://developers.google.com/admob/android/test-ads
// https://developers.google.com/admob/ios/test-ads
String get _testInterstitialAdUnitId => Platform.isAndroid
    //? 'ca-app-pub-3940256099942544/1033173712'
    ? 'ca-app-pub-3974776018579904/2278703575'
    //: 'ca-app-pub-3940256099942544/4411468910';
    : 'ca-app-pub-3974776018579904/5149865761';

/// Loads one interstitial ad ahead of time and shows it on request.
/// `showIfReady` never awaits ad dismissal — it fires the native overlay and
/// returns immediately, so callers can keep running other work (e.g. a video
/// conversion) underneath it instead of waiting for the viewer to close it.
class InterstitialAdController {
  InterstitialAd? _ad;
  bool _loading = false;

  void preload() {
    if (!isAdsSupportedPlatform || _ad != null || _loading) return;
    _loading = true;
    InterstitialAd.load(
      adUnitId: _testInterstitialAdUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _loading = false;
          _ad = ad;
        },
        onAdFailedToLoad: (error) {
          _loading = false;
        },
      ),
    );
  }

  /// Shows the preloaded ad, if one has finished loading. A cold load (no ad
  /// ready yet) is silently skipped rather than delaying the caller.
  void showIfReady() {
    final ad = _ad;
    if (ad == null) return;
    _ad = null;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        preload();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        preload();
      },
    );
    ad.show();
  }

  void dispose() {
    _ad?.dispose();
    _ad = null;
  }
}
