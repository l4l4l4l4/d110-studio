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
}
