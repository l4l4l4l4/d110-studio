import 'dart:async';

import 'package:d110_studio/printer.dart';
import 'package:d110_studio/printer_connection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/adapter-events');
  const codec = StandardMethodCodec();
  late PrinterClient printer;
  late PrinterConnectionController connection;
  late bool? enabled;
  late bool permitted;
  late bool nativeConnected;
  late int connections;
  late List<String> calls;
  Completer<List<Object?>>? discoveryGate;
  Completer<void>? discoveryStarted;
  Completer<void>? disconnectGate;
  Completer<void>? disconnectStarted;
  Completer<Uint8List>? exchangeGate;
  Completer<void>? exchangeStarted;

  Future<void> event(String method, [Object? arguments]) async {
    final handled = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) => handled.complete(),
    );
    await handled.future;
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> power(bool value) async {
    enabled = value;
    await event('adapterChanged', {
      'available': true,
      'enabled': value,
      'permitted': true,
    });
  }

  setUp(() {
    enabled = true;
    permitted = true;
    nativeConnected = false;
    connections = 0;
    calls = [];
    discoveryGate = null;
    discoveryStarted = null;
    disconnectGate = null;
    disconnectStarted = null;
    exchangeGate = null;
    exchangeStarted = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'lastPrinterAddress':
              return '01:02:03:04:05:06';
            case 'adapterState':
              return {
                'available': true,
                'enabled': enabled,
                'permitted': permitted,
              };
            case 'disconnect':
              final gate = disconnectGate;
              if (gate != null) {
                disconnectGate = null;
                disconnectStarted?.complete();
                await gate.future;
              }
              if (nativeConnected) {
                nativeConnected = false;
                await event('disconnected');
              }
              return null;
            case 'connect':
              connections++;
              if (nativeConnected) await event('disconnected');
              nativeConnected = true;
              return null;
            case 'devices':
              discoveryStarted?.complete();
              return discoveryGate?.future ?? <Object?>[];
            case 'exchange':
              final gate = exchangeGate;
              if (gate != null) {
                exchangeGate = null;
                exchangeStarted?.complete();
                return gate.future;
              }
              return Uint8List.fromList('D110'.codeUnits);
            default:
              return null;
          }
        });
    printer = PrinterClient(channel: channel);
    connection = PrinterConnectionController(printer);
  });

  tearDown(() async {
    connection.dispose();
    printer.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'resume detects adapter off even when the old transport looked connected',
    () async {
      await connection.restore();
      expect(printer.connected, isTrue);
      enabled = false;
      await connection.restore();
      expect(connection.phase, PrinterConnectionPhase.bluetoothOff);
      expect(printer.connected, isFalse);
    },
  );

  test(
    'power off wins over stale disconnect and power on restores one connection',
    () async {
      await connection.restore();
      await power(false);
      expect(printer.connected, isFalse);
      expect(connection.phase, PrinterConnectionPhase.bluetoothOff);
      await event('disconnected');
      expect(connection.phase, PrinterConnectionPhase.bluetoothOff);
      await power(true);
      if (connection.busy) {
        final settled = Completer<void>();
        void listener() {
          if (connection.busy) return;
          connection.removeListener(listener);
          settled.complete();
        }

        connection.addListener(listener);
        await settled.future;
      }
      expect(printer.connected, isTrue);
      expect(connection.phase, PrinterConnectionPhase.connected);
      expect(connections, 2);
    },
  );

  test('power on waits for active IO to settle before reconnecting', () async {
    await connection.restore();
    final gate = Completer<Uint8List>();
    exchangeGate = gate;
    exchangeStarted = Completer<void>();
    final info = printer.info();
    final failure = expectLater(info, throwsA(isA<PlatformException>()));
    await exchangeStarted!.future;
    await power(false);
    await power(true);
    expect(printer.busy, isTrue);
    expect(connections, 1);
    gate.completeError(PlatformException(code: 'bluetooth_disabled'));
    await failure;
    await Future<void>.delayed(Duration.zero);
    expect(printer.connected, isTrue);
    expect(connection.phase, PrinterConnectionPhase.connected);
    expect(connections, 2);
  });

  test(
    'replacement waits for the old native transport to disconnect',
    () async {
      await connection.restore();
      const replacement = '01:02:03:04:05:07';
      await connection.connect(replacement);
      expect(printer.connected, isTrue);
      expect(connection.phase, PrinterConnectionPhase.connected);
      expect(connection.address, replacement);
      expect(connections, 2);
    },
  );

  test('power off during old transport teardown blocks replacement', () async {
    await connection.restore();
    disconnectGate = Completer<void>();
    final gate = disconnectGate!;
    disconnectStarted = Completer<void>();
    final replacing = connection.connect('01:02:03:04:05:07');
    await Future.any([
      disconnectStarted!.future,
      replacing.then(
        (_) => fail('Replacement skipped the old transport disconnect'),
      ),
    ]);
    await power(false);
    gate.complete();
    await replacing;
    expect(printer.connected, isFalse);
    expect(connection.phase, PrinterConnectionPhase.bluetoothOff);
    expect(connections, 1);
  });

  test('power cycle during teardown restores only the saved printer', () async {
    await connection.restore();
    disconnectGate = Completer<void>();
    final gate = disconnectGate!;
    disconnectStarted = Completer<void>();
    final replacing = connection.connect('01:02:03:04:05:07');
    await disconnectStarted!.future;
    await power(false);
    await power(true);
    expect(connections, 1);
    gate.complete();
    await replacing;
    await Future<void>.delayed(Duration.zero);
    expect(printer.connected, isTrue);
    expect(connection.phase, PrinterConnectionPhase.connected);
    expect(connection.address, '01:02:03:04:05:06');
    expect(connections, 2);
  });

  test('power off wins over a late successful model handshake', () async {
    exchangeGate = Completer<Uint8List>();
    final gate = exchangeGate!;
    exchangeStarted = Completer<void>();
    final restoring = connection.restore();
    await exchangeStarted!.future;
    await power(false);
    gate.complete(Uint8List.fromList('D110'.codeUnits));
    await restoring;
    expect(printer.connected, isFalse);
    expect(connection.phase, PrinterConnectionPhase.bluetoothOff);
    expect(calls, isNot(contains('saveLastPrinterAddress')));
  });

  test('power off wins over a late successful discovery reply', () async {
    discoveryGate = Completer<List<Object?>>();
    discoveryStarted = Completer<void>();
    final discovering = connection.discover();
    await discoveryStarted!.future;
    await power(false);
    expect(connection.phase, PrinterConnectionPhase.bluetoothOff);
    discoveryGate!.complete([
      {
        'name': 'D110',
        'address': '01:02:03:04:05:06',
        'classic': true,
        'spp': true,
      },
    ]);
    expect(await discovering, hasLength(1));
    expect(connection.phase, PrinterConnectionPhase.bluetoothOff);
    expect(connections, 0);
  });

  test('unknown permitted power is recoverable, not Bluetooth off', () async {
    enabled = null;
    await connection.restore();
    expect(connection.phase, PrinterConnectionPhase.failed);
    expect(printer.connected, isFalse);
    expect(connections, 0);
    await power(true);
    expect(connection.phase, PrinterConnectionPhase.connected);
    expect(connections, 1);
  });

  test(
    'unknown power preserves transport without stale connected text',
    () async {
      await connection.restore();
      calls.clear();
      enabled = null;
      await event('adapterChanged', {
        'available': true,
        'enabled': null,
        'permitted': true,
      });
      expect(printer.connected, isTrue);
      expect(connection.phase, PrinterConnectionPhase.failed);
      expect(calls, isEmpty);
      await connection.restore();
      expect(printer.connected, isTrue);
      expect(connection.phase, PrinterConnectionPhase.failed);
      expect(connections, 1);
      await power(true);
      expect(connection.phase, PrinterConnectionPhase.connected);
      expect(connections, 1);
    },
  );

  test('unknown power wins over a late successful discovery reply', () async {
    await connection.restore();
    discoveryGate = Completer<List<Object?>>();
    discoveryStarted = Completer<void>();
    final discovering = connection.discover();
    await discoveryStarted!.future;
    enabled = null;
    await event('adapterChanged', {
      'available': true,
      'enabled': null,
      'permitted': true,
    });
    discoveryGate!.complete([]);
    expect(await discovering, isEmpty);
    expect(printer.connected, isTrue);
    expect(connection.phase, PrinterConnectionPhase.failed);
    expect(connections, 1);
  });

  test(
    'unknown power during handshake preserves transport and guidance',
    () async {
      exchangeGate = Completer<Uint8List>();
      final gate = exchangeGate!;
      exchangeStarted = Completer<void>();
      final restoring = connection.restore();
      await exchangeStarted!.future;
      enabled = null;
      await event('adapterChanged', {
        'available': true,
        'enabled': null,
        'permitted': true,
      });
      gate.complete(Uint8List.fromList('D110'.codeUnits));
      await restoring;
      expect(printer.connected, isTrue);
      expect(connection.phase, PrinterConnectionPhase.failed);
      expect(connections, 1);
    },
  );

  test(
    'permission loss replaces connected guidance without killing transport',
    () async {
      await connection.restore();
      enabled = null;
      permitted = false;
      await event('adapterChanged', {
        'available': true,
        'enabled': null,
        'permitted': false,
      });
      expect(connection.phase, PrinterConnectionPhase.permissionRequired);
      expect(printer.connected, isTrue);
      expect(connections, 1);
      permitted = true;
      await power(true);
      expect(connection.phase, PrinterConnectionPhase.connected);
      expect(connections, 1);
    },
  );

  test(
    'undisclosed power without permission still requires permission',
    () async {
      enabled = null;
      permitted = false;
      await connection.restore();
      expect(connection.phase, PrinterConnectionPhase.permissionRequired);
      expect(connections, 0);
      expect(calls, ['lastPrinterAddress', 'adapterState']);
    },
  );
}
