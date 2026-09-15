import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'convert_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
    await MobileAds.instance.initialize();
  }
  runApp(const HdrConverterApp());
}

class HdrConverterApp extends StatelessWidget {
  const HdrConverterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HDR converter',
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
