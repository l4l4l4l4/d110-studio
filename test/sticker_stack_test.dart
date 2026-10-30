import 'dart:async';
import 'package:d110_studio/sticker_stack.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'offline next tile stops without sending or resuming automatically',
    () async {
      var online = true;
      final sent = <int>[];
      final job = StickerPrintJob(
        tileCount: 3,
        printTile: (index) async {
          if (!online) throw StateError('printer offline');
          sent.add(index);
        },
      );
      await job.printNext();
      online = false;
      await job.printNext();
      expect(job.phase, StickerPrintPhase.failed);
      online = true;
      await job.printNext();
      expect(sent, [0]);
      job.dispose();
    },
  );

  test(
    'each acknowledgement requires explicit placement before next row-major tile',
    () async {
      final sent = <int>[];
      final job = StickerPrintJob(
        tileCount: 4,
        printTile: (index) async {
          sent.add(index);
        },
      );
      await job.printNext();
      expect(sent, [0]);
      expect(job.phase, StickerPrintPhase.placement);
      expect(job.index, 0);
      for (var i = 1; i < 4; i++) {
        await job.printNext();
        expect(sent, List.generate(i + 1, (n) => n));
        expect(job.index, i);
        expect(job.phase, StickerPrintPhase.placement);
      }
      await job.printNext();
      expect(job.phase, StickerPrintPhase.completed);
      expect(sent, [0, 1, 2, 3]);
      job.dispose();
    },
  );

  test(
    'ambiguous failure is terminal and cannot duplicate a physical print',
    () async {
      final sent = <int>[];
      final job = StickerPrintJob(
        tileCount: 3,
        printTile: (index) async {
          sent.add(index);
          if (index == 1) throw StateError('ack lost');
        },
      );
      await job.printNext();
      await job.printNext();
      expect(job.phase, StickerPrintPhase.failed);
      expect(job.error.toString(), contains('ack lost'));
      await job.printNext();
      expect(sent, [0, 1]);
      job.dispose();
    },
  );

  test(
    'cancel and duplicate next during an in-flight print never send more tiles',
    () async {
      final ack = Completer<void>();
      final sent = <int>[];
      final job = StickerPrintJob(
        tileCount: 4,
        printTile: (index) {
          sent.add(index);
          return ack.future;
        },
      );
      final pending = job.printNext();
      await job.printNext();
      job.cancel();
      ack.complete();
      await pending;
      await job.printNext();
      expect(sent, [0]);
      expect(job.phase, StickerPrintPhase.cancelled);
      job.dispose();
    },
  );
  test(
    'copies preserve tile order and restart placement for each design',
    () async {
      final sent = <int>[];
      final job = StickerPrintJob(
        tileCount: 2,
        copies: 3,
        printTile: (index) async => sent.add(index),
      );
      for (var i = 0; i < 6; i++) {
        await job.printNext();
        expect(job.phase, StickerPrintPhase.placement);
        expect(job.copyIndex, i ~/ 2);
        expect(job.tileIndex, i % 2);
      }
      await job.printNext();
      expect(job.phase, StickerPrintPhase.completed);
      expect(sent, [0, 1, 0, 1, 0, 1]);
      job.dispose();
    },
  );

  test(
    'automatic copies serialize acknowledgements and stop on cancellation',
    () async {
      final acks = [Completer<void>(), Completer<void>()];
      final sent = <int>[];
      final job = StickerPrintJob(
        tileCount: 1,
        copies: 3,
        waitForPlacement: false,
        printTile: (index) {
          sent.add(index);
          return acks[sent.length - 1].future;
        },
      );
      final pending = job.printNext();
      await job.printNext();
      expect(sent, [0]);
      acks[0].complete();
      await Future<void>.delayed(Duration.zero);
      expect(sent, [0, 0]);
      job.cancel();
      acks[1].complete();
      await pending;
      expect(sent, [0, 0]);
      expect(job.phase, StickerPrintPhase.cancelled);
      expect(job.transactionActive, false);
      job.dispose();
    },
  );

  test(
    'automatic copy failure never retries or sends subsequent copies',
    () async {
      var attempts = 0;
      final job = StickerPrintJob(
        tileCount: 1,
        copies: 4,
        waitForPlacement: false,
        printTile: (_) async {
          attempts++;
          if (attempts == 2) throw StateError('lost acknowledgement');
        },
      );
      await job.printNext();
      await job.printNext();
      expect(attempts, 2);
      expect(job.phase, StickerPrintPhase.failed);
      job.dispose();
    },
  );

  test('automatic copies complete exactly the requested count', () async {
    var attempts = 0;
    final job = StickerPrintJob(
      tileCount: 1,
      copies: 3,
      waitForPlacement: false,
      printTile: (_) async {
        attempts++;
      },
    );
    await job.printNext();
    expect(attempts, 3);
    expect(job.phase, StickerPrintPhase.completed);
    await job.printNext();
    expect(attempts, 3);
    job.dispose();
  });
}
