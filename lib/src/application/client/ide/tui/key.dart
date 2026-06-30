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

  /// An unrecognised sequence (ignored by widgets).
  unknown,
}

/// An immutable decoded key press.
class KeyEvent {
  const KeyEvent(this.type, {this.rune, this.ctrl});

  final KeyType type;

  /// The Unicode code point for a [KeyType.char] event, else `null`.
  final int? rune;

  /// The lowercase letter for a [KeyType.ctrlChar] event (e.g. `'s'` for
  /// `Ctrl-S`), else `null`.
  final String? ctrl;

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
      other.ctrl == ctrl;

  @override
  int get hashCode => Object.hash(type, rune, ctrl);

  @override
  String toString() {
    switch (type) {
      case KeyType.char:
        return 'KeyEvent.char(${text.isEmpty ? rune : text})';
      case KeyType.ctrlChar:
        return 'KeyEvent.ctrl($ctrl)';
      default:
        return 'KeyEvent.$type';
    }
  }
}
