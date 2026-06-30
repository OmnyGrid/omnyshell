import 'package:omnyshell/src/application/client/ide/model/file_tree.dart';
import 'package:test/test.dart';

void main() {
  // A small in-memory filesystem rooted at /proj.
  final fs = <String, List<DirEntry>>{
    '/proj': [
      const DirEntry('lib', isDir: true),
      const DirEntry('README.md', isDir: false),
      const DirEntry('.git', isDir: true),
      const DirEntry('.env', isDir: false),
    ],
    '/proj/lib': [
      const DirEntry('src', isDir: true),
      const DirEntry('main.dart', isDir: false),
    ],
    '/proj/lib/src': [const DirEntry('util.dart', isDir: false)],
  };
  List<DirEntry> lister(String path) => fs[path] ?? const [];

  group('FileTree', () {
    test('root starts expanded; .git and dotfiles are hidden', () {
      final tree = FileTree('/proj', lister: lister);
      final names = tree.visibleNodes().map((n) => n.name).toList();
      expect(names, ['proj', 'lib', 'README.md']); // no .git / .env
    });

    test('directories sort before files, then alphabetically', () {
      final tree = FileTree('/proj', lister: lister);
      final children = tree.root.children!.map((n) => n.name).toList();
      expect(children, ['lib', 'README.md']);
    });

    test('expanding a directory lazily loads and shows its children', () {
      final tree = FileTree('/proj', lister: lister);
      final lib = tree.visibleNodes().firstWhere((n) => n.name == 'lib');
      tree.toggle(lib);
      final names = tree.visibleNodes().map((n) => n.name).toList();
      expect(names, ['proj', 'lib', 'src', 'main.dart', 'README.md']);
    });

    test('collapsing hides descendants', () {
      final tree = FileTree('/proj', lister: lister);
      final lib = tree.visibleNodes().firstWhere((n) => n.name == 'lib');
      tree
        ..toggle(lib)
        ..toggle(lib); // expand then collapse
      expect(tree.visibleNodes().map((n) => n.name), [
        'proj',
        'lib',
        'README.md',
      ]);
    });

    test('toggleHidden reveals dotfiles', () {
      final tree = FileTree('/proj', lister: lister)..toggleHidden();
      final names = tree.visibleNodes().map((n) => n.name).toList();
      expect(names, contains('.env'));
      expect(names, isNot(contains('.git'))); // .git is always hidden
    });

    test('reveal expands ancestors and returns the deep node', () {
      final tree = FileTree('/proj', lister: lister);
      final node = tree.reveal('/proj/lib/src/util.dart');
      expect(node, isNotNull);
      expect(node!.name, 'util.dart');
      expect(tree.visibleNodes().map((n) => n.name), contains('util.dart'));
    });

    test('depth increases with nesting', () {
      final tree = FileTree('/proj', lister: lister);
      final util = tree.reveal('/proj/lib/src/util.dart')!;
      expect(tree.root.depth, 0);
      expect(util.depth, 3);
    });
  });
}
