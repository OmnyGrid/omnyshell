import '../tui/key.dart';
import 'agent_backend.dart';

/// State and behaviour of the IDE's AI agent panel: a conversation scrollback
/// ([lines]), the current [input] prompt, the working [contextLabel], and the
/// multi-turn history sent to the [AgentBackend]. Pure logic — rendering lives
/// in `widgets/agent_view.dart`.
class AgentPanel {
  AgentPanel({
    required AgentBackend backend,
    required void Function() onChange,
    int maxLines = 2000,
  }) : _backend = backend,
       _onChange = onChange,
       _maxLines = maxLines;

  final AgentBackend _backend;
  final void Function() _onChange;
  final int _maxLines;

  AgentContext _context = AgentContext.none();
  final List<String> _lines = [];
  final List<AgentTurn> _history = [];
  String _input = '';
  int _scroll = 0;
  bool _busy = false;

  String get contextLabel => _context.label;
  List<String> get lines => List.unmodifiable(_lines);
  String get input => _input;
  bool get isBusy => _busy;
  int get scroll => _scroll;

  /// Updates the working context (called when the panel is opened/focused so it
  /// tracks the active file or selected directory).
  void setContext(AgentContext context) => _context = context;

  // ---- Key handling --------------------------------------------------------

  void handleKey(KeyEvent key) {
    switch (key.type) {
      case KeyType.enter:
        _submit();
      case KeyType.backspace:
        if (_input.isNotEmpty) {
          _input = _input.substring(0, _input.length - 1);
        }
      case KeyType.char:
        _input += key.text;
        _scroll = 0;
      case KeyType.pageUp:
        _scroll += 5;
      case KeyType.pageDown:
        _scroll = (_scroll - 5).clamp(0, 1 << 30);
      case KeyType.home:
        _scroll = 1 << 30; // clamped to the top on render
      case KeyType.end:
        _scroll = 0;
      default:
        break;
    }
  }

  void _submit() {
    final prompt = _input.trim();
    _input = '';
    _scroll = 0;
    if (prompt.isEmpty) return;
    _append('› $prompt');
    if (!_backend.available) {
      _append(_backend.unavailableReason);
      return;
    }
    if (_busy) {
      _append('Please wait for the current response…');
      return;
    }
    _busy = true;
    _backend
        .send(prompt: prompt, context: _context, history: List.of(_history))
        .then((reply) {
          _busy = false;
          _append(reply);
          _append('');
          _history.add(AgentTurn(prompt, reply));
          _onChange();
        })
        .catchError((Object e) {
          _busy = false;
          _append('[error: $e]');
          _onChange();
        });
  }

  void _append(String text) {
    for (final line in text.split('\n')) {
      _lines.add(line);
    }
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
  }
}
