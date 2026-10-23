import 'dart:async';
import 'dart:convert';

import 'package:d110_studio/printer.dart';
import 'package:d110_studio/printer_connection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const goodAddress = 'AA:BB:CC:DD:EE:01';
const otherAddress = 'AA:BB:CC:DD:EE:02';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/printer-reconnect');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PrinterClient printer;
  late PrinterConnectionController controller;
  late List<String> calls;
  String? saved;
  var enabled = true;
  var permitted = true;
  var available = true;
  var model = 'D110';
  var enableResult = 'enabled';
  Object? connectFailure;
  Completer<void>? connectGate;

  Future<void> disconnected() async {
    final delivered = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('disconnected'),
      ),
      (_) => delivered.complete(),
    );
    await delivered.future;
  }

  setUp(() {
    calls = [];
    saved = goodAddress;
    enabled = true;
    permitted = true;
    available = true;
    model = 'D110';
    enableResult = 'enabled';
    connectFailure = null;
    connectGate = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'lastPrinterAddress':
          return saved;
        case 'adapterState':
          return {
            'available': available,
            'enabled': permitted ? enabled : null,
            'permitted': permitted,
          };
        case 'requestEnableBluetooth':
          if (enableResult == 'enabled') {
            enabled = true;
            permitted = true;
          }
          return enableResult;
        case 'connect':
          await connectGate?.future;
          if (connectFailure != null) throw connectFailure!;
          return null;
        case 'exchange':
          return Uint8List.fromList(ascii.encode(model));
        case 'saveLastPrinterAddress':
          saved = (call.arguments as Map)['address'] as String;
          return null;
        case 'disconnect':
          return null;
        case 'devices':
          return <Object>[];
        default:
          throw PlatformException(code: 'unexpected', message: call.method);
      }
    });
    printer = PrinterClient(channel: channel);
    controller = PrinterConnectionController(printer);
  });

  tearDown(() {
    controller.dispose();
    printer.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'restore handshakes before persisting and publishes connected state',
    () async {
      final phases = <PrinterConnectionPhase>[];
      controller.addListener(() => phases.add(controller.phase));
      await controller.restore();
      expect(
        phases,
        containsAllInOrder([
          PrinterConnectionPhase.restoring,
          PrinterConnectionPhase.connecting,
          PrinterConnectionPhase.connected,
        ]),
      );
      expect(calls, [
        'lastPrinterAddress',
        'adapterState',
        'connect',
        'exchange',
        'saveLastPrinterAddress',
      ]);
      expect(controller.address, goodAddress);
      expect(printer.connected, isTrue);
      await controller.restore();
      expect(calls.where((call) => call == 'connect'), hasLength(1));
    },
  );

  test('rejected model preserves last successful printer', () async {
    model = 'B21';
    await controller.connect(otherAddress);
    expect(controller.phase, PrinterConnectionPhase.unsupportedPrinter);
    expect(saved, goodAddress);
    expect(calls, isNot(contains('saveLastPrinterAddress')));
    expect(printer.connected, isFalse);
  });

  test(
    'new client restores address retained by successful handshake',
    () async {
      await controller.connect(otherAddress);
      controller.dispose();
      printer.dispose();
      printer = PrinterClient(channel: channel);
      controller = PrinterConnectionController(printer);
      await controller.restore();
      expect(controller.address, otherAddress);
      expect(saved, otherAddress);
      expect(printer.connected, isTrue);
    },
  );

  test(
    'Bluetooth off does not discover, connect or request enable on restore',
    () async {
      enabled = false;
      await controller.restore();
      expect(controller.phase, PrinterConnectionPhase.bluetoothOff);
      expect(calls, ['lastPrinterAddress', 'adapterState']);
      enableResult = 'declined';
      await controller.enableAndReconnect();
      expect(controller.phase, PrinterConnectionPhase.enableDeclined);
      expect(calls, isNot(contains('connect')));
      expect(saved, goodAddress);
    },
  );

  test(
    'explicit enable reconnects only after platform reports enabled',
    () async {
      enabled = false;
      await controller.enableAndReconnect();
      expect(controller.phase, PrinterConnectionPhase.connected);
      expect(
        calls.indexOf('requestEnableBluetooth'),
        lessThan(calls.indexOf('connect')),
      );
    },
  );

  test('settings launch is not reported as Bluetooth enable success', () async {
    enabled = false;
    enableResult = 'settings_opened';
    await controller.enableAndReconnect();
    expect(controller.phase, PrinterConnectionPhase.awaitingSettings);
    expect(calls, isNot(contains('connect')));
    enabled = true;
    await controller.restore();
    expect(controller.phase, PrinterConnectionPhase.connected);
  });

  test(
    'missing permission stays quiet until explicit connection action',
    () async {
      permitted = false;
      await controller.restore();
      expect(controller.phase, PrinterConnectionPhase.permissionRequired);
      expect(calls, ['lastPrinterAddress', 'adapterState']);
      connectFailure = PlatformException(code: 'permission_denied');
      await controller.connect(goodAddress);
      expect(controller.phase, PrinterConnectionPhase.permissionDenied);
      expect(saved, goodAddress);
    },
  );

  test('unavailable adapter and absent saved address are distinct', () async {
    available = false;
    await controller.restore();
    expect(controller.phase, PrinterConnectionPhase.adapterUnavailable);
    available = true;
    saved = null;
    await controller.restore();
    expect(controller.phase, PrinterConnectionPhase.selectPrinter);
    expect(calls, isNot(contains('connect')));
  });

  test(
    'unreachable saved printer makes one attempt per restore, never loops',
    () async {
      connectFailure = PlatformException(code: 'timeout');
      await controller.restore();
      expect(controller.phase, PrinterConnectionPhase.unreachable);
      expect(calls.where((call) => call == 'connect'), hasLength(1));
      expect(saved, goodAddress);
      await controller.restore();
      expect(calls.where((call) => call == 'connect'), hasLength(2));
    },
  );

  test(
    'missing desktop settings launcher gives manual enable guidance',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'requestEnableBluetooth') {
          throw PlatformException(code: 'settings_unavailable');
        }
        return null;
      });
      await controller.enableAndReconnect();
      expect(controller.phase, PrinterConnectionPhase.bluetoothOff);
      expect(calls, isNot(contains('connect')));
    },
  );

  test('discovery publishes recoverable permission failure', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'devices') {
        throw PlatformException(code: 'permission_denied');
      }
      return null;
    });
    await expectLater(
      controller.discover(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'permission_denied',
        ),
      ),
    );
    expect(controller.phase, PrinterConnectionPhase.permissionDenied);
    expect(printer.busy, isFalse);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'devices') {
        return [
          {'name': 'D110', 'address': goodAddress, 'paired': true},
        ];
      }
      return null;
    });
    final devices = await controller.discover();
    expect(devices.single.address, goodAddress);
    expect(controller.phase, PrinterConnectionPhase.selectPrinter);
  });

  test('storage failure never reports a persisted connection', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'exchange') {
        return Uint8List.fromList(ascii.encode('D110'));
      }
      if (call.method == 'saveLastPrinterAddress') {
        throw PlatformException(code: 'file_error');
      }
      return null;
    });
    await controller.connect(otherAddress);
    expect(controller.phase, PrinterConnectionPhase.storageError);
    expect(saved, goodAddress);
    expect(printer.connected, isFalse);
    expect(calls, contains('disconnect'));
  });

  test(
    'overlapping restore and manual connect share one controller flight',
    () async {
      connectGate = Completer<void>();
      final restoring = controller.restore();
      while (!calls.contains('connect')) {
        await Future<void>.delayed(Duration.zero);
      }
      final selecting = controller.connect(otherAddress);
      expect(calls.where((call) => call == 'connect'), hasLength(1));
      connectGate!.complete();
      await Future.wait([restoring, selecting]);
      expect(saved, goodAddress);
    },
  );

  test(
    'client rejects discovery during handshake rather than racing it',
    () async {
      connectGate = Completer<void>();
      final connecting = printer.connect(goodAddress);
      await expectLater(
        printer.devices(),
        throwsA(isA<PrinterException>().having((e) => e.code, 'code', 'busy')),
      );
      connectGate!.complete();
      await connecting;
      expect(calls, isNot(contains('devices')));
    },
  );

  test(
    'transport disconnect updates listeners without reconnect or print replay',
    () async {
      await controller.restore();
      final before = calls.length;
      await disconnected();
      expect(printer.connected, isFalse);
      expect(controller.phase, PrinterConnectionPhase.disconnected);
      expect(calls.length, before);
    },
  );

  test('disconnect during handshake cannot persist a printer', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'exchange') {
        await disconnected();
        return Uint8List.fromList(ascii.encode('D110'));
      }
      return null;
    });
    await expectLater(
      printer.connect(otherAddress),
      throwsA(isA<PrinterException>()),
    );
    expect(calls, isNot(contains('saveLastPrinterAddress')));
    expect(printer.connected, isFalse);
  });

  test(
    'controller disposal suppresses late state and client closes late connection',
    () async {
      connectGate = Completer<void>();
      var notifications = 0;
      controller.addListener(() => notifications++);
      final connecting = controller.connect(goodAddress);
      while (!calls.contains('connect')) {
        await Future<void>.delayed(Duration.zero);
      }
      controller.dispose();
      printer.dispose();
      final before = notifications;
      connectGate!.complete();
      await connecting;
      expect(notifications, before);
      expect(printer.connected, isFalse);
      expect(calls, contains('disconnect'));
    },
  );
}
