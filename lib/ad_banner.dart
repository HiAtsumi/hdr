import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

bool get isAdsSupportedPlatform =>
    !kIsWeb && (Platform.isIOS || Platform.isAndroid);

// Google公式のバナー広告ユニットID。上がテスト用、下が実ID。
// https://developers.google.com/admob/android/test-ads
// https://developers.google.com/admob/ios/test-ads
String get _testBannerAdUnitId => Platform.isAndroid
    //? 'ca-app-pub-3940256099942544/6300978111'
    ? 'ca-app-pub-3974776018579904/2387971054'
    //: 'ca-app-pub-3940256099942544/2934735716';
    : 'ca-app-pub-3974776018579904/6462947431';

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
  int? _loadedWidth;
  // Bumped on every (re)load request; a completion whose generation no
  // longer matches is for a width we've since moved on from (e.g. two
  // quick rotations) and is discarded instead of being shown.
  int _requestGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Called again whenever MediaQuery changes, including on rotation —
    // that's how a width change (and thus the need for a differently-sized
    // adaptive banner) is noticed.
    _maybeReload();
  }

  void _maybeReload() {
    if (!isAdsSupportedPlatform) return;
    final width = MediaQuery.sizeOf(context).width.truncate();
    if (width == _loadedWidth) return;
    final generation = ++_requestGeneration;

    // The loaded banner's native content is a fixed pixel width/height pair
    // (it doesn't stretch or scale with the container), so once the width
    // has actually changed it no longer fits: too wide and it overflows
    // past the new bounds, too narrow and it just looks undersized. Drop it
    // immediately rather than leaving a wrongly-sized banner up while the
    // correctly-sized replacement loads.
    final previous = _bannerAd;
    if (previous != null) {
      setState(() => _bannerAd = null);
      previous.dispose();
    }
    _loadAd(width, generation);
  }

  Future<void> _loadAd(int width, int generation) async {
    final size = await AdSize.getLargeAnchoredAdaptiveBannerAdSize(width);
    if (size == null || !mounted || generation != _requestGeneration) return;

    final ad = BannerAd(
      adUnitId: _testBannerAdUnitId,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (loadedAd) {
          if (!mounted || generation != _requestGeneration) {
            loadedAd.dispose();
            return;
          }
          setState(() {
            _bannerAd = loadedAd as BannerAd;
            _loadedWidth = width;
          });
        },
        onAdFailedToLoad: (failedAd, error) => failedAd.dispose(),
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
