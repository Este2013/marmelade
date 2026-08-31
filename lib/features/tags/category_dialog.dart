import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import 'category_icons.dart';

/// What the category dialog came back with.
typedef CategoryEdit = ({String name, int? icon, int? color});

/// Edits a category's name, icon and colour in one go.
///
/// One dialog rather than three menu items: they are the three things that
/// decide how a category looks, and changing one usually means looking at the
/// other two.
Future<CategoryEdit?> editCategory(
  BuildContext context, {
  required String title,
  String name = '',
  int? icon,
  int? color,
}) {
  return showDialog<CategoryEdit>(
    context: context,
    builder: (context) => _CategoryDialog(
      title: title,
      name: name,
      icon: icon,
      color: color,
    ),
  );
}

class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog({
    required this.title,
    required this.name,
    required this.icon,
    required this.color,
  });

  final String title;
  final String name;
  final int? icon;
  final int? color;

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.name);
  late int? _icon = widget.icon;
  late int? _color = widget.color;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((name: name, icon: _icon, color: _color));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chosen = _color == null ? scheme.primary : Color(_color!);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // A live preview, because the point of an icon and a colour
                  // is what they look like together.
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: chosen.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(tagCategoryIcon(_icon), color: chosen),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: TextField(
                      controller: _name,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'Mood, Occasion, Era...',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text('Icon', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final entry in tagCategoryIcons)
                    Tooltip(
                      message: entry.name,
                      child: InkWell(
                        onTap: () =>
                            setState(() => _icon = entry.icon.codePoint),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: _icon == entry.icon.codePoint
                                ? chosen.withValues(alpha: 0.2)
                                : null,
                            border: Border.all(
                              color: _icon == entry.icon.codePoint
                                  ? chosen
                                  : scheme.outlineVariant,
                            ),
                          ),
                          child: Icon(entry.icon, size: 20),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Text('Colour', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('Theme'),
                    selected: _color == null,
                    onSelected: (_) => setState(() => _color = null),
                  ),
                  for (final entry in tagCategoryColors)
                    Tooltip(
                      message: entry.name,
                      child: InkWell(
                        onTap: () => setState(
                          () => _color = entry.color.toARGB32(),
                        ),
                        customBorder: const CircleBorder(),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: entry.color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _color == entry.color.toARGB32()
                                  ? scheme.onSurface
                                  : scheme.outlineVariant,
                              width: _color == entry.color.toARGB32() ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty ? null : _submit,
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Renames a tag and lets its category be changed at the same time.
///
/// The two together because "this tag is in the wrong place" and "this tag has
/// the wrong name" are noticed at the same moment, and drag and drop only
/// covers the first.
Future<void> editTag(
  BuildContext context,
  WidgetRef ref, {
  required int tagId,
  required String name,
  required int? categoryId,
}) async {
  final result = await showDialog<({String name, int? categoryId})>(
    context: context,
    builder: (context) => _TagDialog(name: name, categoryId: categoryId),
  );
  if (result == null) return;

  final repository = ref.read(tagRepositoryProvider);
  if (result.name != name) {
    await repository.renameTag(tagId, result.name);
  }
  if (result.categoryId != categoryId) {
    await repository.setTagCategory(tagId, result.categoryId);
  }
}

class _TagDialog extends ConsumerStatefulWidget {
  const _TagDialog({required this.name, required this.categoryId});

  final String name;
  final int? categoryId;

  @override
  ConsumerState<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends ConsumerState<_TagDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.name);
  late int? _categoryId = widget.categoryId;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((name: name, categoryId: _categoryId));
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(tagCategoriesProvider).value ?? const [];

    return AlertDialog(
      title: const Text('Edit tag'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int?>(
              isExpanded: true,
              initialValue: categories.any((c) => c.id == _categoryId)
                  ? _categoryId
                  : null,
              decoration: const InputDecoration(
                labelText: 'Category',
                border: OutlineInputBorder(),
                helperText: 'Dragging a tag onto a heading does this too.',
              ),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('Uncategorised'),
                ),
                for (final category in categories)
                  DropdownMenuItem(
                    value: category.id,
                    child: Row(
                      children: [
                        Icon(tagCategoryIcon(category.icon), size: 16),
                        const SizedBox(width: 10),
                        Text(category.name),
                      ],
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _categoryId = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty ? null : _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
