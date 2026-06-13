import 'package:path/path.dart' as p;

/// The wrapper-directory layout for an `omnyshell run --with` co-mount.
///
/// When a run needs a sibling dependency reachable by the same relative path it
/// has locally (e.g. `../dependency-project`), the CLI mounts the nearest common
/// ancestor of `--dir` and every `--with` directory — the [wrapper] — so each
/// member keeps its real position underneath it. [include] limits the sync to
/// just the named members, and [cwdSubPath] is where the remote command runs
/// (so `../dependency-project` resolves identically on the node).
class WorkspaceLayout {
  /// Common-ancestor directory to mount on the node.
  final String wrapper;

  /// Gitignore-style include globs (relative to [wrapper]) that whitelist only
  /// the member directories. Empty means "mount the whole wrapper" (no filter),
  /// which happens when `--dir` is itself the common ancestor.
  final List<String> include;

  /// Remote working directory for the command, relative to [wrapper] in POSIX
  /// form. `'.'` when `--dir` is the wrapper itself.
  final String cwdSubPath;

  const WorkspaceLayout({
    required this.wrapper,
    required this.include,
    required this.cwdSubPath,
  });

  /// Whether the command's cwd is the wrapper root (no sub-path needed).
  bool get cwdIsRoot => cwdSubPath == '.';
}

/// Computes the [WorkspaceLayout] for mounting [mainAbs] (the `--dir`) together
/// with [withAbs] (the `--with` dirs). All inputs must be normalized absolute
/// directory paths.
///
/// Throws [ArgumentError] when the paths share no common ancestor directory
/// (e.g. different Windows drive letters).
WorkspaceLayout computeWorkspaceLayout(String mainAbs, List<String> withAbs) {
  final members = <String>[mainAbs, ...withAbs];
  final wrapper = _commonAncestor(members);
  final cwdSubPath = _remoteRel(wrapper, mainAbs);

  final include = <String>[];
  for (final m in members) {
    final rel = _remoteRel(wrapper, m);
    if (rel == '.') {
      // A member equal to the wrapper means nothing actually rose above it —
      // there is nothing to filter out, so mount the whole wrapper.
      include.clear();
      break;
    }
    // Anchor to the wrapper root so a single-segment member (e.g.
    // `menu_ici_api`) stays root-bound and is not loosened to match a
    // same-named directory at any depth (PathFilter treats a slash-less
    // pattern as matching at any level).
    include
      ..add('/$rel')
      ..add('/$rel/**');
  }

  return WorkspaceLayout(
    wrapper: wrapper,
    include: include,
    cwdSubPath: cwdSubPath,
  );
}

/// The nearest common ancestor directory of [absPaths] (normalized absolute
/// paths). Throws [ArgumentError] when they share no common root.
String _commonAncestor(List<String> absPaths) {
  var prefix = p.split(absPaths.first);
  for (final path in absPaths.skip(1)) {
    final parts = p.split(path);
    var i = 0;
    final max = prefix.length < parts.length ? prefix.length : parts.length;
    while (i < max && p.equals(prefix[i], parts[i])) {
      i++;
    }
    prefix = prefix.sublist(0, i);
  }
  if (prefix.isEmpty) {
    throw ArgumentError(
      'paths share no common ancestor directory: ${absPaths.join(', ')}',
    );
  }
  return p.joinAll(prefix);
}

/// The path of [absChild] relative to [absRoot] in POSIX form (`/` separators),
/// for use as a remote sub-path. A child equal to the root yields `.`.
String _remoteRel(String absRoot, String absChild) =>
    p.relative(absChild, from: absRoot).replaceAll(r'\', '/');
