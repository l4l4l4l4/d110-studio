import 'dart:async';

import 'package:d110_studio/printer.dart';
import 'package:d110_studio/printer_connection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const savedAddress = 'AA:BB:CC:DD:EE:01';
const selectedAddress = 'AA:BB:CC:DD:EE:02';
const retryDelay = Duration(seconds: 3);

class LatePrinter extends PrinterClient {
  bool availableNow = false;
  bool linked = false;
  bool operationBusy = false;
  String? saved = savedAddress;
  Object? connectFailure;
  Completer<void>? connectGate;
  Completer<void>? discoveryGate;
  Completer<void>? printGate;
  Completer<void>? addressGate;
  Completer<void>? adapterGate;
  Object? printFailure;
  int attempts = 0;
  int prints = 0;
  int busyRejections = 0;
  int addressReads = 0;
  int generation = 0;
  final attemptedAddresses = <String>[];
  final attemptedPermissions = <bool>[];
  BluetoothAdapterState adapter = const BluetoothAdapterState(
    available: true,
    enabled: true,
    permitted: true,
  );

  @override
  bool get connected => linked;

  @override
  bool get busy => operationBusy;

  @override
  int get adapterGeneration => generation;

  @override
  BluetoothAdapterState? get observedAdapter => adapter;

  Future<T> _operate<T>(Future<T> Function() action) async {
    if (operationBusy) {
      busyRejections++;
      throw const PrinterException('Busy', code: 'busy');
    }
    operationBusy = true;
    try {
      return await action();
    } finally {
      operationBusy = false;
      notifyListeners();
    }
  }

  @override
  Future<BluetoothAdapterState> adapterState() => _operate(() async {
    await adapterGate?.future;
    return adapter;
  });

  @override
  Future<String?> lastPrinterAddress() async {
    addressReads++;
    await addressGate?.future;
    return saved;
  }

  @override
  Future<void> connect(String address, {bool requestPermission = true}) =>
      _operate(() async {
        attempts++;
        attemptedAddresses.add(address);
        attemptedPermissions.add(requestPermission);
        await connectGate?.future;
        if (connectFailure != null) throw connectFailure!;
        if (!availableNow) throw PlatformException(code: 'timeout');
        linked = true;
        saved = address;
        notifyListeners();
      });

  @override
  Future<List<PrinterDevice>> devices() => _operate(() async {
    await discoveryGate?.future;
    return <PrinterDevice>[];
  });

  @override
  Future<void> printRaster(Uint8List packed, int height, {int density = 2}) =>
      _operate(() async {
        prints++;
        await printGate?.future;
        if (printFailure != null) {
          dropTransport();
          throw printFailure!;
        }
      });

  void changeAdapter(BluetoothAdapterState state) {
    adapter = state;
    generation++;
    if (!state.available || state.enabled == false) linked = false;
    notifyListeners();
  }

  void dropTransport() {
    linked = false;
    notifyListeners();
  }
}

