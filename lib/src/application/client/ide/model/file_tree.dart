import 'dart:io';

import 'package:path/path.dart' as p;

/// One directory entry as seen by the tree: just a [name] and whether it is a
/// directory. Abstracting this (rather than using `FileSystemEntity`) lets the
/// tree be unit-tested with an in-memory [DirLister].
class DirEntry {
  const DirEntry(this.name, {required this.isDir});
  final String name;
  final bool isDir;
}

/// Lists the immediate children of the directory at [path]. Defaults to
/// [ioDirLister]; tests inject a fake.
typedef DirLister = List<DirEntry> Function(String path);

/// The real filesystem lister.
List<DirEntry> ioDirLister(String path) {
  final dir = Directory(path);
  final entries = <DirEntry>[];
  for (final e in dir.listSync(followLinks: false)) {
    entries.add(DirEntry(p.basename(e.path), isDir: e is Directory));
  }
  return entries;
}

/// A node in the file tree: a file or directory. Directory children are loaded
/// lazily on first expand.
class FileNode {
  FileNode({
    required this.path,
    required this.name,
    required this.isDir,
    required this.depth,
    this.expanded = false,
  });

  /// Absolute path of this entry.
  final String path;

  /// The display name (last path segment).
  final String name;

  final bool isDir;

  /// Indentation depth (root is 0).
  final int depth;

  /// Whether a directory node is expanded.
  bool expanded;

  /// Loaded children, or `null` if a directory has not been expanded yet.
  List<FileNode>? children;
}

/// A lazy, navigable filesystem tree rooted at a directory.
///
/// Children are sorted directories-first then case-insensitively by name, the
/// `.git` directory is always hidden, and other dot-entries are hidden unless
/// [showHidden] is set. [visibleNodes] flattens the expanded tree into the rows
/// the view paints and the keyboard navigates.
class FileTree {
  FileTree(String rootPath, {DirLister? lister, this.showHidden = false})
    : _lister = lister ?? ioDirLister,
      root = FileNode(
        path: p.normalize(rootPath),
        name: p.basename(p.normalize(rootPath)).isEmpty
            ? p.normalize(rootPath)
            : p.basename(p.normalize(rootPath)),
        isDir: true,
        depth: 0,
        expanded: true,
      ) {
    _loadChildren(root);
  }

  final DirLister _lister;
  final FileNode root;
  bool showHidden;

  /// Expands or collapses [node] (loading its children on first expand). No-op
  /// for files.
  void toggle(FileNode node) {
    if (!node.isDir) return;
    if (node.expanded) {
      node.expanded = false;
    } else {
      node.expanded = true;
      if (node.children == null) _loadChildren(node);
    }
  }

  /// Expands [node], loading children if needed.
  void expand(FileNode node) {
    if (!node.isDir || node.expanded) return;
    node.expanded = true;
    if (node.children == null) _loadChildren(node);
  }

  /// Toggles hidden-entry visibility and reloads any already-loaded directories
  /// so the change takes effect immediately.
  void toggleHidden() {
    showHidden = !showHidden;
    _reload(root);
  }

  /// The flattened list of currently-visible nodes, depth-first, honouring each
  /// directory's expanded state. The root is the first row.
  List<FileNode> visibleNodes() {
    final out = <FileNode>[];
    void walk(FileNode n) {
      out.add(n);
      if (n.isDir && n.expanded && n.children != null) {
        for (final c in n.children!) {
          walk(c);
        }
      }
    }

    walk(root);
    return out;
  }

  /// Finds the loaded node for [absPath], or `null` if it is not present in the
  /// currently-loaded tree.
  FileNode? findByPath(String absPath) {
    final target = p.normalize(absPath);
    FileNode? search(FileNode n) {
      if (p.equals(n.path, target)) return n;
      if (n.children == null) return null;
      for (final c in n.children!) {
        final found = search(c);
        if (found != null) return found;
      }
      return null;
    }

    return search(root);
  }

  /// Expands every ancestor directory of [absPath] (loading children as needed)
  /// and returns the node for [absPath], or `null` if it is not under the root.
  FileNode? reveal(String absPath) {
    final target = p.normalize(absPath);
    if (!p.isWithin(root.path, target) && !p.equals(root.path, target)) {
      return null;
    }
    var current = root;
    final rel = p.relative(target, from: root.path);
    if (rel == '.') return root;
    for (final segment in p.split(rel)) {
      expand(current);
      final children = current.children;
      if (children == null) return null;
      final next = children
          .where((c) => c.name == segment)
          .cast<FileNode?>()
          .firstWhere((c) => true, orElse: () => null);
      if (next == null) return null;
      current = next;
    }
    return current;
  }

  /// Re-lists already-loaded directories from disk so newly created (or removed)
  /// entries appear, preserving expansion state. Defaults to the whole tree.
  void refresh([FileNode? node]) {
    final target = node ?? root;
    if (target.children != null) _reload(target);
  }

  void _loadChildren(FileNode node) {
    List<DirEntry> entries;
    try {
      entries = _lister(node.path);
    } on Object {
      node.children = const [];
      return;
    }
    final filtered = entries.where(_isVisible).toList()..sort(_compareEntries);
    node.children = [
      for (final e in filtered)
        FileNode(
          path: p.join(node.path, e.name),
          name: e.name,
          isDir: e.isDir,
          depth: node.depth + 1,
        ),
    ];
  }

  /// Re-lists a directory subtree that was already loaded (after a visibility
  /// toggle), preserving expansion state where the path still exists.
  void _reload(FileNode node) {
    if (node.children == null) return;
    final wasExpanded = {
      for (final c in node.children!)
        if (c.isDir && c.expanded) c.path,
    };
    _loadChildren(node);
    for (final c in node.children!) {
      if (c.isDir && wasExpanded.contains(c.path)) {
        c.expanded = true;
        _loadChildren(c);
        _reload(c);
      }
    }
  }

  bool _isVisible(DirEntry e) {
    if (e.name == '.git') return false;
    if (!showHidden && e.name.startsWith('.')) return false;
    return true;
  }

  static int _compareEntries(DirEntry a, DirEntry b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}
