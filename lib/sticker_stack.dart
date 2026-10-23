import 'package:flutter/foundation.dart';

enum StickerPrintPhase {
  ready,
  printing,
  placement,
  completed,
  failed,
  cancelled,
}

/// A physical transaction is attempted at most once per tile in this job.
/// Placement is explicit: an acknowledgement never starts the next print.
class StickerPrintJob extends ChangeNotifier {
  StickerPrintJob({required this.tileCount, required this.printTile}) {
    if (tileCount < 1) throw ArgumentError.value(tileCount, 'tileCount');
  }

  final int tileCount;
  final Future<void> Function(int index) printTile;
  int index = -1;
  StickerPrintPhase phase = StickerPrintPhase.ready;
  Object? error;
  bool _disposed = false;
  bool transactionActive = false;

  Future<void> printNext() async {
    if (phase != StickerPrintPhase.ready &&
        phase != StickerPrintPhase.placement) {
      return;
    }
    if (index + 1 == tileCount) {
      phase = StickerPrintPhase.completed;
      notifyListeners();
      return;
    }
    index++;
    phase = StickerPrintPhase.printing;
    transactionActive = true;
    notifyListeners();
    try {
      await printTile(index);
      if (!_disposed && phase != StickerPrintPhase.cancelled) {
        phase = StickerPrintPhase.placement;
      }
    } catch (failure) {
      if (!_disposed && phase != StickerPrintPhase.cancelled) {
        error = failure;
        phase = StickerPrintPhase.failed;
      }
    } finally {
      transactionActive = false;
      if (!_disposed) notifyListeners();
    }
  }

  void cancel() {
    if (phase == StickerPrintPhase.completed ||
        phase == StickerPrintPhase.cancelled) {
      return;
    }
    phase = StickerPrintPhase.cancelled;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
