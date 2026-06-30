/// Terminal text styling for the TUI: an 8/16-colour + 256-colour palette and
/// the bold/italic/underline/reverse/dim attributes, plus the SGR escape that
/// realises a [Style] on an ANSI terminal.
///
/// Colours are kept deliberately small and terminal-agnostic. A [Color] is
/// either a named ANSI colour (rendered with the 30–37 / 90–97 ranges so it
/// honours the user's terminal theme) or an explicit 256-colour index (the
/// `38;5;n` / `48;5;n` form), which every modern terminal understands.
library;

/// An immutable terminal colour: either a named ANSI colour or a 256-palette
/// index. Use [Color.ansi] for theme-honouring named colours and
/// [Color.indexed] for a fixed palette entry.
class Color {
  const Color._(this._ansi, this._index);

  /// A named ANSI colour (0–7), rendered bright when used with [Style.bold] or
  /// via the 90–97 range when [bright] is set.
  const Color.ansi(int code, {bool bright = false})
    : this._(bright ? code + 8 : code, null);

  /// A fixed 256-colour palette index (0–255).
  const Color.indexed(int index) : this._(null, index);

  final int? _ansi; // 0..15 (8 normal + 8 bright), or null when indexed.
  final int? _index; // 0..255, or null when named.

  /// Whether this is a 256-palette colour (vs. a named ANSI colour).
  bool get isIndexed => _index != null;

  /// The SGR parameter list for this colour as a foreground (e.g. `['38','5','81']`
  /// or `['94']`).
  List<String> get _fgParams {
    final idx = _index;
    if (idx != null) return ['38', '5', '$idx'];
    final a = _ansi!;
    return [a < 8 ? '${30 + a}' : '${90 + (a - 8)}'];
  }

  /// The SGR parameter list for this colour as a background.
  List<String> get _bgParams {
    final idx = _index;
    if (idx != null) return ['48', '5', '$idx'];
    final a = _ansi!;
    return [a < 8 ? '${40 + a}' : '${100 + (a - 8)}'];
  }

  // Named ANSI colours.
  static const black = Color.ansi(0);
  static const red = Color.ansi(1);
  static const green = Color.ansi(2);
  static const yellow = Color.ansi(3);
  static const blue = Color.ansi(4);
  static const magenta = Color.ansi(5);
  static const cyan = Color.ansi(6);
  static const white = Color.ansi(7);
  static const brightBlack = Color.ansi(0, bright: true);
  static const brightRed = Color.ansi(1, bright: true);
  static const brightGreen = Color.ansi(2, bright: true);
  static const brightYellow = Color.ansi(3, bright: true);
  static const brightBlue = Color.ansi(4, bright: true);
  static const brightMagenta = Color.ansi(5, bright: true);
  static const brightCyan = Color.ansi(6, bright: true);
  static const brightWhite = Color.ansi(7, bright: true);

  @override
  bool operator ==(Object other) =>
      other is Color && other._ansi == _ansi && other._index == _index;

  @override
  int get hashCode => Object.hash(_ansi, _index);
}

/// An immutable bundle of a foreground/background colour and text attributes.
///
/// A `null` [fg]/[bg] means "terminal default". [Style] values are interned-free
/// and cheap to compare, so the renderer can diff cell styles directly.
class Style {
  const Style({
    this.fg,
    this.bg,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.reverse = false,
    this.dim = false,
  });

  /// The default (unstyled) style: terminal default colours, no attributes.
  static const none = Style();

  final Color? fg;
  final Color? bg;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool reverse;
  final bool dim;

  /// Returns a copy of this style with the given fields overridden.
  Style copyWith({
    Color? fg,
    Color? bg,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? reverse,
    bool? dim,
  }) => Style(
    fg: fg ?? this.fg,
    bg: bg ?? this.bg,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    reverse: reverse ?? this.reverse,
    dim: dim ?? this.dim,
  );

  /// The full SGR escape that realises this style on the terminal, starting
  /// from a reset (`\x1b[0;…m`) so it is self-contained and never inherits a
  /// previous cell's attributes.
  String get sgr {
    final params = <String>['0'];
    if (bold) params.add('1');
    if (dim) params.add('2');
    if (italic) params.add('3');
    if (underline) params.add('4');
    if (reverse) params.add('7');
    if (fg != null) params.addAll(fg!._fgParams);
    if (bg != null) params.addAll(bg!._bgParams);
    return '\x1b[${params.join(';')}m';
  }

  @override
  bool operator ==(Object other) =>
      other is Style &&
      other.fg == fg &&
      other.bg == bg &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.reverse == reverse &&
      other.dim == dim;

  @override
  int get hashCode =>
      Object.hash(fg, bg, bold, italic, underline, reverse, dim);
}
