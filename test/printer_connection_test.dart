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
  late List<bool> connectionPermissions;
  var revokePermissionDuringConnect = false;
  var nativePermissionRequests = 0;
  String? saved;
  var enabled = true;
  var permitted = true;
  var available = true;
  var model = 'D110';
  var enableResult = 'enabled';
  Object? connectFailure;
  Completer<void>? connectGate;

  Future<void> event(String method, [Object? arguments]) async {
    final delivered = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      (_) => delivered.complete(),
    );
    await delivered.future;
  }

  Future<void> disconnected() => event('disconnected');

  setUp(() {
    calls = [];
    connectionPermissions = [];
    revokePermissionDuringConnect = false;
    nativePermissionRequests = 0;
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
          final requestPermission =
              (call.arguments as Map)['requestPermission'] as bool? ?? true;
          connectionPermissions.add(requestPermission);
          if (revokePermissionDuringConnect) {
            permitted = false;
            if (requestPermission) nativePermissionRequests++;
            throw PlatformException(code: 'permission_denied');
          }
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
      expect(controller.address, goodAddress);
      expect(printer.connected, isTrue);
      await controller.restore();
      expect(calls.where((call) => call == 'connect'), hasLength(1));
      expect(connectionPermissions, [false]);
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
      expect(connectionPermissions, [false]);
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

  testWidgets('declined enable cancels an already pending retry', (
    tester,
  ) async {
    connectFailure = PlatformException(code: 'timeout');
    await controller.restore();
    enableResult = 'declined';
    await controller.enableAndReconnect();
    await tester.pump(const Duration(hours: 1));
    expect(controller.phase, PrinterConnectionPhase.enableDeclined);
    expect(calls.where((call) => call == 'connect'), hasLength(1));
  });

  testWidgets(
    'opened settings suspends retries until returning to foreground',
    (tester) async {
      connectFailure = PlatformException(code: 'timeout');
      await controller.restore();
      enableResult = 'settings_opened';
      await controller.enableAndReconnect();
      await tester.pump(const Duration(minutes: 1));
      expect(calls.where((call) => call == 'connect'), hasLength(1));
      connectFailure = null;
      controller.setForeground(false);
      controller.setForeground(true);
      await tester.pump();
      expect(printer.connected, isTrue);
    },
  );

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

  test(
    'passive connect refuses a permission prompt after permission is revoked',
    () async {
      revokePermissionDuringConnect = true;
      await controller.restore();
      expect(controller.phase, PrinterConnectionPhase.permissionDenied);
      expect(printer.connected, isFalse);
      expect(connectionPermissions, [false]);
      expect(nativePermissionRequests, 0);
      expect(saved, goodAddress);

      revokePermissionDuringConnect = false;
      permitted = true;
      final connected = Completer<void>();
      void observe() {
        if (controller.connected && !connected.isCompleted) {
          connected.complete();
        }
      }

      controller.addListener(observe);
      try {
        await event('adapterChanged', {
          'available': true,
          'enabled': true,
          'permitted': true,
        });
        await connected.future.timeout(const Duration(seconds: 5));
      } finally {
        controller.removeListener(observe);
      }
      expect(printer.connected, isTrue);
      expect(controller.phase, PrinterConnectionPhase.connected);
      expect(connectionPermissions, [false, false]);
      expect(nativePermissionRequests, 0);
      expect(calls, isNot(contains('requestEnableBluetooth')));
    },
  );

  test(
    'successful explicit connection refreshes previously missing permission',
    () async {
      permitted = false;
      await controller.restore();
      expect(controller.phase, PrinterConnectionPhase.permissionRequired);
      permitted = true;
      await controller.connect(otherAddress);
      expect(controller.phase, PrinterConnectionPhase.connected);
      expect(controller.address, otherAddress);
      expect(saved, otherAddress);
      expect(printer.connected, isTrue);
      expect(connectionPermissions, [true]);
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

  testWidgets(
    'unreachable saved printer retries passively and stops after handshake',
    (tester) async {
      connectFailure = PlatformException(code: 'timeout');
      await controller.restore();
      expect(controller.phase, PrinterConnectionPhase.unreachable);
      expect(calls.where((call) => call == 'connect'), hasLength(1));
      expect(saved, goodAddress);
      await tester.pump(const Duration(milliseconds: 2999));
      expect(calls.where((call) => call == 'connect'), hasLength(1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(calls.where((call) => call == 'connect'), hasLength(2));
      connectFailure = null;
      await tester.pump(const Duration(seconds: 3));
      expect(printer.connected, isTrue);
      expect(controller.phase, PrinterConnectionPhase.connected);
      await tester.pump(const Duration(hours: 1));
      expect(calls.where((call) => call == 'connect'), hasLength(3));
      expect(calls, isNot(contains('devices')));
      expect(calls, isNot(contains('requestEnableBluetooth')));
      expect(calls, isNot(contains('write')));
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
          {
            'name': 'D110',
            'address': goodAddress,
            'classic': true,
            'spp': true,
          },
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
    'transport disconnect schedules reconnect without immediate IO or print replay',
    () async {
      await controller.restore();
      final connected = Completer<void>();
      void observe() {
        if (controller.connected && !connected.isCompleted) {
          connected.complete();
        }
      }

      controller.addListener(observe);
      final before = calls.length;
      await disconnected();
      expect(printer.connected, isFalse);
      expect(controller.phase, PrinterConnectionPhase.disconnected);
      expect(calls.length, before);
      try {
        await connected.future.timeout(const Duration(seconds: 10));
      } finally {
        controller.removeListener(observe);
      }
      expect(printer.connected, isTrue);
      expect(controller.phase, PrinterConnectionPhase.connected);
      expect(calls.where((call) => call == 'connect'), hasLength(2));
      expect(calls, isNot(contains('write')));
      expect(calls, isNot(contains('requestEnableBluetooth')));
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
