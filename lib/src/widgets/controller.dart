import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:tuple/tuple.dart';

import '../models/documents/attribute.dart';
import '../models/documents/document.dart';
import '../models/documents/nodes/embed.dart';
import '../models/documents/style.dart';
import '../models/quill_delta.dart';
import '../utils/diff_delta.dart';

typedef ReplaceTextCallback = bool Function(int index, int len, Object? data);
typedef DeleteCallback = void Function(int cursorPosition, bool forward);

class QuillController extends ChangeNotifier {
  QuillController({
    required this.document,
    required TextSelection selection,
    bool keepStyleOnNewLine = false,
    this.onReplaceText,
    this.onDelete,
    this.onSelectionCompleted,
  })  : _selection = selection,
        _keepStyleOnNewLine = keepStyleOnNewLine;

  factory QuillController.basic() {
    return QuillController(
      document: Document(),
      selection: const TextSelection.collapsed(offset: 0),
    );
  }

  /// Document managed by this controller.
  final Document document;

  /// Tells whether to keep or reset the [toggledStyle]
  /// when user adds a new line.
  final bool _keepStyleOnNewLine;

  /// Currently selected text within the [document].
  TextSelection get selection => _selection;
  TextSelection _selection;

  /// Custom [replaceText] handler
  /// Return false to ignore the event
  ReplaceTextCallback? onReplaceText;

  /// Custom delete handler
  DeleteCallback? onDelete;

  void Function()? onSelectionCompleted;

  /// Store any styles attribute that got toggled by the tap of a button
  /// and that has not been applied yet.
  /// It gets reset after each format action within the [document].
  Style toggledStyle = Style();

  bool ignoreFocusOnTextChange = false;

  /// True when this [QuillController] instance has been disposed.
  ///
  /// A safety mechanism to ensure that listeners don't crash when adding,
  /// removing or listeners to this instance.
  bool _isDisposed = false;

  // item1: Document state before [change].
  //
  // item2: Change delta applied to the document.
  //
  // item3: The source of this change.
  Stream<Tuple3<Delta, Delta, ChangeSource>> get changes => document.changes;

  TextEditingValue get plainTextEditingValue => TextEditingValue(
        text: document.toPlainText(),
        selection: selection,
      );

  /// Only attributes applied to all characters within this range are
  /// included in the result.
  Style getSelectionStyle() {
    return document
        .collectStyle(selection.start, selection.end - selection.start)
        .mergeAll(toggledStyle);
  }

  /// Returns all styles for any character within the specified text range.
  List<Style> getAllSelectionStyles() {
    final styles = document.collectAllStyles(
        selection.start, selection.end - selection.start)
      ..add(toggledStyle);
    return styles;
  }

  void undo() {
    final tup = document.undo();
    if (tup.item1) {
      _handleHistoryChange(tup.item2);
    }
  }

  void _handleHistoryChange(int? len) {
    if (len! != 0) {
      // if (this.selection.extentOffset >= document.length) {
      // // cursor exceeds the length of document, position it in the end
      // updateSelection(
      // TextSelection.collapsed(offset: document.length), ChangeSource.LOCAL);
      updateSelection(
          TextSelection.collapsed(offset: selection.baseOffset + len),
          ChangeSource.LOCAL);
    } else {
      // no need to move cursor
      notifyListeners();
    }
  }

  void redo() {
    final tup = document.redo();
    if (tup.item1) {
      _handleHistoryChange(tup.item2);
    }
  }

  bool get hasUndo => document.hasUndo;

  bool get hasRedo => document.hasRedo;

  /// clear editor
  void clear() {
    replaceText(0, plainTextEditingValue.text.length - 1, '',
        const TextSelection.collapsed(offset: 0));
  }

