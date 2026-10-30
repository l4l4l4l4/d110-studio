import 'package:flutter/foundation.dart';

enum StickerPrintPhase {
  ready,
  printing,
  placement,
  completed,
  failed,
  cancelled,
}

/// A physical transaction is attempted at most once per tile and copy.
/// Stacks require explicit placement; single-label copies may advance on ACK.
class StickerPrintJob extends ChangeNotifier {
  StickerPrintJob({
    required this.tileCount,
    required this.printTile,
    this.copies = 1,
    this.waitForPlacement = true,
  }) {
    if (tileCount < 1) throw ArgumentError.value(tileCount, 'tileCount');
    if (copies < 1 || copies > 99) {
      throw RangeError.range(copies, 1, 99, 'copies');
    }
  }

  final int tileCount;
  final int copies;
  final bool waitForPlacement;
  int get totalCount => tileCount * copies;
  int get tileIndex => index < 0 ? 0 : index % tileCount;
  int get copyIndex => index < 0 ? 0 : index ~/ tileCount;
  final Future<void> Function(int index) printTile;
  int index = -1;
  StickerPrintPhase phase = StickerPrintPhase.ready;
  Object? error;
  bool _disposed = false;
  bool transactionActive = false;

  Future<void> printNext() async {
    if (_disposed ||
        (phase != StickerPrintPhase.ready &&
            phase != StickerPrintPhase.placement)) {
      return;
    }
    if (index + 1 == totalCount) {
      phase = StickerPrintPhase.completed;
      notifyListeners();
      return;
    }
    phase = StickerPrintPhase.printing;
    transactionActive = true;
    try {
      do {
        index++;
        notifyListeners();
        await printTile(tileIndex);
        if (_disposed || phase == StickerPrintPhase.cancelled) return;
        if (waitForPlacement) {
          phase = StickerPrintPhase.placement;
          return;
        }
      } while (index + 1 < totalCount);
      phase = StickerPrintPhase.completed;
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
