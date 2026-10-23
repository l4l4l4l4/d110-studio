import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'printer.dart';

/// Recoverable connection states for the connection bar, not startup dialogs.
enum PrinterConnectionPhase {
  idle,
  restoring,
  selectPrinter,
  adapterUnavailable,
  bluetoothOff,
  permissionRequired,
  permissionDenied,
  enabling,
  enableDeclined,
  awaitingSettings,
  discovering,
  connecting,
  connected,
  disconnected,
  unreachable,
  unsupportedPrinter,
  storageError,
  failed,
}

/// Own one controller per PrinterClient. The owner disposes both objects.
///
/// Call restore on launch and on resume (or a device-available notification).
/// Each call attempts at most one saved address; there is no timer or print replay.
/// Use discover for the device picker and connect after the picker has finished.
/// Lifecycle/enable/manual operations coalesce while a controller action runs;
/// client single-flight also rejects collisions with print/info/direct discovery.
class PrinterConnectionController extends ChangeNotifier {
  PrinterConnectionController(this.printer) {
    printer.addListener(_onTransportChanged);
  }

  final PrinterClient printer;
  PrinterConnectionPhase _phase = PrinterConnectionPhase.idle;
  String _message = 'Принтер не подключён';
  String? _address;
  String? _lastAddress;
  Future<void>? _flight;
  bool _disposed = false;
  int _adapterGeneration = 0;
  bool _restorePending = false;

  PrinterConnectionPhase get phase => _phase;
  String get message => _message;
  String? get address => _address;
  String? get lastAddress => _lastAddress;
  bool get busy => _flight != null;
  bool get connected => printer.connected;

  void _set(PrinterConnectionPhase phase, String message) {
    if (_disposed) return;
    if (_phase == phase && _message == message) return;
    _phase = phase;
    _message = message;
    notifyListeners();
  }

  bool _blockedByAdapter({bool checkPermission = true}) {
    final adapter = printer.observedAdapter;
    if (adapter == null) return false;
    if (!adapter.available || adapter.enabled == false) {
      _restorePending = false;
      _address = null;
      _set(
        adapter.available
            ? PrinterConnectionPhase.bluetoothOff
            : PrinterConnectionPhase.adapterUnavailable,
        adapter.available
            ? 'Bluetooth выключен'
            : 'Bluetooth-адаптер недоступен',
      );
      return true;
    }
    if (checkPermission && !adapter.permitted) {
      _restorePending = false;
      if (!printer.connected) _address = null;
      _set(
        PrinterConnectionPhase.permissionRequired,
        'Разрешите доступ к Bluetooth при подключении',
      );
      return true;
    }
    if (adapter.permitted && adapter.enabled == null) {
      _restorePending = false;
      if (!printer.connected) _address = null;
      _set(
        PrinterConnectionPhase.failed,
        'Не удалось определить состояние Bluetooth. Проверьте настройки и повторите подключение.',
      );
      return true;
    }
    return false;
  }

  void _drainRestore() {
    if (_disposed || !_restorePending || _flight != null || printer.busy) {
      return;
    }
    _restorePending = false;
    unawaited(restore());
  }