  void replaceText(
      int index, int len, Object? data, TextSelection? textSelection,
      {bool ignoreFocus = false}) {
    assert(data is String || data is Embeddable);

    if (onReplaceText != null && !onReplaceText!(index, len, data)) {
      return;
    }

    Delta? delta;
    if (len > 0 || data is! String || data.isNotEmpty) {
      delta = document.replace(index, len, data);
      var shouldRetainDelta = toggledStyle.isNotEmpty &&
          delta.isNotEmpty &&
          delta.length <= 2 &&
          delta.last.isInsert;
      if (shouldRetainDelta &&
          toggledStyle.isNotEmpty &&
          delta.length == 2 &&
          delta.last.data == '\n') {
        // if all attributes are inline, shouldRetainDelta should be false
        final anyAttributeNotInline =
            toggledStyle.values.any((attr) => !attr.isInline);
        if (!anyAttributeNotInline) {
          shouldRetainDelta = false;
        }
      }
      if (shouldRetainDelta) {
        final retainDelta = Delta()
          ..retain(index)
          ..retain(data is String ? data.length : 1, toggledStyle.toJson());
        document.compose(retainDelta, ChangeSource.LOCAL);
      }
    }

    if (_keepStyleOnNewLine) {
      final style = getSelectionStyle();
      final notInlineStyle = style.attributes.values.where((s) => !s.isInline);
      toggledStyle = style.removeAll(notInlineStyle.toSet());
    } else {
      toggledStyle = Style();
    }

    if (textSelection != null) {
      if (delta == null || delta.isEmpty) {
        _updateSelection(textSelection, ChangeSource.LOCAL);
      } else {
        final user = Delta()
          ..retain(index)
          ..insert(data)
          ..delete(len);
        final positionDelta = getPositionDelta(user, delta);
        _updateSelection(
          textSelection.copyWith(
            baseOffset: textSelection.baseOffset + positionDelta,
            extentOffset: textSelection.extentOffset + positionDelta,
          ),
          ChangeSource.LOCAL,
        );
      }
    }

    if (ignoreFocus) {
      ignoreFocusOnTextChange = true;
    }
    notifyListeners();
    ignoreFocusOnTextChange = false;
  }

  /// Called in two cases:
  /// forward == false && textBefore.isEmpty
  /// forward == true && textAfter.isEmpty
  /// Android only
  /// see https://github.com/singerdmx/flutter-quill/discussions/514
  void handleDelete(int cursorPosition, bool forward) =>
      onDelete?.call(cursorPosition, forward);

  void formatText(int index, int len, Attribute? attribute) {
    if (len == 0 &&
        attribute!.isInline &&
        attribute.key != Attribute.link.key) {
      toggledStyle = toggledStyle.put(attribute);
    }

    final change = document.format(index, len, attribute);
    final adjustedSelection = selection.copyWith(
        baseOffset: change.transformPosition(selection.baseOffset),
        extentOffset: change.transformPosition(selection.extentOffset));
    if (selection != adjustedSelection) {
      _updateSelection(adjustedSelection, ChangeSource.LOCAL);
    }
    notifyListeners();
  }

  void formatSelection(Attribute? attribute) {
    formatText(selection.start, selection.end - selection.start, attribute);
  }

  void moveCursorToStart() {
    updateSelection(
        const TextSelection.collapsed(offset: 0), ChangeSource.LOCAL);
  }

  void moveCursorToEnd() {
    updateSelection(
        TextSelection.collapsed(offset: plainTextEditingValue.text.length),
        ChangeSource.LOCAL);
  }

  void updateSelection(TextSelection textSelection, ChangeSource source) {
    _updateSelection(textSelection, source);
    notifyListeners();
  }

  void compose(Delta delta, TextSelection textSelection, ChangeSource source) {
    if (delta.isNotEmpty) {
      document.compose(delta, source);
    }

    textSelection = selection.copyWith(
        baseOffset: delta.transformPosition(selection.baseOffset, force: false),
        extentOffset:
            delta.transformPosition(selection.extentOffset, force: false));
    if (selection != textSelection) {
      _updateSelection(textSelection, source);
    }

    notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    // By using `_isDisposed`, make sure that `addListener` won't be called on a
    // disposed `ChangeListener`
    if (!_isDisposed) {
      super.addListener(listener);
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    // By using `_isDisposed`, make sure that `removeListener` won't be called
    // on a disposed `ChangeListener`
    if (!_isDisposed) {
      super.removeListener(listener);
    }
  }

  @override
  void dispose() {
    if (!_isDisposed) {
      document.close();
    }

    _isDisposed = true;
    super.dispose();
  }

  void _updateSelection(TextSelection textSelection, ChangeSource source) {
    _selection = textSelection;
    final end = document.length - 1;
    _selection = selection.copyWith(
        baseOffset: math.min(selection.baseOffset, end),
        extentOffset: math.min(selection.extentOffset, end));
  }
}
