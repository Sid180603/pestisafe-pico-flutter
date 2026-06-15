// test/connect_screen_test.dart
// Widget tests for ConnectScreen — verifies the Phase 3 transport picker UI.
//
// These tests pump ConnectScreen in isolation.  BLE plugin calls are avoided
// by never tapping the Scan/Connect buttons; dispose()'s stopScan() is
// guarded with try/catch so it does not throw MissingPluginException.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pestisafe/app_state.dart';
import 'package:pestisafe/connect_screen.dart';

Widget _connectScreen() => ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: const MaterialApp(home: ConnectScreen()),
    );

void main() {
  group('ConnectScreen — transport selector (Phase 3)', () {
    testWidgets('renders Connect Device title', (tester) async {
      await tester.pumpWidget(_connectScreen());
      expect(find.text('Connect Device'), findsOneWidget);
    });

    testWidgets('shows WiFi segment by default', (tester) async {
      await tester.pumpWidget(_connectScreen());
      expect(find.text('WiFi'), findsOneWidget);
    });

    testWidgets('shows BLE segment on non-web', (tester) async {
      // kIsWeb is false in the test environment — BLE segment must be visible.
      await tester.pumpWidget(_connectScreen());
      if (!kIsWeb) {
        expect(find.text('BLE'), findsOneWidget);
      }
    });

    testWidgets('WiFi mode shows Dev Mode switch', (tester) async {
      await tester.pumpWidget(_connectScreen());
      expect(find.text('Dev Mode'), findsOneWidget);
    });

    testWidgets('WiFi mode shows target URI text', (tester) async {
      await tester.pumpWidget(_connectScreen());
      // Default WiFi URI is ws://192.168.4.1:8080/ws
      expect(find.textContaining('192.168.4.1'), findsOneWidget);
    });

    testWidgets('WiFi mode shows Connect button', (tester) async {
      await tester.pumpWidget(_connectScreen());
      expect(find.text('Connect'), findsOneWidget);
    });

    testWidgets('status card shows Not connected initially', (tester) async {
      await tester.pumpWidget(_connectScreen());
      expect(find.text('Not connected'), findsOneWidget);
    });

    testWidgets('Dev Mode toggle switches URI to 127.0.0.1', (tester) async {
      await tester.pumpWidget(_connectScreen());
      // Toggle Dev Mode on.
      await tester.tap(find.byType(Switch));
      await tester.pump();
      // The target URI text should now show the dev-mode address.
      expect(find.text('Target: ws://127.0.0.1:8080/ws'), findsOneWidget);
    });

    testWidgets('switching to BLE hides Dev Mode switch', (tester) async {
      if (kIsWeb) return; // BLE option not shown on web
      await tester.pumpWidget(_connectScreen());
      // Tap the BLE segment.
      await tester.tap(find.text('BLE'));
      await tester.pump();
      // Dev Mode is WiFi-only — should no longer be visible.
      expect(find.text('Dev Mode'), findsNothing);
    });

    testWidgets('switching to BLE shows Scan button', (tester) async {
      if (kIsWeb) return;
      await tester.pumpWidget(_connectScreen());
      await tester.tap(find.text('BLE'));
      await tester.pump();
      expect(find.text('Scan'), findsOneWidget);
    });

    testWidgets('switching to BLE shows no-devices placeholder', (tester) async {
      if (kIsWeb) return;
      await tester.pumpWidget(_connectScreen());
      await tester.tap(find.text('BLE'));
      await tester.pump();
      expect(
        find.textContaining('No BLE devices found'),
        findsOneWidget,
      );
    });

    testWidgets('switching back to WiFi restores Dev Mode switch', (tester) async {
      if (kIsWeb) return;
      await tester.pumpWidget(_connectScreen());
      // Go to BLE then back to WiFi.
      await tester.tap(find.text('BLE'));
      await tester.pump();
      await tester.tap(find.text('WiFi'));
      await tester.pump();
      expect(find.text('Dev Mode'), findsOneWidget);
    });
  });
}