  void _onTransportChanged() {
    if (_disposed) return;
    final changed = _adapterGeneration != printer.adapterGeneration;
    _adapterGeneration = printer.adapterGeneration;
    if (_blockedByAdapter()) return;
    final adapter = printer.observedAdapter;
    if (changed &&
        adapter != null &&
        adapter.permitted &&
        adapter.enabled == true &&
        !printer.connected) {
      _restorePending = true;
    }
    if (_restorePending) {
      _drainRestore();
      return;
    }
    // Failed handshakes are classified by the operation's catch, not by cleanup.
    if (printer.connected) {
      if (changed && _flight == null) {
        _set(PrinterConnectionPhase.connected, 'D110 · $_address');
      }
      return;
    }
    if (_flight != null || printer.busy) return;
    _address = null;
    _set(
      PrinterConnectionPhase.disconnected,
      'Связь с принтером потеряна. Проверьте этикетку перед повторной печатью.',
    );
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool propagateFailure = false,
  }) {
    if (_disposed) return Future<void>.value();
    if (_flight != null) return _flight!;
    // Do not let resume steal a live print/discovery transaction.
    if (printer.busy) return Future<void>.value();
    final completion = Completer<void>();
    _flight = completion.future;
    Object? failure;
    StackTrace? failureStack;
    Future<void>.sync(action)
        .catchError((Object error, StackTrace stack) {
          _failure(error);
          if (propagateFailure) {
            failure = error;
            failureStack = stack;
          }
        })
        .whenComplete(() {
          _flight = null;
          if (!_disposed) notifyListeners();
          if (failure != null) {
            completion.completeError(failure!, failureStack);
          } else {
            completion.complete();
          }
          _drainRestore();
        });
    return completion.future;
  }

  /// Passive until a saved printer and an already-permitted, enabled adapter exist.
  Future<void> restore() => _run(() async {
    if (!printer.connected) {
      _set(
        PrinterConnectionPhase.restoring,
        'Проверяем последнее подключение…',
      );
    }
    _lastAddress = await printer.lastPrinterAddress();
    if (_disposed || !await _adapterReady()) return;
    if (printer.connected) {
      _set(PrinterConnectionPhase.connected, 'D110 · $_address');
      return;
    }
    if (_lastAddress == null) {
      _set(PrinterConnectionPhase.selectPrinter, 'Выберите принтер D110');
      return;
    }
    await _connect(_lastAddress!);
  });

  Future<bool> _adapterReady() async {
    final adapter = await printer.adapterState();
    if (_disposed) return false;
    if (!adapter.available) {
      _set(
        PrinterConnectionPhase.adapterUnavailable,
        'Bluetooth-адаптер недоступен',
      );
      return false;
    }
    if (!adapter.permitted) {
      _set(
        PrinterConnectionPhase.permissionRequired,
        'Разрешите доступ к Bluetooth при подключении',
      );
      return false;
    }
    return !_blockedByAdapter();
  }

  /// Android returns the actual OS prompt result. Desktop settings launch is not
  /// enable success: wait for a later resume/restore to inspect the radio again.
  Future<void> enableAndReconnect() => _run(() async {
    _set(
      PrinterConnectionPhase.enabling,
      'Включите Bluetooth в системном окне…',
    );
    final result = await printer.requestEnableBluetooth();
    if (_disposed) return;
    if (result == BluetoothEnableResult.declined) {
      _set(
        PrinterConnectionPhase.enableDeclined,
        'Включение Bluetooth отменено',
      );
      return;
    }
    if (result == BluetoothEnableResult.settingsOpened) {
      _set(
        PrinterConnectionPhase.awaitingSettings,
        'Включите Bluetooth в настройках и вернитесь в приложение',
      );
      return;
    }
    _lastAddress = await printer.lastPrinterAddress();
    if (_disposed || !await _adapterReady()) return;
    if (_lastAddress == null) {
      _set(PrinterConnectionPhase.selectPrinter, 'Выберите принтер D110');
      return;
    }
    await _connect(_lastAddress!);
  });

  /// Explicit user selection may request Bluetooth permission; restore never does.
  Future<void> connect(String address) => _run(() => _connect(address));

  Future<void> _connect(String address) async {
    _address = null;
    _set(PrinterConnectionPhase.connecting, 'Подключаем D110…');
    await printer.connect(address);
    if (_disposed) return;
    _restorePending = false;
    _address = address.trim().toUpperCase();
    _lastAddress = _address;
    // Native connect may have just obtained Android's Bluetooth permission.
    if (!await _adapterReady()) return;
    _set(PrinterConnectionPhase.connected, 'D110 · $_address');
  }

  Future<List<PrinterDevice>> discover() async {
    var devices = <PrinterDevice>[];
    await _run(() async {
      _set(PrinterConnectionPhase.discovering, 'Ищем Bluetooth-принтеры…');
      devices = await printer.devices();
      if (_disposed || _blockedByAdapter()) return;
      _set(
        printer.connected
            ? PrinterConnectionPhase.connected
            : PrinterConnectionPhase.selectPrinter,
        printer.connected ? 'D110 · $_address' : 'Выберите принтер D110',
      );
    }, propagateFailure: true);
    return devices;
  }

  void _failure(Object error) {
    if (_disposed) return;
    // The native request's error classifies an explicit denial; a cached
    // missing-permission state must not turn it back into an unasked request.
    if (_blockedByAdapter(checkPermission: false)) return;
    final code = switch (error) {
      PrinterException value => value.code,
      PlatformException value => value.code,
      MissingPluginException _ => 'bluetooth_unavailable',
      _ => 'unknown',
    };
    if (!printer.connected) _address = null;
    final (phase, message) = switch (code) {
      'bluetooth_disabled' => (
        PrinterConnectionPhase.bluetoothOff,
        'Bluetooth выключен',
      ),
      'settings_unavailable' => (
        PrinterConnectionPhase.bluetoothOff,
        'Откройте настройки Bluetooth вручную, включите его и вернитесь в приложение',
      ),
      'bluetooth_unavailable' => (
        PrinterConnectionPhase.adapterUnavailable,
        'Bluetooth-адаптер недоступен',
      ),
      'permission_denied' => (
        PrinterConnectionPhase.permissionDenied,
        'Нет разрешения на Bluetooth. Разрешите доступ в настройках приложения.',
      ),
      'unsupported_model' => (
        PrinterConnectionPhase.unsupportedPrinter,
        'Этот принтер не D110. Выберите совместимый принтер.',
      ),
      'file_error' || 'storage_error' => (
        PrinterConnectionPhase.storageError,
        'Не удалось сохранить или прочитать последнее подключение',
      ),
      'timeout' ||
      'io_error' ||
      'bluetooth_error' ||
      'connect_failed' ||
      'invalid_address' ||
      'invalid_argument' => (
        PrinterConnectionPhase.unreachable,
        'D110 недоступен. Включите принтер или выберите его заново.',
      ),
      'disconnected' || 'not_connected' => (
        PrinterConnectionPhase.disconnected,
        'Связь с D110 потеряна. Проверьте этикетку перед повторной печатью.',
      ),
      'busy' => (
        PrinterConnectionPhase.idle,
        'Дождитесь завершения операции принтера',
      ),
      _ => (
        PrinterConnectionPhase.failed,
        'Не удалось подключить принтер. Попробуйте выбрать D110 заново.',
      ),
    };
    _set(phase, message);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    printer.removeListener(_onTransportChanged);
    super.dispose();
  }
}
