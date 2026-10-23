import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'label.dart';
import 'last_printed.dart';

/// A tab owns all document/editor state, including in-flight preview resources.
/// The printer, connection, templates and physical job lock belong to the page.
class DesignTab {
  DesignTab(this.document, {String? id})
    : id = id ?? 'design-${DateTime.now().microsecondsSinceEpoch}-${_nextId++}',
      selected = document.elements.firstOrNull;

  static int _nextId = 0;
  final String id;
  final LabelDocument document;
  LabelElement? selected;
  bool dirty = false;
  bool inspectorOpen = false;
  bool colorImages = false;
  bool preview = false;
  double viewZoom = 1;
  Offset viewPan = Offset.zero;
  ui.Image? previewImage;
  Timer? previewTimer;
  int previewVersion = 0;
  int revision = 0;
  bool disposed = false;

  Map<String, dynamic> toJson() => {
    'id': id,
    'document': document.toJson(),
    'dirty': dirty,
    'selected': selected == null ? null : document.elements.indexOf(selected!),
    'inspectorOpen': inspectorOpen,
    'colorImages': colorImages,
    'preview': preview,
    'zoom': viewZoom,
    'pan': [viewPan.dx, viewPan.dy],
  };

  static Future<DesignTab> restore(Map<String, dynamic> json) async {
    final id = json['id'];
    final zoom = json['zoom'];
    final pan = json['pan'];
    final selection = json['selected'];
    if (id is! String ||
        id.isEmpty ||
        json['document'] is! Map ||
        json['dirty'] is! bool ||
        json['inspectorOpen'] is! bool ||
        json['colorImages'] is! bool ||
        json['preview'] is! bool ||
        zoom is! num ||
        !zoom.isFinite ||
        zoom < .4 ||
        zoom > 6 ||
        pan is! List ||
        pan.length != 2 ||
        pan.any((value) => value is! num || !value.isFinite) ||
        (selection != null && selection is! int)) {
      throw const FormatException('Некорректное состояние вкладки');
    }
    final document = await prepareDocument(
      Map<String, dynamic>.from(json['document'] as Map),
    );
    if (selection != null &&
        (selection < 0 || selection >= document.elements.length)) {
      document.dispose();
      throw const FormatException('Некорректное выделение во вкладке');
    }
    return DesignTab(document, id: id)
      ..selected = selection == null
          ? null
          : document.elements[selection as int]
      ..dirty = json['dirty'] as bool
      ..inspectorOpen = json['inspectorOpen'] as bool
      ..colorImages = json['colorImages'] as bool
      ..preview = json['preview'] as bool
      ..viewZoom = zoom.toDouble()
      ..viewPan = Offset(
        (pan[0] as num).toDouble(),
        (pan[1] as num).toDouble(),
      );
  }

  void invalidatePreview() {
    previewVersion++;
    previewTimer?.cancel();
    previewImage?.dispose();
    previewImage = null;
  }

  void dispose() {
    disposed = true;
    invalidatePreview();
    document.dispose();
  }
}

/// Startup precedence: restore every draft and its editor state first, then
/// activate the exact last ACKed design. An edited draft is never overwritten.
/// Exact existing snapshots are reused, so relaunches do not duplicate tabs.
class DesignWorkspace {
  DesignWorkspace(LabelDocument initial)
    : tabs = [DesignTab(initial)],
      printedRestoreError = null {
    activeId = tabs.first.id;
  }
  DesignWorkspace._(this.tabs, this.activeId, this.printedRestoreError);

  final List<DesignTab> tabs;
  final String? printedRestoreError;
  late String activeId;
  DesignTab get active => tabs.firstWhere((tab) => tab.id == activeId);

  void activate(String id) {
    if (!tabs.any((tab) => tab.id == id)) {
      throw StateError('Unknown design tab');
    }
    activeId = id;
  }

  DesignTab create(LabelDocument document) {
    final tab = DesignTab(document);
    tabs.add(tab);
    activeId = tab.id;
    return tab;
  }

  bool close(String id, {bool discardChanges = false}) {
    final index = tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return false;
    final tab = tabs[index];
    if (tab.dirty && !discardChanges) return false;
    tabs.removeAt(index);
    if (tabs.isEmpty) {
      create(LabelDocument(name: 'Новый макет'));
    } else if (activeId == id) {
      activeId = tabs[index < tabs.length ? index : tabs.length - 1].id;
    }
    tab.dispose();
    return true;
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'activeId': activeId,
    'tabs': tabs.map((tab) => tab.toJson()).toList(),
  };

  static Future<DesignWorkspace> restore(
    String? text, {
    String? printedSnapshot,
  }) async {
    final tabs = <DesignTab>[];
    try {
      String? active;
      String? printedError;
      if (text != null) {
        final json = jsonDecode(text);
        if (json is! Map ||
            json['version'] != 1 ||
            json['tabs'] is! List ||
            (json['tabs'] as List).isEmpty ||
            json['activeId'] is! String) {
          throw const FormatException('Некорректное рабочее пространство');
        }
        for (final entry in json['tabs'] as List) {
          if (entry is! Map) {
            throw const FormatException('Некорректная вкладка');
          }
          final tab = await DesignTab.restore(Map<String, dynamic>.from(entry));
          if (tabs.any((existing) => existing.id == tab.id)) {
            tab.dispose();
            throw const FormatException('Повторяющийся идентификатор вкладки');
          }
          tabs.add(tab);
        }
        active = json['activeId'] as String;
        if (!tabs.any((tab) => tab.id == active)) {
          throw const FormatException('Не найдена активная вкладка');
        }
      }
      if (printedSnapshot != null) {
        try {
          // Normalize through the current document schema before comparison.
          final printed = await prepareDocument(
            Map<String, dynamic>.from(jsonDecode(printedSnapshot) as Map),
          );
          var retained = false;
          try {
            final normalized = jsonEncode(printed.toJson());
            final match = tabs
                .where((tab) => jsonEncode(tab.document.toJson()) == normalized)
                .firstOrNull;
            if (match == null) {
              final tab = DesignTab(printed);
              tabs.add(tab);
              retained = true;
              active = tab.id;
            } else {
              active = match.id;
            }
          } finally {
            if (!retained) printed.dispose();
          }
        } catch (error) {
          printedError = 'Последний отпечаток не загружен: $error';
        }
      }
      if (tabs.isEmpty) tabs.add(DesignTab(LabelDocument(name: 'Новый макет')));
      return DesignWorkspace._(tabs, active ?? tabs.first.id, printedError);
    } catch (_) {
      for (final tab in tabs) {
        tab.dispose();
      }
      rethrow;
    }
  }

  void dispose() {
    for (final tab in tabs) {
      tab.dispose();
    }
  }
}