void main() {
  late LatePrinter printer;
  late PrinterConnectionController controller;

  setUp(() {
    printer = LatePrinter();
    controller = PrinterConnectionController(printer);
  });

  tearDown(() {
    controller.dispose();
    printer.dispose();
  });

  testWidgets('connects when the saved printer is switched on after startup', (
    tester,
  ) async {
    await controller.restore();
    expect(printer.attempts, 1);
    expect(printer.connected, isFalse);
    expect(controller.lastAddress, savedAddress);
    expect(controller.message, isNot(contains('заново')));
    printer.availableNow = true;
    await tester.pump(const Duration(seconds: 8));
    expect(printer.connected, isTrue);
    expect(controller.phase, PrinterConnectionPhase.connected);
    expect(printer.attemptedAddresses, [savedAddress, savedAddress]);
    expect(printer.attemptedPermissions, [false, false]);
    await tester.pump(const Duration(hours: 1));
    expect(printer.attempts, 2);
  });

  testWidgets(
    'existing adapter generation does not trigger an immediate retry',
    (tester) async {
      controller.dispose();
      printer.changeAdapter(printer.adapter);
      controller = PrinterConnectionController(printer);
      await controller.restore();
      await tester.pump(const Duration(milliseconds: 2999));
      expect(printer.attempts, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(printer.attempts, 2);
      controller.setForeground(false);
    },
  );

  testWidgets('failed foreground attempts have no retry-count limit', (
    tester,
  ) async {
    await controller.restore();
    for (var completed = 1; completed <= 40; completed++) {
      await tester.pump(const Duration(milliseconds: 2999));
      expect(printer.attempts, completed);
      await tester.pump(const Duration(milliseconds: 1));
      expect(printer.attempts, completed + 1);
    }
    expect(controller.lastAddress, savedAddress);
    expect(printer.saved, savedAddress);
    expect(printer.busyRejections, 0);
    printer.availableNow = true;
    await tester.pump(retryDelay);
    expect(controller.connected, isTrue);
  });

  testWidgets(
    'unsupported saved printer and storage failure stop passive retries',
    (tester) async {
      for (final code in ['unsupported_model', 'storage_error']) {
        printer.connectFailure = PlatformException(code: code);
        await controller.restore();
        final attempts = printer.attempts;
        await tester.pump(const Duration(hours: 1));
        expect(printer.attempts, attempts);
        expect(printer.saved, savedAddress);
        expect(controller.lastAddress, savedAddress);
      }
    },
  );

  testWidgets('retry delay starts after failure rather than at attempt start', (
    tester,
  ) async {
    printer.connectGate = Completer<void>();
    final restoring = controller.restore();
    await tester.pump();
    expect(printer.attempts, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(printer.attempts, 1);
    printer.connectGate!.complete();
    await restoring;
    await tester.pump(const Duration(milliseconds: 2999));
    expect(printer.attempts, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(printer.attempts, 2);
    expect(printer.busyRejections, 0);
    controller.setForeground(false);
  });

  testWidgets('background cancels retries and resume reconnects immediately', (
    tester,
  ) async {
    await controller.restore();
    controller.setForeground(false);
    printer.availableNow = true;
    await tester.pump(const Duration(hours: 1));
    await controller.restore();
    expect(printer.attempts, 1);
    controller.setForeground(true);
    await tester.pump();
    expect(printer.connected, isTrue);
    expect(printer.attempts, 2);
  });

  testWidgets('a controller initialized in background performs no restore IO', (
    tester,
  ) async {
    controller.setForeground(false);
    await controller.restore();
    await tester.pump(const Duration(hours: 1));
    expect(printer.addressReads, 0);
    expect(printer.attempts, 0);
    printer.availableNow = true;
    controller.setForeground(true);
    await tester.pump();
    expect(printer.connected, isTrue);
  });

  testWidgets(
    'resume waits for direct client IO before loading saved printer',
    (tester) async {
      controller.setForeground(false);
      printer.discoveryGate = Completer<void>();
      final discovery = printer.devices();
      controller.setForeground(true);
      await tester.pump(const Duration(minutes: 1));
      expect(printer.addressReads, 0);
      expect(printer.attempts, 0);
      printer.availableNow = true;
      printer.discoveryGate!.complete();
      await discovery;
      await tester.pump();
      expect(printer.connected, isTrue);
      expect(printer.busyRejections, 0);
    },
  );

  testWidgets('background during address load prevents a late connection', (
    tester,
  ) async {
    printer.addressGate = Completer<void>();
    final restoring = controller.restore();
    controller.setForeground(false);
    printer.addressGate!.complete();
    await restoring;
    await tester.pump(const Duration(minutes: 1));
    expect(printer.attempts, 0);
    controller.setForeground(true);
    await tester.pump();
    expect(printer.attempts, 1);
    controller.setForeground(false);
  });

  testWidgets('background during adapter query prevents a late connection', (
    tester,
  ) async {
    printer.adapterGate = Completer<void>();
    final restoring = controller.restore();
    await tester.pump();
    controller.setForeground(false);
    printer.adapterGate!.complete();
    await restoring;
    await tester.pump(const Duration(minutes: 1));
    expect(printer.attempts, 0);
  });

  testWidgets('background during a failed attempt prevents further attempts', (
    tester,
  ) async {
    printer.connectGate = Completer<void>();
    final restoring = controller.restore();
    await tester.pump();
    controller.setForeground(false);
    printer.connectGate!.complete();
    await restoring;
    await tester.pump(const Duration(hours: 1));
    expect(printer.attempts, 1);
  });

  testWidgets(
    'disposal cancels a timer and suppresses late attempt completion',
    (tester) async {
      await controller.restore();
      controller.dispose();
      await tester.pump(const Duration(hours: 1));
      expect(printer.attempts, 1);

      controller = PrinterConnectionController(printer);
      printer.connectGate = Completer<void>();
      final restoring = controller.restore();
      await tester.pump();
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.dispose();
      printer.connectGate!.complete();
      await restoring;
      await tester.pump(const Duration(hours: 1));
      expect(printer.attempts, 2);
      expect(notifications, 0);
    },
  );

  testWidgets('manual selection cancels a pending retry to the old printer', (
    tester,
  ) async {
    await controller.restore();
    await tester.pump(const Duration(seconds: 2));
    printer.availableNow = true;
    printer.connectGate = Completer<void>();
    final selecting = controller.connect(selectedAddress);
    await tester.pump(const Duration(minutes: 1));
    expect(printer.attemptedAddresses, [savedAddress, selectedAddress]);
    expect(printer.attemptedPermissions, [false, true]);
    printer.connectGate!.complete();
    await selecting;
    await tester.pump(const Duration(hours: 1));
    expect(controller.address, selectedAddress);
    expect(printer.attempts, 2);
    expect(printer.busyRejections, 0);
  });

  testWidgets(
    'failed manual selection retries only the last verified address',
    (tester) async {
      await controller.restore();
      await controller.connect(selectedAddress);
      expect(printer.saved, savedAddress);
      expect(controller.lastAddress, savedAddress);
      printer.availableNow = true;
      await tester.pump(retryDelay);
      expect(printer.attemptedAddresses, [
        savedAddress,
        selectedAddress,
        savedAddress,
      ]);
      expect(printer.attemptedPermissions, [false, true, false]);
      expect(controller.address, savedAddress);
    },
  );

  testWidgets(
    'discovery postpones retry until three seconds after completion',
    (tester) async {
      await controller.restore();
      printer.discoveryGate = Completer<void>();
      final discovery = controller.discover();
      await tester.pump(const Duration(minutes: 1));
      expect(printer.attempts, 1);
      printer.discoveryGate!.complete();
      await discovery;
      await tester.pump(const Duration(milliseconds: 2999));
      expect(printer.attempts, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(printer.attempts, 2);
      expect(printer.busyRejections, 0);
      controller.setForeground(false);
    },
  );

  testWidgets('direct client discovery defers timer until the client is idle', (
    tester,
  ) async {
    await controller.restore();
    printer.discoveryGate = Completer<void>();
    final discovery = printer.devices();
    await tester.pump(const Duration(minutes: 1));
    expect(printer.attempts, 1);
    printer.discoveryGate!.complete();
    await discovery;
    await tester.pump(const Duration(milliseconds: 2999));
    expect(printer.attempts, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(printer.attempts, 2);
    expect(printer.busyRejections, 0);
    controller.setForeground(false);
  });

  testWidgets('transport loss retries the connection but never a print', (
    tester,
  ) async {
    printer.availableNow = true;
    await controller.restore();
    printer.printGate = Completer<void>();
    printer.printFailure = PlatformException(code: 'timeout');
    final printing = printer.printRaster(Uint8List(12), 1);
    final failure = expectLater(printing, throwsA(isA<PlatformException>()));
    printer.dropTransport();
    await tester.pump(const Duration(minutes: 1));
    expect(printer.attempts, 1);
    printer.printGate!.complete();
    await failure;
    await tester.pump(const Duration(milliseconds: 2999));
    expect(printer.attempts, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(printer.attempts, 2);
    expect(printer.connected, isTrue);
    expect(printer.prints, 1);
    expect(printer.busyRejections, 0);
    await tester.pump(const Duration(hours: 1));
    expect(printer.prints, 1);
    expect(printer.attempts, 2);
  });

  testWidgets('idle transport loss keeps retrying until the printer returns', (
    tester,
  ) async {
    printer.availableNow = true;
    await controller.restore();
    printer.availableNow = false;
    printer.dropTransport();
    expect(controller.phase, PrinterConnectionPhase.disconnected);
    expect(controller.address, isNull);
    await tester.pump(retryDelay);
    await tester.pump(retryDelay);
    expect(printer.attempts, 3);
    printer.availableNow = true;
    await tester.pump(retryDelay);
    expect(printer.connected, isTrue);
    expect(controller.address, savedAddress);
  });

  testWidgets('transport loss in background waits for foreground recovery', (
    tester,
  ) async {
    printer.availableNow = true;
    await controller.restore();
    controller.setForeground(false);
    printer.dropTransport();
    await tester.pump(const Duration(hours: 1));
    expect(printer.attempts, 1);
    controller.setForeground(true);
    await tester.pump();
    expect(printer.connected, isTrue);
    expect(printer.attempts, 2);
  });

  testWidgets(
    'radio off cancels retries and foreground radio on re-arms them',
    (tester) async {
      await controller.restore();
      printer.changeAdapter(
        const BluetoothAdapterState(
          available: true,
          enabled: false,
          permitted: true,
        ),
      );
      await tester.pump(const Duration(hours: 1));
      expect(printer.attempts, 1);
      expect(controller.phase, PrinterConnectionPhase.bluetoothOff);
      printer.availableNow = true;
      printer.changeAdapter(
        const BluetoothAdapterState(
          available: true,
          enabled: true,
          permitted: true,
        ),
      );
      await tester.pump();
      expect(printer.connected, isTrue);
      expect(printer.attempts, 2);
    },
  );

  testWidgets('radio-on notifications cannot reconnect in background', (
    tester,
  ) async {
    await controller.restore();
    controller.setForeground(false);
    printer.availableNow = true;
    printer.changeAdapter(
      const BluetoothAdapterState(
        available: true,
        enabled: true,
        permitted: true,
      ),
    );
    await tester.pump(const Duration(hours: 1));
    expect(printer.attempts, 1);
    controller.setForeground(true);
    await tester.pump();
    expect(printer.connected, isTrue);
  });

  testWidgets(
    'permission denial does not passively prompt or repeat attempts',
    (tester) async {
      printer.connectFailure = PlatformException(code: 'permission_denied');
      await controller.restore();
      expect(controller.phase, PrinterConnectionPhase.permissionDenied);
      await tester.pump(const Duration(hours: 1));
      expect(printer.attempts, 1);
      printer.availableNow = true;
      printer.connectFailure = null;
      controller.setForeground(false);
      controller.setForeground(true);
      await tester.pump();
      expect(printer.connected, isTrue);
    },
  );

  testWidgets(
    'permission loss stops a pending timer until permission returns',
    (tester) async {
      await controller.restore();
      printer.changeAdapter(
        const BluetoothAdapterState(
          available: true,
          enabled: null,
          permitted: false,
        ),
      );
      await tester.pump(const Duration(hours: 1));
      expect(printer.attempts, 1);
      expect(controller.phase, PrinterConnectionPhase.permissionRequired);
      printer.availableNow = true;
      printer.changeAdapter(
        const BluetoothAdapterState(
          available: true,
          enabled: true,
          permitted: true,
        ),
      );
      await tester.pump();
      expect(printer.connected, isTrue);
    },
  );

  testWidgets(
    'absent saved printer and unavailable adapter never arm retries',
    (tester) async {
      printer.saved = null;
      await controller.restore();
      await tester.pump(const Duration(hours: 1));
      expect(printer.addressReads, 1);
      expect(printer.attempts, 0);
      printer.saved = savedAddress;
      printer.changeAdapter(
        const BluetoothAdapterState(
          available: false,
          enabled: null,
          permitted: false,
        ),
      );
      await controller.restore();
      await tester.pump(const Duration(hours: 1));
      expect(printer.attempts, 0);
      expect(controller.phase, PrinterConnectionPhase.adapterUnavailable);
    },
  );
}
