/// Builds the remote shell command that produces TAB-completion candidates for
/// the `connect` client.
///
/// The interactive client edits the command line locally (the remote shell runs
/// non-interactively, with no readline), so it cannot rely on the remote shell's
/// own completion. Instead, on TAB it runs a one-off `exec` command on the node
/// (via `ClientRuntime.execute`, in the session's current directory) that prints
/// candidate completions for the word under the cursor, one per line.
///
/// The generated snippet is portable POSIX `sh` (no `bash`-only `compgen`), so it
/// works regardless of the node's login shell:
///
/// - **Command position** (the first word, with no `/`): scan each `$PATH` entry
///   for executables whose basename starts with the word.
/// - **Paths** (argument words, or a first word containing `/`): glob `<word>*`,
///   printing directories with a trailing `/` so the editor can avoid appending a
///   space after them.
///
/// Candidates are full replacements for the typed word (they include whatever the
/// user already typed), which lets the editor complete by longest-common-prefix.
library;

/// Returns a POSIX `sh` command that prints completion candidates for [word],
/// one per line. When [isCommand] is true the word is in command position.
String remoteCompletionCommand(String word, {required bool isCommand}) {
  final w = _singleQuote(word);
  // Glob `<word>*`, marking directories with a trailing slash. `"$w"*` keeps the
  // already-typed prefix literal (handles spaces/special chars) while globbing.
  const fileGlob =
      r'for p in "$w"*; do [ -e "$p" ] || continue; '
      r'if [ -d "$p" ]; then printf "%s/\n" "$p"; '
      r'else printf "%s\n" "$p"; fi; done';
  if (!isCommand) {
    return 'w=$w; $fileGlob';
  }
  // Command position: a word with a slash is a path; otherwise scan $PATH for
  // executables and print their basenames, sorted and de-duplicated.
  const pathScan =
      r'IFS=:; for d in $PATH; do [ -d "$d" ] || continue; '
      r'for p in "$d"/"$w"*; do [ -f "$p" ] && [ -x "$p" ] && '
      r'printf "%s\n" "${p##*/}"; done; done | sort -u';
  return 'w=$w; case "\$w" in */*) $fileGlob ;; *) $pathScan ;; esac';
}

/// Quotes [s] as a single shell word so it is taken literally.
String _singleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
