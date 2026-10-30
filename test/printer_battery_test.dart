import 'dart:async';

import 'package:d110_studio/printer.dart';
import 'package:d110_studio/printer_battery.dart';
import 'package:d110_studio/printer_connection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/printer-battery');
  late PrinterClient printer;
  late Uint8List response;
  late PrinterBatteryController battery;
  late PrinterConnectionController connection;
  late int queries;
  Completer<Uint8List>? batteryGate;
  Completer<Uint8List>? infoGate;

  setUp(() {
    response = Uint8List.fromList([0, 78]);
    queries = 0;
    batteryGate = null;
    infoGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'adapterState') {
            return {'available': true, 'enabled': true, 'permitted': true};
          }
          if (call.method == 'exchange') {
            final bytes = (call.arguments as Map)['bytes'] as Uint8List;
            if (bytes[2] == 0x20) {
              if (bytes.last == 0xF0) {
                return Uint8List.fromList('D110'.codeUnits);
              }
              return infoGate?.future ?? Uint8List.fromList('V1.0.4'.codeUnits);
            }
            queries++;
            return batteryGate?.future ?? response;
          }
          return null;
        });
    printer = PrinterClient(channel: channel);
    connection = PrinterConnectionController(printer);
    battery = PrinterBatteryController(connection);
  });

  tearDown(() async {
    battery.dispose();
    connection.dispose();
    printer.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'battery percentage uses the second byte, including empty and full',
    () async {
      await printer.connect('C8:48:8A:F6:B8:18');
      for (final percent in [78, 0, 100]) {
        response = Uint8List.fromList([0, percent]);
        expect(await printer.readBatteryPercent(), percent);
      }
    },
  );

  test(
    'invalid or truncated battery data cannot become a displayed level',
    () async {
      for (final bytes in [
        [0, 101],
        [0, 255],
        [0xFF, 50],
        [0],
        <int>[],
      ]) {
        await printer.connect('C8:48:8A:F6:B8:18');
        response = Uint8List.fromList(bytes);
        await expectLater(
          printer.readBatteryPercent(),
          throwsA(
            isA<PrinterException>().having(
              (e) => e.code,
              'code',
              'protocol_error',
            ),
          ),
        );
        expect(printer.connected, isFalse);
      }
    },
  );

  testWidgets('battery monitoring cannot steal the connection handshake', (
    tester,
  ) async {
    battery.setForeground(true);
    await connection.connect('C8:48:8A:F6:B8:18');
    await tester.pump();
    expect(connection.phase, PrinterConnectionPhase.connected);
    expect(battery.percent, 78);
    battery.dispose();
  });

  testWidgets('due battery refresh waits for the whole printer transaction', (
    tester,
  ) async {
    await connection.connect('C8:48:8A:F6:B8:18');
    battery.setForeground(true);
    await tester.pump();
    expect(battery.percent, 78);
    expect(queries, 1);

    infoGate = Completer<Uint8List>();
    final info = printer.info();
    await tester.pump();
    response = Uint8List.fromList([0, 0]);
    await tester.pump(const Duration(seconds: 30));
    expect(queries, 1);
    expect(battery.percent, 78);

    infoGate!.complete(Uint8List.fromList('V1.0.4'.codeUnits));
    await info;
    await tester.pump();
    expect(queries, 2);
    expect(battery.percent, 0);

    await printer.disconnect();
    expect(battery.percent, isNull);
    await tester.pump(const Duration(minutes: 1));
    expect(queries, 2);
    battery.dispose();
  });

  testWidgets('background completion cannot revive a stale battery reading', (
    tester,
  ) async {
    await connection.connect('C8:48:8A:F6:B8:18');
    batteryGate = Completer<Uint8List>();
    battery.setForeground(true);
    await tester.pump();
    expect(queries, 1);
    battery.setForeground(false);
    batteryGate!.complete(Uint8List.fromList([0, 78]));
    await tester.pump(const Duration(minutes: 1));
    expect(battery.percent, isNull);
    expect(queries, 1);

    batteryGate = null;
    response = Uint8List.fromList([0, 25]);
    battery.setForeground(true);
    await tester.pump();
    expect(battery.percent, 25);
    expect(queries, 2);
    battery.setForeground(false);
    await tester.pump(const Duration(minutes: 1));
    expect(queries, 2);
    battery.dispose();
  });

  testWidgets('history contains real readings and never mixes printers', (
    tester,
  ) async {
    battery.setForeground(true);
    await connection.connect('C8:48:8A:F6:B8:18');
    await tester.pump();
    expect(battery.samples.map((sample) => sample.percent), [78]);
    response = Uint8List.fromList([0, 25]);
    battery.refresh();
    await tester.pump();
    expect(battery.samples.map((sample) => sample.percent), [78, 25]);

    await connection.disconnect();
    expect(battery.percent, isNull);
    expect(battery.samples.map((sample) => sample.percent), [78, 25]);
    await connection.connect('C8:48:8A:F6:B8:18');
    await tester.pump();
    expect(battery.samples.map((sample) => sample.percent), [78, 25, 25]);

    response = Uint8List.fromList([0, 50]);
    await connection.connect('C8:48:8A:F6:B8:19');
    await tester.pump();
    expect(battery.percent, 50);
    expect(battery.samples.map((sample) => sample.percent), [50]);
    battery.dispose();
  });
}
