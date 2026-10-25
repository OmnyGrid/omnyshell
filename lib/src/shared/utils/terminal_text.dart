/// [text] with every control character (C0 including TAB, DEL, C1) removed,
/// for single-line output of remote-supplied strings (a node's or the Hub's
/// hostname, OS version, labels) to a terminal, so they cannot smuggle in an
/// escape sequence.
String stripControlChars(String text) =>
    text.replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F]'), '');
