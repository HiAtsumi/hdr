import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'convert_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
    // Fire-and-forget: never block the first frame on the ad SDK reaching
    // out to the network. Ad widgets/preloads tolerate initialize() still
    // being in flight when they're first requested.
    unawaited(MobileAds.instance.initialize());
    // Full-screen media viewer: hide the status bar and (on Android) the
    // navigation bar. immersiveSticky lets a swipe from the edge reveal
    // them briefly, then they auto-hide again.
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }
  runApp(const HdrConverterApp());
}

class HdrConverterApp extends StatelessWidget {
  const HdrConverterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HDR converter',
      debugShowCheckedModeBanner: false,
      // ロケール未指定だとCJKのフォールバックフォントが中国語(簡体字)向けの
      // 字形で描画されることがあるため、日本語ロケールを明示して漢字の字形を
      // スマホ標準(日本語)にする。
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // ColorScheme.fromSeed(seedColor: Colors.grey)は、MaterialのHCT
      // アルゴリズムにより微妙な色味(ティール寄り)が乗ってしまうため、
      // 無彩色のグレーを直接指定する。
      theme: ThemeData(
        colorScheme: ColorScheme.light(
          primary: Colors.grey.shade800,
          onPrimary: Colors.white,
          secondary: Colors.grey.shade600,
          onSecondary: Colors.white,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.dark(
          primary: Colors.grey.shade300,
          onPrimary: Colors.black,
          secondary: Colors.grey.shade500,
          onSecondary: Colors.black,
        ),
        useMaterial3: true,
      ),
      home: const ConvertPage(),
    );
  }
}
