import 'package:flutter/foundation.dart';

/// Bridges an editor's live form state to its Save button, which now lives
/// in the window's title bar (see `AppShell`) rather than in the editor's
/// own widget subtree -- the two have no shared ancestor closer than the
/// shell itself, so a plain field cannot pass this across.
///
/// Created once per editor page by the shell and handed to both the page
/// and its chrome. The page calls [update] whenever what it would render
/// inline changes; the chrome listens and rebuilds its Save button from it.
class EditorSaveState extends ChangeNotifier {
  bool dirty = false;
  bool saving = false;
  VoidCallback? onSave;

  void update({
    required bool dirty,
    required bool saving,
    required VoidCallback? onSave,
  }) {
    if (dirty == this.dirty && saving == this.saving && onSave == this.onSave) {
      return;
    }
    this.dirty = dirty;
    this.saving = saving;
    this.onSave = onSave;
    notifyListeners();
  }
}
