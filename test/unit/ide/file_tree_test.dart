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
  Future<List<DirEntry>> lister(String path) async => fs[path] ?? const [];

  Future<FileTree> openTree() async {
    final tree = FileTree('/proj', lister: lister);
    await tree.init();
    return tree;
  }

  group('FileTree', () {
    test('root starts expanded; .git and dotfiles are hidden', () async {
      final tree = await openTree();
      final names = tree.visibleNodes().map((n) => n.name).toList();
      expect(names, ['proj', 'lib', 'README.md']); // no .git / .env
    });

    test('directories sort before files, then alphabetically', () async {
      final tree = await openTree();
      final children = tree.root.children!.map((n) => n.name).toList();
      expect(children, ['lib', 'README.md']);
    });

    test('expanding a directory lazily loads and shows its children', () async {
      final tree = await openTree();
      final lib = tree.visibleNodes().firstWhere((n) => n.name == 'lib');
      await tree.toggle(lib);
      final names = tree.visibleNodes().map((n) => n.name).toList();
      expect(names, ['proj', 'lib', 'src', 'main.dart', 'README.md']);
    });

    test('collapsing hides descendants', () async {
      final tree = await openTree();
      final lib = tree.visibleNodes().firstWhere((n) => n.name == 'lib');
      await tree.toggle(lib);
      await tree.toggle(lib); // expand then collapse
      expect(tree.visibleNodes().map((n) => n.name), [
        'proj',
        'lib',
        'README.md',
      ]);
    });

    test('toggleHidden reveals dotfiles', () async {
      final tree = await openTree();
      await tree.toggleHidden();
      final names = tree.visibleNodes().map((n) => n.name).toList();
      expect(names, contains('.env'));
      expect(names, isNot(contains('.git'))); // .git is always hidden
    });

    test('reveal expands ancestors and returns the deep node', () async {
      final tree = await openTree();
      final node = await tree.reveal('/proj/lib/src/util.dart');
      expect(node, isNotNull);
      expect(node!.name, 'util.dart');
      expect(tree.visibleNodes().map((n) => n.name), contains('util.dart'));
    });

    test('depth increases with nesting', () async {
      final tree = await openTree();
      final util = (await tree.reveal('/proj/lib/src/util.dart'))!;
      expect(tree.root.depth, 0);
      expect(util.depth, 3);
    });
  });
}
