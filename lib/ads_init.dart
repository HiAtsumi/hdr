import 'dart:io';

import 'package:google_mobile_ads/google_mobile_ads.dart';

Future<void>? _adsReady;

/// Completes once the Mobile Ads SDK has been initialized. Every ad request
/// awaits this.
Future<void> get adsReady => _adsReady ??= MobileAds.instance.initialize();

/// The request every ad load uses. On iOS the app doesn't track users (no
/// App Tracking Transparency prompt, no IDFA), so only non-personalized ads
/// are requested there.
AdRequest get adRequest => AdRequest(nonPersonalizedAds: Platform.isIOS);
