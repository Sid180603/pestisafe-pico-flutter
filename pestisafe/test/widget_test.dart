// test/widget_test.dart
// Widget tests for PestiSafe HomeScreen.
// Note: PestiSafeApp is pumped directly (bypasses main()'s MrlData.load() call)
// so these tests run without requiring asset files to be loaded.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pestisafe/main.dart';
import 'package:pestisafe/app_state.dart';

Widget _appUnderTest() => ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: const PestiSafeApp(),
    );

void main() {
  group('HomeScreen', () {
    testWidgets('renders app title', (tester) async {
      await tester.pumpWidget(_appUnderTest());
      expect(find.text('PestiSafe 2.0'), findsWidgets);
    });

    testWidgets('has Get Started button', (tester) async {
      await tester.pumpWidget(_appUnderTest());
      expect(find.text('Get Started'), findsOneWidget);
    });

    testWidgets('has View History button', (tester) async {
      await tester.pumpWidget(_appUnderTest());
      expect(find.text('View History'), findsOneWidget);
    });

    testWidgets('smoke test — no exceptions on first frame', (tester) async {
      await tester.pumpWidget(_appUnderTest());
      // pumpWidget completing without error is the assertion.
      expect(find.text('PestiSafe 2.0'), findsWidgets);
      expect(find.text('Get Started'), findsOneWidget);
      expect(find.text('View History'), findsOneWidget);
    });
  });
}
