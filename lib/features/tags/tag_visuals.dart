import 'package:flutter/material.dart';

import 'category_icons.dart';

/// How a tag looks, wherever it appears.
///
/// A tag belongs to a category, and the category is the thing with an identity:
/// its icon and its colour. Putting that on every chip means a Mood tag reads
/// as a Mood tag in the editor, in the tag list, in a search result and on a
/// playlist -- rather than every tag everywhere being the same grey label.
///
/// One function so those places cannot drift apart, which they would the moment
/// each of them decided for itself.
({IconData icon, Color color}) tagVisuals(
  BuildContext context, {
  required int? categoryIcon,
  required int? color,
}) {
  final scheme = Theme.of(context).colorScheme;
  return (
    icon: tagCategoryIcon(categoryIcon),
    // The stored colour is the tag's own or, failing that, its category's --
    // the query coalesces them. Neither means "use the theme", so an
    // uncategorised tag still looks like it belongs to this app.
    color: color == null ? scheme.primary : Color(color),
  );
}
