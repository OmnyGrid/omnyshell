import 'dart_highlighter.dart';
import 'highlighter.dart';
import 'json_highlighter.dart';
import 'markdown_highlighter.dart';
import 'plain_highlighter.dart';
import 'yaml_highlighter.dart';

/// Resolves a [Highlighter] for a file from its extension (or, for a few
/// extension-less files, its base name). Unknown types fall back to the
/// [PlainHighlighter], so the editor always has a highlighter.
class HighlighterRegistry {
  HighlighterRegistry();

  static const _dart = DartHighlighter();
  static const _yaml = YamlHighlighter();
  static const _json = JsonHighlighter();
  static const _markdown = MarkdownHighlighter();

  static const _byExtension = <String, Highlighter>{
    'dart': _dart,
    'yaml': _yaml,
    'yml': _yaml,
    'json': _json,
    'jsonc': _json,
    'md': _markdown,
    'markdown': _markdown,
  };

  static const _byBasename = <String, Highlighter>{
    'pubspec.lock': _yaml,
    'dart_test.yaml': _yaml,
    '.gitignore': PlainHighlighter('Text'),
  };

  static const _plain = PlainHighlighter();

  /// The highlighter for the file named [path] (a full or relative path; only
  /// its last segment matters).
  Highlighter forPath(String path) {
    final name = _basename(path).toLowerCase();
    final byName = _byBasename[name];
    if (byName != null) return byName;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return _plain;
    return _byExtension[name.substring(dot + 1)] ?? _plain;
  }

  static String _basename(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }
}
