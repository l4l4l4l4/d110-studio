import 'dart:convert';

import 'app_state_store.dart';
import 'label.dart';

Future<LabelDocument> prepareDocument(Map<String, dynamic> json) async {
  final document = LabelDocument.fromJson(json);
  try {
    for (final element in document.elements) {
      await element.prepare();
    }
    return document;
  } catch (_) {
    document.dispose();
    rethrow;
  }
}

class LastPrintedHistory {
  LastPrintedHistory(this.store);
  final AppStateStore store;

  Future<String?> readSnapshot() async {
    final text = await store.read(AppStateSlot.lastPrinted);
    if (text == null) return null;
    final json = jsonDecode(text);
    if (json is! Map || json['version'] != 1 || json['document'] is! Map) {
      throw const FormatException('Некорректная запись последнего отпечатка');
    }
    return jsonEncode(json['document']);
  }

  Future<LabelDocument?> restore() async {
    final snapshot = await readSnapshot();
    return snapshot == null
        ? null
        : prepareDocument(
            Map<String, dynamic>.from(jsonDecode(snapshot) as Map),
          );
  }

  Future<void> saveSnapshot(String snapshot) => store.write(
    AppStateSlot.lastPrinted,
    '{"version":1,"document":$snapshot}',
  );
}

/// Capture synchronously, before any print preparation or transport await.
/// Only the user-design ACK path calls confirmed; diagnostics never do.
class LastPrintedJob {
  LastPrintedJob.capture(LabelDocument document, this.history)
    : snapshot = jsonEncode(document.toJson());

  final LastPrintedHistory history;
  final String snapshot;
  bool _confirmed = false;

  Future<LabelDocument> prepare() =>
      prepareDocument(Map<String, dynamic>.from(jsonDecode(snapshot) as Map));

  Future<String?> confirmed() async {
    if (_confirmed) return null;
    _confirmed = true;
    try {
      await history.saveSnapshot(snapshot);
      return null;
    } catch (error) {
      return 'Принтер подтвердил печать, но макет не сохранён для следующего '
          'запуска: $error. Не повторяйте печать ради сохранения.';
    }
  }
}
