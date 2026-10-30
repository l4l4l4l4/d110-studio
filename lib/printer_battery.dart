import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'printer.dart';
import 'printer_connection.dart';

class PrinterBatterySample {
  const PrinterBatterySample(this.at, this.percent);

  final DateTime at;
  final int percent;
}

/// Poll only in the foreground, between complete printer transactions.
class PrinterBatteryController extends ChangeNotifier {
  PrinterBatteryController(this.connection) {
    printer.addListener(_transportChanged);
    connection.addListener(_transportChanged);
  }

  final PrinterConnectionController connection;
  PrinterClient get printer => connection.printer;
  final _samples = <PrinterBatterySample>[];
  late final samples = UnmodifiableListView(_samples);
  String? _sampleAddress;
  int? _percent;
  int? get percent => _percent;
  bool _foreground = false;
  bool _disposed = false;
  bool _due = true;
  bool _refreshing = false;
  int _generation = 0;
  Timer? _timer;

  void _set(int? value) {
    if (_disposed || value == _percent) return;
    _percent = value;
    notifyListeners();
  }

  void _record(int value) {
    if (_sampleAddress != connection.address) {
      _samples.clear();
      _sampleAddress = connection.address;
    }
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(hours: 24));
    _samples.removeWhere((sample) => sample.at.isBefore(cutoff));
    _samples.add(PrinterBatterySample(now, value));
    if (_samples.length > 2880) {
      _samples.removeRange(0, _samples.length - 2880);
    }
    _percent = value;
    notifyListeners();
  }

  /// A tap requests fresh data, but cannot interrupt a print or handshake.
  void refresh() {
    if (_disposed || _refreshing) return;
    _timer?.cancel();
    _timer = null;
    _due = true;
    unawaited(_refresh());
  }

  void setForeground(bool active) {
    if (_disposed || _foreground == active) return;
    _foreground = active;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _due = true;
    if (active) unawaited(_refresh());
  }

  void _transportChanged() {
    if (_disposed) return;
    if (!printer.connected ||
        connection.phase != PrinterConnectionPhase.connected) {
      _generation++;
      _timer?.cancel();
      _timer = null;
      _due = true;
      _set(null);
    } else if (_due) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (_disposed ||
        !_foreground ||
        !_due ||
        _refreshing ||
        !printer.connected ||
        connection.busy ||
        connection.phase != PrinterConnectionPhase.connected ||
        printer.busy) {
      return;
    }
    _due = false;
    _refreshing = true;
    final generation = _generation;
    try {
      final value = await printer.readBatteryPercent();
      if (!_disposed && generation == _generation && printer.connected) {
        _record(value);
      }
    } catch (_) {
      // A failed query has no level; never retain a fabricated or stale reading.
      if (generation == _generation) _set(null);
    } finally {
      _refreshing = false;
      if (!_disposed && _foreground && printer.connected) {
        if (_due) {
          unawaited(_refresh());
        } else {
          _timer = Timer(const Duration(seconds: 30), () {
            _timer = null;
            _due = true;
            unawaited(_refresh());
          });
        }
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    printer.removeListener(_transportChanged);
    connection.removeListener(_transportChanged);
    super.dispose();
  }
}
