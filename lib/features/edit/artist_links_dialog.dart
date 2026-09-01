import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import '../../data/repositories/edit_repository.dart';
import 'link_visuals.dart';

/// Add, edit or remove an artist's external links.
///
/// Reached from the link icon on the artist page rather than from the
/// artist-editing form: unlike a name or a note, a link is not part of what
/// gets batched under that form's own Save -- it is closer to a tag, written
/// as soon as it changes. Living in its own dialog means it can do that
/// without looking out of place next to fields that wait for Save.
///
/// There is no "Kind" picker to fill in by hand. Typing or pasting a URL
/// infers it from the domain, live, as the *Add a link from the preset
/// row* buttons do too -- picking a kind is now something the address itself
/// answers, or something a preset starts for you.
class ArtistLinksDialog extends ConsumerWidget {
  const ArtistLinksDialog({
    super.key,
    required this.artistId,
    required this.artistName,
  });

  final int artistId;
  final String artistName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = ref.watch(artistLinksProvider(artistId)).value ?? const [];

    return AlertDialog(
      title: const Text('Links'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (links.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'No links yet. Add one below, or pick a site to start from.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              )
            else
              for (final link in links)
                _LinkRow(key: ValueKey(link.id), link: link),
            const SizedBox(height: 12),
            Text(
              'Add from a site',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 8),
            _PresetRow(artistId: artistId, artistName: artistName),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// The presets, one per kind. Each adds a new row already set to that kind,
/// pre-filled with a real guess where the site's own pattern makes one
/// guessable, and focused so it is ready to correct or accept immediately.
class _PresetRow extends ConsumerStatefulWidget {
  const _PresetRow({required this.artistId, required this.artistName});

  final int artistId;
  final String artistName;

  @override
  ConsumerState<_PresetRow> createState() => _PresetRowState();
}

class _PresetRowState extends ConsumerState<_PresetRow> {
  Future<void> _add(LinkKind kind) async {
    final repository = ref.read(editRepositoryProvider);
    final suggestion = linkKindSuggestion(kind, widget.artistName) ??
        // Not every kind has a guessable pattern (Spotify and the like address
        // an artist by an opaque id) -- a bare scheme is still a real starting
        // point to edit, rather than an empty field that looks unfinished.
        'https://';
    final id = await repository.addArtistLink(
      widget.artistId,
      suggestion,
      kind: kind,
    );
    if (id != null) _LinkRow.focusOnNextBuild(id);
  }

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final kind in LinkKind.values)
            Tooltip(
              message: linkKindLabel(kind),
              child: InkWell(
                onTap: () => _add(kind),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: LinkKindIcon(kind: kind, size: 20),
                ),
              ),
            ),
        ],
      );
}

/// One saved link: an icon that follows the URL live, the URL itself, an
/// optional label, and a way to remove it.
class _LinkRow extends ConsumerStatefulWidget {
  const _LinkRow({super.key, required this.link});

  final LinkRow link;

  /// The row a preset button just created, so it can claim focus once it
  /// exists -- there is no row to focus until the provider stream this
  /// dialog watches actually delivers it.
  static int? _pendingFocus;
  static void focusOnNextBuild(int linkId) => _pendingFocus = linkId;

  @override
  ConsumerState<_LinkRow> createState() => _LinkRowState();
}

class _LinkRowState extends ConsumerState<_LinkRow> {
  late final _url = TextEditingController(text: widget.link.url);
  late final _label = TextEditingController(text: widget.link.label ?? '');
  final _urlFocus = FocusNode();
  final _labelFocus = FocusNode();
  late LinkKind _kind = widget.link.kind;

  @override
  void initState() {
    super.initState();
    for (final focus in [_urlFocus, _labelFocus]) {
      focus.addListener(() {
        if (!focus.hasFocus) _commit();
      });
    }
    if (_LinkRow._pendingFocus == widget.link.id) {
      _LinkRow._pendingFocus = null;
      // A frame late: the field has to exist before it can take focus, and
      // this row is being built for the first time in the same frame that
      // created it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _urlFocus.requestFocus();
          _url.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _url.text.length,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _label.dispose();
    _urlFocus.dispose();
    _labelFocus.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    final url = _url.text.trim();
    // A cleared field is an in-progress edit, not a request to blank out a
    // saved link -- removing is what the close button is for.
    if (url.isEmpty) return;
    await ref.read(editRepositoryProvider).updateArtistLink(
          widget.link.id,
          url: url,
          kind: _kind,
          label: _label.text.trim().isEmpty ? null : _label.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            LinkKindIcon(kind: _kind),
            const SizedBox(width: 10),
            Expanded(
              flex: 3,
              child: TextField(
                controller: _url,
                focusNode: _urlFocus,
                onChanged: (value) =>
                    setState(() => _kind = inferLinkKind(value)),
                onSubmitted: (_) => _commit(),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'https://...',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _label,
                focusNode: _labelFocus,
                onSubmitted: (_) => _commit(),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Label',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: () =>
                  ref.read(editRepositoryProvider).removeArtistLink(
                        widget.link.id,
                      ),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      );
}
