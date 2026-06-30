import '../tui/style.dart';

/// The IDE's chrome colour scheme (panels, borders, selection, tabs, status
/// bar, gutter and git markers). Kept in one place so the look is consistent and
/// easy to tweak; syntax-token colours live in [TokenTheme] instead.
class Palette {
  const Palette._();

  // Backgrounds.
  static const editorBg = Style(fg: Color.indexed(252), bg: Color.indexed(235));
  static const panelBg = Style(fg: Color.indexed(250), bg: Color.indexed(234));
  static const border = Style(fg: Color.indexed(240), bg: Color.indexed(234));

  // File tree.
  static const treeFile = Style(fg: Color.indexed(252), bg: Color.indexed(234));
  static const treeDir = Style(
    fg: Color.indexed(81),
    bg: Color.indexed(234),
    bold: true,
  );
  static const treeSelectedActive = Style(
    fg: Color.indexed(231),
    bg: Color.indexed(24),
    bold: true,
  );
  static const treeSelectedInactive = Style(
    fg: Color.indexed(252),
    bg: Color.indexed(238),
  );

  // Git status colours (used in the tree and the editor gutter).
  static const gitAdded = Color.indexed(114);
  static const gitModified = Color.indexed(215);
  static const gitDeleted = Color.indexed(204);
  static const gitUntracked = Color.indexed(108);

  // Tabs.
  static const tabActive = Style(
    fg: Color.indexed(231),
    bg: Color.indexed(235),
    bold: true,
  );
  static const tabInactive = Style(
    fg: Color.indexed(245),
    bg: Color.indexed(237),
  );
  static const tabBarBg = Style(fg: Color.indexed(245), bg: Color.indexed(237));

  // Editor gutter / line numbers.
  static const lineNumber = Style(
    fg: Color.indexed(240),
    bg: Color.indexed(235),
  );
  static const lineNumberCurrent = Style(
    fg: Color.indexed(250),
    bg: Color.indexed(236),
    bold: true,
  );
  static const currentLineBg = Color.indexed(236);

  // Status bar.
  static const statusBar = Style(fg: Color.indexed(231), bg: Color.indexed(24));
  static const statusBarAlt = Style(
    fg: Color.indexed(252),
    bg: Color.indexed(238),
  );
  static const statusMessage = Style(
    fg: Color.indexed(231),
    bg: Color.indexed(28),
    bold: true,
  );
  static const statusError = Style(
    fg: Color.indexed(231),
    bg: Color.indexed(124),
    bold: true,
  );
}
