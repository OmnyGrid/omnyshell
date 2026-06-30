import 'dart:convert';

import 'key.dart';

/// Turns raw terminal input bytes (read in raw mode) into [KeyEvent]s.
///
/// The decoder is streaming: feed it each chunk from stdin with [decode] and it
/// returns the events that completed in that chunk, buffering any partial
/// escape sequence or partial UTF-8 character until the rest arrives. This keeps
/// multi-byte input (arrow keys, accented characters pasted a chunk at a time)
/// robust without the caller reasoning about byte boundaries.
class KeyDecoder {
  final List<int> _pending = [];

  /// Decodes [bytes], returning the keys that completed. Incomplete trailing
  /// sequences are retained for the next call.
  List<KeyEvent> decode(List<int> bytes) {
    _pending.addAll(bytes);
    final events = <KeyEvent>[];
    while (_pending.isNotEmpty) {
      final consumed = _decodeOne(events);
      if (consumed == 0) break; // need more bytes
      _pending.removeRange(0, consumed);
    }
    return events;
  }

  /// Flushes any buffered bytes as a best-effort final decode (e.g. a lone
  /// trailing `ESC`). Call when input ends.
  List<KeyEvent> flush() {
    final events = <KeyEvent>[];
    if (_pending.length == 1 && _pending.first == 0x1b) {
      events.add(const KeyEvent(KeyType.escape));
      _pending.clear();
    }
    return events;
  }

  /// Decodes a single key from the front of [_pending], appending it to
  /// [events]. Returns the number of bytes consumed, or 0 when more bytes are
  /// needed to disambiguate.
  int _decodeOne(List<KeyEvent> events) {
    final b = _pending.first;

    // ESC: a control sequence (CSI / SS3) or a lone Escape.
    if (b == 0x1b) return _decodeEscape(events);

    // C0 controls.
    switch (b) {
      case 0x0d: // CR
      case 0x0a: // LF
        events.add(const KeyEvent(KeyType.enter));
        return 1;
      case 0x09: // Tab (Ctrl-I)
        events.add(const KeyEvent(KeyType.tab));
        return 1;
      case 0x7f: // DEL
      case 0x08: // BS (Ctrl-H)
        events.add(const KeyEvent(KeyType.backspace));
        return 1;
    }
    if (b >= 0x01 && b <= 0x1a) {
      // Ctrl-A .. Ctrl-Z, minus the ones special-cased above.
      events.add(KeyEvent.ctrl(String.fromCharCode(b + 0x60)));
      return 1;
    }

    // Printable ASCII.
    if (b >= 0x20 && b < 0x80) {
      events.add(KeyEvent.char(b));
      return 1;
    }

    // UTF-8 multi-byte lead. Determine the sequence length and wait for it.
    final len = _utf8Len(b);
    if (len == 0) {
      // Invalid lead byte — drop it.
      events.add(const KeyEvent(KeyType.unknown));
      return 1;
    }
    if (_pending.length < len) return 0; // need more bytes
    try {
      final decoded = utf8.decode(_pending.sublist(0, len));
      if (decoded.isNotEmpty) events.add(KeyEvent.char(decoded.runes.first));
    } on FormatException {
      events.add(const KeyEvent(KeyType.unknown));
    }
    return len;
  }

  /// Decodes an `ESC`-led sequence. Returns bytes consumed, or 0 if the
  /// sequence is incomplete (more bytes needed).
  int _decodeEscape(List<KeyEvent> events) {
    if (_pending.length == 1) {
      // Could be a lone Escape or the start of a sequence. Wait briefly: the
      // streaming caller delivers the rest in the same or next chunk. Treat a
      // solitary ESC that never grows as Escape via [flush].
      return 0;
    }
    final second = _pending[1];

    // SS3 sequences: ESC O <final> (e.g. application-cursor-mode arrows).
    if (second == 0x4f) {
      if (_pending.length < 3) return 0;
      final f = _pending[2];
      final key = _finalToKey(f);
      events.add(key ?? const KeyEvent(KeyType.unknown));
      return 3;
    }

    // CSI sequences: ESC [ … <final>.
    if (second == 0x5b) {
      // Find the final byte (0x40..0x7e), collecting parameter bytes between.
      var i = 2;
      while (i < _pending.length) {
        final c = _pending[i];
        if (c >= 0x40 && c <= 0x7e) {
          _emitCsi(events, _pending.sublist(2, i), c);
          return i + 1;
        }
        i++;
      }
      return 0; // incomplete CSI
    }

    // ESC followed by anything else: treat the ESC as Escape and let the rest
    // decode on its own.
    events.add(const KeyEvent(KeyType.escape));
    return 1;
  }

  /// Emits the key for a CSI sequence with [params] (the bytes between `[` and
  /// the final) and [finalByte].
  void _emitCsi(List<KeyEvent> events, List<int> params, int finalByte) {
    // Letter finals: cursor + Home/End.
    final byFinal = _finalToKey(finalByte);
    if (byFinal != null) {
      events.add(byFinal);
      return;
    }
    if (finalByte == 0x5a) {
      // 'Z'
      events.add(const KeyEvent(KeyType.backTab));
      return;
    }
    // Tilde finals: ESC [ n ~  (n selects the key).
    if (finalByte == 0x7e) {
      final n = int.tryParse(String.fromCharCodes(params).split(';').first);
      switch (n) {
        case 1:
        case 7:
          events.add(const KeyEvent(KeyType.home));
          return;
        case 4:
        case 8:
          events.add(const KeyEvent(KeyType.end));
          return;
        case 3:
          events.add(const KeyEvent(KeyType.delete));
          return;
        case 5:
          events.add(const KeyEvent(KeyType.pageUp));
          return;
        case 6:
          events.add(const KeyEvent(KeyType.pageDown));
          return;
      }
    }
    events.add(const KeyEvent(KeyType.unknown));
  }

  /// Maps a CSI/SS3 letter final byte to its key, or `null` if unrecognised.
  KeyEvent? _finalToKey(int finalByte) {
    switch (finalByte) {
      case 0x41:
        return const KeyEvent(KeyType.up); // A
      case 0x42:
        return const KeyEvent(KeyType.down); // B
      case 0x43:
        return const KeyEvent(KeyType.right); // C
      case 0x44:
        return const KeyEvent(KeyType.left); // D
      case 0x48:
        return const KeyEvent(KeyType.home); // H
      case 0x46:
        return const KeyEvent(KeyType.end); // F
    }
    return null;
  }

  /// The UTF-8 sequence length implied by lead byte [b], or 0 if [b] is not a
  /// valid lead byte.
  static int _utf8Len(int b) {
    if (b & 0xe0 == 0xc0) return 2;
    if (b & 0xf0 == 0xe0) return 3;
    if (b & 0xf8 == 0xf0) return 4;
    return 0;
  }
}
