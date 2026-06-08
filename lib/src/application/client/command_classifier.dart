/// Heuristics that classify a typed command line for the `connect` client.
///
/// The interactive client has no PTY-backed prompt signal, so it injects a
/// `CwdMarker` command after each command and watches the output stream to learn
/// the remote cwd. Two decisions are derived purely from the typed line:
///
/// - [launchesForegroundProgram] — does the line start an interactive program
///   (editor, pager, monitor, REPL) that takes over the terminal? The client
///   uses this to switch the [LineEditor] into raw passthrough so keystrokes —
///   including Enter — reach the program instead of being committed as lines (a
///   committed line would inject the marker into the program's stdin). This
///   matters most on backends where the alternate-screen sequence never reaches
///   the client (e.g. the macOS `script(1)` PTY, whose stdout is not a tty).
/// - [mayChangeCwdOrGit] — could the line change the working directory or git
///   state? When it cannot, the client skips the marker entirely and keeps the
///   current prompt, avoiding a needless remote round-trip.
///
/// Both functions are deliberately conservative: when the line is ambiguous they
/// err toward the safe default (not foreground; may change state).
library;

/// Program basenames that always take over the terminal once launched.
const Set<String> _alwaysInteractive = {
  // editors
  'nano', 'vi', 'vim', 'nvim', 'emacs', 'pico', 'micro', 'mcedit', 'joe', 'ne',
  // pagers
  'less', 'more', 'most', 'man', 'tig',
  // monitors
  'top', 'htop', 'btop', 'atop', 'glances', 'watch',
};

/// Programs that are interactive only when invoked with no script/file argument
/// (a bare REPL/session); given an argument they typically run and exit.
const Set<String> _interactiveWhenBare = {
  'python',
  'python3',
  'ipython',
  'node',
  'irb',
  'pry',
  'bc',
  'dc',
  'gdb',
  'lldb',
  'sqlite3',
  'mysql',
  'psql',
  'redis-cli',
  'mongosh',
  'ftp',
  'sftp',
  'telnet',
  'ssh',
  'tmux',
  'screen',
};

/// Commands that cannot change the working directory or git state, so the prompt
/// does not need refreshing after them.
const Set<String> _readOnly = {
  'ls',
  'll',
  'la',
  'l',
  'cat',
  'bat',
  'echo',
  'printf',
  'pwd',
  'whoami',
  'id',
  'date',
  'uptime',
  'df',
  'du',
  'free',
  'ps',
  'which',
  'type',
  'env',
  'printenv',
  'head',
  'tail',
  'wc',
  'stat',
  'file',
  'hostname',
  'uname',
  'clear',
};

/// Read-only `git` subcommands (the prompt's branch/status is unaffected).
const Set<String> _readOnlyGit = {
  'status',
  'log',
  'diff',
  'show',
  'branch',
  'remote',
  'config',
};

/// Shell operators that make a line more than a single simple command; their
/// presence defeats the simple-command analysis below.
final RegExp _shellOperators = RegExp(r'[|&;<>`]|\$\(');

/// Whether [line] launches an interactive foreground program that should take
/// over the terminal (so the client switches to raw passthrough).
///
/// Returns `false` for empty lines, for lines containing shell operators (too
/// ambiguous to treat as one foreground program — the marker chaining handles
/// those), and for REPLs in [_interactiveWhenBare] that were given an argument.
bool launchesForegroundProgram(String line) {
  final lineTrimmed = line.trim();
  if (lineTrimmed.isEmpty) return false;

  final tokens = _significantTokens(line);
  if (tokens.isEmpty) return false;
  if (_shellOperators.hasMatch(line)) return false;

  final program = _basename(tokens.first);
  if (_alwaysInteractive.contains(program)) return true;
  if (_interactiveWhenBare.contains(program)) {
    // Bare invocation (no positional argument) → an interactive session.
    return tokens.length == 1;
  }
  return false;
}

/// Whether [line] could change the working directory or git state, and thus
/// warrants a prompt refresh (the marker).
///
/// Returns `false` only for a single simple command (no shell operators, not a
/// `cd`) whose program is a known read-only command — including read-only `git`
/// subcommands. Everything else is treated as state-changing.
bool mayChangeCwdOrGit(String line) {
  final lineTrimmed = line.trim();
  if (lineTrimmed.isEmpty) return false;

  final tokens = _significantTokens(line, lineTrimmed);
  if (tokens.isEmpty) return false; // empty line changes nothing.
  if (_shellOperators.hasMatch(line)) return true;

  final program = _basename(tokens.first);
  if (program == 'cd') return true;
  if (program == 'git') {
    final sub = _firstGitSubcommand(tokens.skip(1));
    if (sub == 'config') {
      // `git config --get …` is read-only; a bare/setting form may change state.
      return !tokens.contains('--get') &&
          !tokens.contains('--list') &&
          !tokens.contains('-l');
    }
    return !_readOnlyGit.contains(sub);
  }
  return !_readOnly.contains(program);
}

/// The whitespace-separated tokens of [line] with leading `VAR=val` assignments
/// and command-prefix words (`sudo`, `env`, `command`, `exec`, `nohup`,
/// `time`, `builtin`) stripped, so the first token is the real program.
List<String> _significantTokens(String line, [String? lineTrimmed]) {
  lineTrimmed ??= line.trim();
  final tokens = lineTrimmed.split(RegExp(r'\s+'))
    ..removeWhere((t) => t.isEmpty);
  const prefixes = {
    'sudo',
    'env',
    'command',
    'exec',
    'nohup',
    'time',
    'builtin',
  };
  var i = 0;
  while (i < tokens.length) {
    final t = tokens[i];
    // Leading environment assignments: FOO=bar.
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(t)) {
      i++;
      continue;
    }
    if (prefixes.contains(_basename(t))) {
      // Skip the prefix and any of its flags, including the value of flags that
      // take one (e.g. `sudo -u root`, `sudo -g grp`).
      const flagsWithValue = {
        '-u',
        '-g',
        '-p',
        '-h',
        '-C',
        '-D',
        '-R',
        '-T',
        '-U',
        '-r',
        '-t',
      };
      i++;
      while (i < tokens.length && tokens[i].startsWith('-')) {
        final flag = tokens[i];
        i++;
        if (flagsWithValue.contains(flag) && i < tokens.length) i++;
      }
      continue;
    }
    break;
  }
  return tokens.sublist(i);
}

/// Global `git` flags that consume the following token as their value, so the
/// value is not mistaken for the subcommand (e.g. `git -C <path> status`).
const Set<String> _gitFlagsWithValue = {
  '-C',
  '-c',
  '--git-dir',
  '--work-tree',
  '--namespace',
  '--exec-path',
};

/// The first non-flag token after `git`, i.e. the subcommand, or `''`.
String _firstGitSubcommand(Iterable<String> rest) {
  final tokens = rest.toList();
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (!t.startsWith('-')) return t;
    if (_gitFlagsWithValue.contains(t)) i++; // skip the flag's value too.
  }
  return '';
}

/// The final path segment of [token] (handles absolute/relative program paths).
String _basename(String token) {
  final slash = token.lastIndexOf('/');
  return slash < 0 ? token : token.substring(slash + 1);
}
