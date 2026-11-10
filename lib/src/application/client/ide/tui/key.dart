/// A decoded keyboard event delivered to the TUI. See [KeyDecoder] for how raw
/// terminal bytes become [KeyEvent]s.
library;

/// The kind of a [KeyEvent].
enum KeyType {
  /// A printable character; [KeyEvent.rune] holds the code point.
  char,
  enter,
  tab,
  backTab,
  backspace,
  delete,
  escape,
  up,
  down,
  left,
  right,
  home,
  end,
  pageUp,
  pageDown,

  /// A `Ctrl`-modified letter; [KeyEvent.ctrl] holds the lowercase letter.
  ctrlChar,

  /// One step of the mouse wheel (or a trackpad scroll) away from the user,
  /// i.e. toward the top of a document. [KeyEvent.x]/[KeyEvent.y] hold the
  /// pointer's cell, so the app can scroll the pane under it. Only reported
  /// while the driver was entered with `mouseWheel: true`.
  wheelUp,

  /// One step of the mouse wheel toward the user (the document's bottom); see
  /// [wheelUp].
  wheelDown,

  /// An unrecognised sequence (ignored by widgets).
  unknown,
}

/// An immutable decoded key press.
class KeyEvent {
  const KeyEvent(this.type, {this.rune, this.ctrl, this.x, this.y});

  final KeyType type;

  /// The Unicode code point for a [KeyType.char] event, else `null`.
  final int? rune;

  /// The lowercase letter for a [KeyType.ctrlChar] event (e.g. `'s'` for
  /// `Ctrl-S`), else `null`.
  final String? ctrl;

  /// The pointer's 0-based column for a wheel event, else `null`.
  final int? x;

  /// The pointer's 0-based row for a wheel event, else `null`.
  final int? y;

  /// A wheel step ([KeyType.wheelUp] when [up], else [KeyType.wheelDown]) with
  /// the pointer at the 0-based cell ([x], [y]).
  factory KeyEvent.wheel({required bool up, required int x, required int y}) =>
      KeyEvent(up ? KeyType.wheelUp : KeyType.wheelDown, x: x, y: y);

  /// Whether this is a mouse-wheel step ([KeyType.wheelUp]/[KeyType.wheelDown]).
  bool get isWheel => type == KeyType.wheelUp || type == KeyType.wheelDown;

  /// A printable-character event for [rune].
  factory KeyEvent.char(int rune) => KeyEvent(KeyType.char, rune: rune);

  /// A `Ctrl`-letter event for [letter] (lowercase).
  factory KeyEvent.ctrl(String letter) =>
      KeyEvent(KeyType.ctrlChar, ctrl: letter);

  /// The character for a [KeyType.char] event (empty otherwise).
  String get text =>
      type == KeyType.char && rune != null ? String.fromCharCode(rune!) : '';

  /// Whether this is `Ctrl-[letter]`.
  bool isCtrl(String letter) => type == KeyType.ctrlChar && ctrl == letter;

  @override
  bool operator ==(Object other) =>
      other is KeyEvent &&
      other.type == type &&
      other.rune == rune &&
      other.ctrl == ctrl &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(type, rune, ctrl, x, y);

  @override
  String toString() {
    switch (type) {
      case KeyType.char:
        return 'KeyEvent.char(${text.isEmpty ? rune : text})';
      case KeyType.ctrlChar:
        return 'KeyEvent.ctrl($ctrl)';
      case KeyType.wheelUp:
      case KeyType.wheelDown:
        return 'KeyEvent.$type($x, $y)';
      default:
        return 'KeyEvent.$type';
    }
  }
}
