import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

bool get isAdsSupportedPlatform => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

// Google公式のテスト用バナー広告ユニットID。実IDが決まり次第差し替える。
// https://developers.google.com/admob/android/test-ads
// https://developers.google.com/admob/ios/test-ads
String get _testBannerAdUnitId => Platform.isIOS
    ? 'ca-app-pub-3940256099942544/2934735716'
    : 'ca-app-pub-3940256099942544/6300978111';

/// Anchored adaptive banner, meant to sit as the last child of a bottom-
/// aligned Column on every screen. Renders nothing while loading, on
/// failure, or on a platform google_mobile_ads doesn't support (macOS etc.)
/// — it never reserves blank space or shifts layout around.
class AdBanner extends StatefulWidget {
  const AdBanner({super.key});

  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> {
  BannerAd? _bannerAd;
  bool _requested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requested) return;
    _requested = true;
    _loadAd();
  }

  Future<void> _loadAd() async {
    if (!isAdsSupportedPlatform) return;
    final width = MediaQuery.sizeOf(context).width.truncate();
    final size = await AdSize.getLargeAnchoredAdaptiveBannerAdSize(width);
    if (size == null || !mounted) return;

    final ad = BannerAd(
      adUnitId: _testBannerAdUnitId,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted) {
            ad.dispose();
            return;
          }
          setState(() => _bannerAd = ad as BannerAd);
        },
        onAdFailedToLoad: (ad, error) => ad.dispose(),
      ),
    );
    await ad.load();
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _bannerAd;
    if (ad == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      height: ad.size.height.toDouble(),
      alignment: Alignment.center,
      child: AdWidget(ad: ad),
    );
  }
}
