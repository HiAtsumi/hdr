import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hdr/main.dart';

void main() {
  testWidgets('Shows a single Select entry point', (WidgetTester tester) async {
    await tester.pumpWidget(const HdrConverterApp());

    expect(find.text('SDR → HDR'), findsOneWidget);
    expect(find.text('Select'), findsOneWidget);
    expect(find.byIcon(Icons.add_photo_alternate_outlined), findsOneWidget);
  });
}
