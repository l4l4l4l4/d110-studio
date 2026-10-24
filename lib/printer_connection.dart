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
/// Restore on launch and use setForeground for every application lifecycle state.
/// While foregrounded, a saved printer is retried after each failed attempt.
/// Passive retries never request permission, enable Bluetooth or replay prints.
/// Hold setSelectingPrinter(true) for the picker lifetime, including its connect.
/// Discovery waits for a controller flight; client single-flight protects other I/O.
class PrinterConnectionController extends ChangeNotifier {
  PrinterConnectionController(this.printer) {
    _adapterGeneration = printer.adapterGeneration;
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
  bool _foreground = true;
  int _foregroundGeneration = 0;
  bool _retryPaused = false;
  bool _selectingPrinter = false;
  bool _connectionWanted = true;
  Timer? _retryTimer;
  static const _retryDelay = Duration(seconds: 3);

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

  /// Only resumed is foreground. In-flight I/O is allowed to settle, not replayed.
  void setForeground(bool active) {
    if (_disposed || _foreground == active) return;
    _foreground = active;
    _foregroundGeneration++;
    _cancelRetry();
    if (!active) {
      _restorePending = false;
      if (_connectionWanted && !printer.connected && _lastAddress != null) {
        if (_phase == PrinterConnectionPhase.unreachable) {
          _set(
            _phase,
            'D110 недоступен. Поиск продолжится при возврате в приложение.',
          );
        } else if (_phase == PrinterConnectionPhase.disconnected) {
          _set(
            _phase,
            'Связь с D110 потеряна. Поиск продолжится при возврате в приложение. Проверьте этикетку перед повторной печатью.',
          );
        }
      }
      return;
    }
    _retryPaused = false;
    _connectionWanted = true;
    _restorePending = true;
    _drainRestore();
  }

  /// Explicit device selection takes priority over passive reconnection.
  void setSelectingPrinter(bool active) {
    if (_disposed || _selectingPrinter == active) return;
    _selectingPrinter = active;
    _cancelRetry();
    if (!active &&
        !_retryPaused &&
        _connectionWanted &&
        !printer.connected &&
        _lastAddress != null) {
      _restorePending = true;
      _drainRestore();
    }
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  bool get _mayRetry {
    final adapter = printer.observedAdapter;
    return !_disposed &&
        _foreground &&
        _connectionWanted &&
        !_selectingPrinter &&
        !_retryPaused &&
        !printer.connected &&
        _lastAddress != null &&
        adapter != null &&
        adapter.available &&
        adapter.permitted &&
        adapter.enabled == true;
  }

  void _scheduleRetry() {
    if (!_mayRetry || _retryTimer != null || _flight != null || printer.busy) {
      return;
    }
    // One timer after completion, never a fixed-rate burst or a failure drain loop.
    _retryTimer = Timer(_retryDelay, () {
      _retryTimer = null;
      if (!_mayRetry || _flight != null || printer.busy) return;
      unawaited(restore());
    });
  }

  bool _blockedByAdapter({bool checkPermission = true}) {
    final adapter = printer.observedAdapter;
    if (adapter == null) return false;
    if (!adapter.available || adapter.enabled == false) {
      _restorePending = false;
      _cancelRetry();
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
      _cancelRetry();
      if (!printer.connected) _address = null;
      _set(
        PrinterConnectionPhase.permissionRequired,
        'Разрешите доступ к Bluetooth при подключении',
      );
      return true;
    }
    if (adapter.permitted && adapter.enabled == null) {
      _restorePending = false;
      _cancelRetry();
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
    if (_disposed ||
        !_foreground ||
        !_connectionWanted ||
        _selectingPrinter ||
        !_restorePending ||
        _flight != null ||
        printer.busy) {
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
    if (!_connectionWanted) {
      if (!printer.connected) {
        _set(
          PrinterConnectionPhase.disconnected,
          'D110 отключён. Подключите его снова или вернитесь в приложение.',
        );
      }
      return;
    }
    final adapter = printer.observedAdapter;
    if (changed &&
        adapter != null &&
        adapter.permitted &&
        adapter.enabled == true) {
      _retryPaused = false;
      if (_foreground && !printer.connected) _restorePending = true;
    }
    // Failed handshakes are classified by the operation's catch, not by cleanup.
    if (printer.connected) {
      _restorePending = false;
      _cancelRetry();
      if (changed && _flight == null) {
        _set(PrinterConnectionPhase.connected, 'D110 · $_address');
      }
      return;
    }
    if (_flight != null || printer.busy) {
      _cancelRetry();
      return;
    }
    if (_restorePending) {
      _drainRestore();
      return;
    }
    if (_retryPaused) return;
    _address = null;
    _set(
      PrinterConnectionPhase.disconnected,
      _foreground && _lastAddress != null
          ? 'Связь с D110 потеряна. Ищем принтер… Проверьте этикетку перед повторной печатью.'
          : 'Связь с принтером потеряна. Проверьте этикетку перед повторной печатью.',
    );
    _scheduleRetry();
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool propagateFailure = false,
  }) {
    _cancelRetry();
    if (_disposed || !_foreground) return Future<void>.value();
    if (_flight != null) return _flight!;
    // Do not let resume steal a live print/discovery transaction.
    if (printer.busy) return Future<void>.value();
    _retryPaused = false;
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
          _scheduleRetry();
        });
    return completion.future;
  }

  /// Passive until a saved printer and an already-permitted, enabled adapter exist.
  Future<void> restore() {
    _cancelRetry();
    if (_disposed || !_foreground || !_connectionWanted || _selectingPrinter) {
      return Future<void>.value();
    }
    if (_flight != null) return _flight!;
    _retryPaused = false;
    if (printer.busy) {
      _restorePending = true;
      return Future<void>.value();
    }
    _restorePending = false;
    final generation = _foregroundGeneration;
    bool active() =>
        !_disposed &&
        _foreground &&
        _connectionWanted &&
        !_selectingPrinter &&
        generation == _foregroundGeneration;
    return _run(() async {
      if (!printer.connected) {
        _set(PrinterConnectionPhase.restoring, 'Ищем последний принтер D110…');
      }
      _lastAddress = await printer.lastPrinterAddress();
      if (!active() || !await _adapterReady() || !active()) return;
      if (printer.connected) {
        _set(PrinterConnectionPhase.connected, 'D110 · $_address');
        return;
      }
      if (_lastAddress == null) {
        _set(PrinterConnectionPhase.selectPrinter, 'Выберите принтер D110');
        return;
      }
      await _connect(_lastAddress!, requestPermission: false);
    });
  }

  Future<bool> _adapterReady() async {
    if (_disposed || !_foreground) return false;
    final adapter = await printer.adapterState();
    if (_disposed || !_foreground) return false;
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
  Future<void> enableAndReconnect() {
    _connectionWanted = true;
    return _run(() async {
      _set(
        PrinterConnectionPhase.enabling,
        'Включите Bluetooth в системном окне…',
      );
      final result = await printer.requestEnableBluetooth();
      if (_disposed || !_foreground) return;
      if (result == BluetoothEnableResult.declined) {
        _retryPaused = true;
        _restorePending = false;
        _set(
          PrinterConnectionPhase.enableDeclined,
          'Включение Bluetooth отменено',
        );
        return;
      }
      if (result == BluetoothEnableResult.settingsOpened) {
        _retryPaused = true;
        _restorePending = false;
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
      await _connect(_lastAddress!, requestPermission: false);
    });
  }

  /// An explicit disconnect pauses recovery until connection or foreground resume.
  Future<void> disconnect() {
    _connectionWanted = false;
    _foregroundGeneration++;
    _restorePending = false;
    _cancelRetry();
    return _run(() async {
      await printer.disconnect();
      if (_disposed || _blockedByAdapter()) return;
      _address = null;
      _set(
        PrinterConnectionPhase.disconnected,
        'D110 отключён. Подключите его снова или вернитесь в приложение.',
      );
    }, propagateFailure: true);
  }

  /// Explicit user selection may request Bluetooth permission; restore never does.
  Future<void> connect(String address) {
    _connectionWanted = true;
    return _run(() => _connect(address));
  }

  Future<void> _connect(String address, {bool requestPermission = true}) async {
    _address = null;
    _set(PrinterConnectionPhase.connecting, 'Подключаем D110…');
    await printer.connect(address, requestPermission: requestPermission);
    if (_disposed) return;
    _restorePending = false;
    _cancelRetry();
    _address = address.trim().toUpperCase();
    _lastAddress = _address;
    // Native connect may have just obtained Android's Bluetooth permission.
    if (!await _adapterReady()) return;
    if (!printer.connected) {
      _address = null;
      _set(
        PrinterConnectionPhase.disconnected,
        'Связь с D110 потеряна. Ищем принтер… Проверьте этикетку перед повторной печатью.',
      );
      return;
    }
    _set(PrinterConnectionPhase.connected, 'D110 · $_address');
  }

  Future<List<PrinterDevice>> discover({bool Function()? isCurrent}) async {
    final current = _flight;
    if (current != null) await current;
    if (isCurrent != null && !isCurrent()) return const [];
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
    _retryPaused = switch (code) {
      'bluetooth_disabled' ||
      'settings_unavailable' ||
      'bluetooth_unavailable' ||
      'permission_denied' ||
      'unsupported_model' ||
      'file_error' ||
      'storage_error' ||
      'invalid_address' ||
      'invalid_argument' ||
      'disposed' => true,
      _ => false,
    };
    if (_retryPaused) {
      _restorePending = false;
      _cancelRetry();
    }
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
        _connectionWanted &&
                _foreground &&
                !_retryPaused &&
                _lastAddress != null
            ? 'D110 недоступен. Включите принтер — продолжаем поиск…'
            : 'D110 недоступен. Проверьте принтер и повторите подключение.',
      ),
      'disconnected' || 'not_connected' => (
        PrinterConnectionPhase.disconnected,
        _connectionWanted &&
                _foreground &&
                !_retryPaused &&
                _lastAddress != null
            ? 'Связь с D110 потеряна. Ищем принтер… Проверьте этикетку перед повторной печатью.'
            : 'Связь с D110 потеряна. Проверьте этикетку перед повторной печатью.',
      ),
      'busy' => (
        PrinterConnectionPhase.idle,
        'Дождитесь завершения операции принтера',
      ),
      _ => (
        PrinterConnectionPhase.failed,
        _connectionWanted &&
                _foreground &&
                !_retryPaused &&
                _lastAddress != null
            ? 'Не удалось подключить D110. Продолжаем поиск…'
            : 'Не удалось подключить принтер. Попробуйте выбрать D110 заново.',
      ),
    };
    _set(phase, message);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _restorePending = false;
    _cancelRetry();
    printer.removeListener(_onTransportChanged);
    super.dispose();
  }
}
