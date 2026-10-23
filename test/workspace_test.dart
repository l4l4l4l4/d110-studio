import 'dart:convert';
import 'dart:typed_data';

import 'package:d110_studio/label.dart';
import 'package:d110_studio/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'switching tabs keeps independent document and first-frame editor state',
    () {
      final workspace = DesignWorkspace(LabelDocument(name: 'First'));
      final first = workspace.active;
      first.document.elements.add(
        LabelElement(kind: ElementKind.text, text: 'A'),
      );
      first.selected = first.document.elements.single;
      first.inspectorOpen = true;
      first.preview = true;
      first.viewZoom = 2.5;
      first.viewPan = const Offset(12, -9);
      final second = workspace.create(LabelDocument(name: 'Second'));
      expect(second.selected, isNull);
      expect(second.inspectorOpen, isFalse);
      expect(second.preview, isFalse);
      expect(second.viewZoom, 1);
      expect(second.viewPan, Offset.zero);
      second.document.name = 'Second edited';
      workspace.activate(first.id);
      expect(workspace.active, same(first));
      expect(first.document.name, 'First');
      expect(first.selected!.text, 'A');
      expect(first.inspectorOpen, isTrue);
      expect(first.preview, isTrue);
      expect(first.viewZoom, 2.5);
      expect(first.viewPan, const Offset(12, -9));
      workspace.dispose();
    },
  );

  test(
    'cold startup preserves newer draft and activates exact printed snapshot',
    () async {
      final printed = LabelDocument(
        name: 'Printed',
        elements: [LabelElement(kind: ElementKind.text, text: 'Ink')],
      );
      final snapshot = jsonEncode(printed.toJson());
      final workspace = DesignWorkspace(printed);
      workspace.active.document.elements.single.text = 'Newer unprinted edit';
      workspace.active.dirty = true;
      final state = jsonEncode(workspace.toJson());
      workspace.dispose();
      final restored = await DesignWorkspace.restore(
        state,
        printedSnapshot: snapshot,
      );
      expect(restored.tabs, hasLength(2));
      expect(restored.active.document.elements.single.text, 'Ink');
      expect(
        restored.tabs.first.document.elements.single.text,
        'Newer unprinted edit',
      );
      expect(restored.tabs.first.dirty, isTrue);
      final reopened = await DesignWorkspace.restore(
        jsonEncode(restored.toJson()),
        printedSnapshot: snapshot,
      );
      expect(reopened.tabs, hasLength(2));
      expect(reopened.active.document.elements.single.text, 'Ink');
      restored.dispose();
      reopened.dispose();
    },
  );

  test(
    'dirty close requires explicit discard and closing printed tab may reopen it',
    () async {
      final doc = LabelDocument(name: 'Printed');
      final snapshot = jsonEncode(doc.toJson());
      final workspace = DesignWorkspace(doc);
      workspace.active.dirty = true;
      final id = workspace.active.id;
      expect(workspace.close(id), isFalse);
      expect(workspace.tabs.single.id, id);
      expect(workspace.close(id, discardChanges: true), isTrue);
      expect(workspace.tabs.single.id, isNot(id));
      final restored = await DesignWorkspace.restore(
        jsonEncode(workspace.toJson()),
        printedSnapshot: snapshot,
      );
      expect(restored.active.document.name, 'Printed');
      workspace.dispose();
      restored.dispose();
    },
  );

  test(
    'persisted selection inspector pan and preview restore without state bleed',
    () async {
      final workspace = DesignWorkspace(
        LabelDocument(
          elements: [LabelElement(kind: ElementKind.text, text: 'Selected')],
        ),
      );
      workspace.active.inspectorOpen = true;
      workspace.active.viewZoom = 3;
      workspace.active.viewPan = const Offset(-5, 8);
      workspace.active.preview = true;
      workspace.create(LabelDocument(name: 'Other'));
      final restored = await DesignWorkspace.restore(
        jsonEncode(workspace.toJson()),
      );
      expect(restored.active.document.name, 'Other');
      expect(restored.active.inspectorOpen, isFalse);
      restored.activate(restored.tabs.first.id);
      expect(restored.active.selected!.text, 'Selected');
      expect(restored.active.inspectorOpen, isTrue);
      expect(restored.active.preview, isTrue);
      expect(restored.active.viewZoom, 3);
      expect(restored.active.viewPan, const Offset(-5, 8));
      workspace.dispose();
      restored.dispose();
    },
  );

  test(
    'malformed workspace does not masquerade as a new empty draft',
    () async {
      await expectLater(
        DesignWorkspace.restore('{"version":1,"tabs":[]}'),
        throwsFormatException,
      );
    },
  );
  test('undecodable history image leaves valid draft artwork intact', () async {
    final drafts = DesignWorkspace(
      LabelDocument(
        name: 'Valid draft',
        elements: [LabelElement(kind: ElementKind.text, text: 'Keep this ink')],
      ),
    );
    final state = jsonEncode(drafts.toJson());
    drafts.dispose();
    final corrupt = LabelDocument(
      elements: [
        LabelElement(
          kind: ElementKind.image,
          imageBytes: Uint8List.fromList([0]),
        ),
      ],
    );
    final snapshot = jsonEncode(corrupt.toJson());
    corrupt.dispose();
    final restored = await DesignWorkspace.restore(
      state,
      printedSnapshot: snapshot,
    );
    expect(restored.active.document.name, 'Valid draft');
    expect(restored.active.document.elements.single.text, 'Keep this ink');
    expect(restored.tabs, hasLength(1));
    expect(restored.printedRestoreError, isNotNull);
    restored.dispose();
  });
}
