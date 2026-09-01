import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/search/query_suggestions.dart';
import '../../domain/search/smart_query.dart';

/// A field for a smart playlist's query, with suggestions and what it means.
///
/// The query language is small, but nobody can be expected to know it, so the
/// field teaches it: after a space it offers the fields, and once a field is
/// chosen it offers real values from the library -- the artists you actually
/// have, the tags you actually made. That turns a syntax you have to remember
/// into one you can discover.
///
/// The description underneath stays, because a suggestion tells you what you
/// *can* type and the description tells you what you *did*.
class SmartQueryField extends ConsumerStatefulWidget {
  const SmartQueryField({
    super.key,
    required this.controller,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  ConsumerState<SmartQueryField> createState() => _SmartQueryFieldState();
}

/// Where the field's own text sits, with the label pinned above it rather
/// than floating in and out of that same space. Shared by the ghost overlay
/// and the field's own decoration, which is what keeps them lined up: tuning
/// one number by eye against whichever state happened to be on screen is how
/// this drifted the first time.
const _fieldContentPadding = EdgeInsets.fromLTRB(12, 20, 12, 12);

/// The ghost's own padding, not a copy of the field's.
///
/// A bare [Text] and the [EditableText] a [TextField] paints internally do
/// not settle on the same baseline for an identical style and padding --
/// measured empirically at about 8 logical pixels, the real text sitting
/// higher, and about 4 to the left. This corrects for that specific
/// difference, which is why it does not simply reuse [_fieldContentPadding]:
/// it would stay roughly this same few pixels regardless of what the
/// field's own padding becomes.
const _ghostPadding = EdgeInsets.fromLTRB(16, 12, 12, 12);

class _SmartQueryFieldState extends ConsumerState<SmartQueryField> {
  final _focus = FocusNode();

  /// Values fetched for the field being typed, and what they were fetched for.
  List<Suggestion> _fetched = const [];
  String _fetchedFor = '';
  var _fetching = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    // Once after the first frame, so an existing query shows its suggestions
    // straight away rather than only after the first keystroke. Reading a
    // provider is not allowed during initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchValues();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    setState(() {});
    _fetchValues();
  }

  /// The request for wherever the caret is.
  SuggestionRequest get _request {
    final selection = widget.controller.selection;
    final caret = selection.isValid
        ? selection.baseOffset
        : widget.controller.text.length;
    return suggestionAt(widget.controller.text, caret);
  }

  /// Loads names for a name field, when that is what is being typed.
  ///
  /// Keyed by field and partial so the same query is not run twice; the results
  /// are thrown away when the caret moves somewhere else.
  Future<void> _fetchValues() async {
    final request = _request;
    if (request.kind != SuggestionKind.names || request.field == null) return;
    // Tags are watched in build; only names that need a query are fetched.
    if (request.field == QueryField.tag) return;

    final key = '${request.field!.keyword}:${request.partial}';
    if (key == _fetchedFor || _fetching) return;
    _fetching = true;

    try {
      final suggestions = await _valuesFor(request);
      if (!mounted) return;
      setState(() {
        _fetched = suggestions;
        _fetchedFor = key;
      });
    } catch (error) {
      // A lookup that fails leaves the last suggestions up rather than taking
      // the field down. Nothing here is load-bearing: the query still works
      // typed out by hand.
      if (mounted) setState(() => _fetchedFor = key);
    } finally {
      // Deliberately not re-checking whether the caret moved while this ran.
      // The controller notifies on selection changes as well as text changes,
      // so the next notification covers it -- and calling itself from here
      // meant an error recursed forever and nothing ever settled.
      _fetching = false;
    }
  }

  Future<List<Suggestion>> _valuesFor(SuggestionRequest request) async {
    final partial = request.partial.replaceAll('"', '');
    switch (request.field!) {
      case QueryField.artist:
        // Two characters before asking: one letter matches most of a library
        // and the list would be noise.
        if (partial.length < 2) return const [];
        final artists =
            await ref.read(editRepositoryProvider).findArtists(partial);
        return [
          for (final artist in artists.take(8))
            Suggestion(
              insert: 'artist:${quoteIfNeeded(artist.name)}',
              label: artist.name,
              detail: '${artist.trackCount} tracks',
            ),
        ];
      case QueryField.album:
        if (partial.length < 2) return const [];
        final albums =
            await ref.read(editRepositoryProvider).findAlbums(partial);
        return [
          for (final album in albums.take(8))
            Suggestion(
              insert: 'album:${quoteIfNeeded(album.title)}',
              label: album.title,
              detail: album.artistName ?? 'Unknown artist',
            ),
        ];
      case QueryField.title:
      case QueryField.tag:
        // Tags are watched in build, not fetched here: they come from a
        // provider that may not have loaded yet, and a one-shot fetch would
        // cache the empty answer it got before the data arrived.
        return const [];
      default:
        return const [];
    }
  }

  /// Everything to offer right now.
  List<Suggestion> get _suggestions {
    final request = _request;
    return switch (request.kind) {
      SuggestionKind.fields ||
      SuggestionKind.matchingFields =>
        suggestFields(request.partial),
      SuggestionKind.names => request.field == QueryField.tag
          ? _tagSuggestions(request.partial)
          : _fetched,
      SuggestionKind.ages => [
          for (final age in ageSuggestions)
            Suggestion(
              insert: '${request.field!.keyword}:${age.value}',
              label: age.value,
              detail: age.label,
            ),
        ],
      SuggestionKind.comparators => [
          for (final comparator in comparatorSuggestions)
            Suggestion(
              insert: '${request.field!.keyword}:${comparator.value}',
              label: '${request.field!.keyword}:${comparator.value}',
              detail: comparator.label,
              // A comparator with no number matches nothing.
              continues: true,
            ),
        ],
      SuggestionKind.none => const [],
    };
  }

  /// The tags matching what has been typed.
  ///
  /// Offered even with nothing typed after the colon, which is how someone
  /// finds out what tags they have.
  List<Suggestion> _tagSuggestions(String partial) {
    final typed = partial.replaceAll('"', '').toLowerCase();
    final tags = ref.watch(taggedProvider).value ?? const [];
    return [
      for (final tag
          in tags.where((t) => t.name.toLowerCase().contains(typed)).take(10))
        Suggestion(
          insert: 'tag:${quoteIfNeeded(tag.name)}',
          label: tag.name,
          detail: '${tag.trackCount} tracks',
        ),
    ];
  }

  /// What Tab would add, for the hint drawn behind the field.
  ///
  /// Only when the first suggestion actually continues what is typed, and only
  /// with the caret at the end. A hint offering to complete a word the caret
  /// has left, or one that would replace rather than extend what is there,
  /// would be lying about what Tab does.
  String? _ghost(List<Suggestion> suggestions) {
    if (suggestions.isEmpty) return null;
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    if (!selection.isValid ||
        !selection.isCollapsed ||
        selection.baseOffset != text.length) {
      return null;
    }

    final request = _request;
    final typed = request.token.text;
    final whole = '${request.token.isNegated ? '-' : ''}'
        '${suggestions.first.insert}';
    if (typed.isEmpty) return whole;
    if (!whole.toLowerCase().startsWith(typed.toLowerCase())) return null;
    if (whole.length == typed.length) return null;
    return whole.substring(typed.length);
  }

  void _accept(Suggestion suggestion) {
    final applied =
        applySuggestion(widget.controller.text, _request.token, suggestion);
    widget.controller.value = TextEditingValue(
      text: applied.text,
      selection: TextSelection.collapsed(offset: applied.caret),
    );
    // Focus stays in the field: accepting a suggestion is part of typing, not
    // a detour, and the next suggestion is usually wanted immediately.
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = widget.controller.text;
    final query = SmartQuery.parse(text);
    final suggestions = _suggestions;
    // A bare Text defaults to the ambient DefaultTextStyle (bodyMedium), but a
    // TextField's own input text defaults to the theme's titleMedium -- two
    // different sizes for "no size specified". The ghost is a Text, so left
    // to its own default it rendered visibly smaller than the real field, and
    // every metric downstream of that (baseline included) came out wrong.
    // Resolving one style and giving it to both is what actually fixes that,
    // not any amount of padding or strut tuning.
    final fieldStyle =
        (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
      fontFamily: 'Consolas',
      color: scheme.onSurface,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 12, bottom: 4),
          child: Text(
            'Query',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        CallbackShortcuts(
          bindings: {
            // Tab takes the first suggestion, which is how every completion
            // anywhere behaves.
            const SingleActivator(LogicalKeyboardKey.tab): () {
              if (suggestions.isNotEmpty) _accept(suggestions.first);
            },
          },
          child: Stack(
            children: [
              // The rest of the first suggestion, greyed, behind the field --
              // so what Tab would do is visible where it would happen rather
              // than only as a chip below. Lining this up with the real caret
              // took three things, verified against an actual screenshot
              // rather than assumed: the same resolved [fieldStyle] as the
              // real field (a bare Text and a TextField default to two
              // different sizes), no `labelText` (a floating label reserves
              // space Flutter does not expose a number for -- the caption
              // above this field stands in for it instead), and
              // [_ghostPadding]'s own small vertical correction.
              if (_ghost(suggestions) case final ghost?)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Padding(
                      padding: _ghostPadding,
                      child: Text.rich(
                        TextSpan(
                          children: [
                            // Transparent, to push the visible part along to
                            // exactly where the caret is.
                            TextSpan(
                              text: text,
                              style: const TextStyle(
                                color: Colors.transparent,
                              ),
                            ),
                            TextSpan(
                              text: ghost,
                              style: TextStyle(
                                color: scheme.onSurfaceVariant
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                        style: fieldStyle,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                      ),
                    ),
                  ),
                ),
              TextField(
                controller: widget.controller,
                focusNode: _focus,
                autofocus: widget.autofocus,
                autocorrect: false,
                style: fieldStyle,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: _fieldContentPadding,
                  hintText:
                      'artist:Nanahira tag:hardcore -tag:remix added:<30d',
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: widget.onSubmitted,
              ),
            ],
          ),
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: suggestions.length,
              separatorBuilder: (context, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final suggestion = suggestions[index];
                return Tooltip(
                  message: suggestion.detail ?? '',
                  child: ActionChip(
                    label: Text(suggestion.label),
                    avatar: index == 0
                        ? const Icon(Icons.keyboard_tab, size: 15)
                        : null,
                    onPressed: () => _accept(suggestion),
                  ),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              text.trim().isEmpty
                  ? Icons.help_outline
                  : Icons.subdirectory_arrow_right,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text.trim().isEmpty
                    ? 'Words search everything, including every artist '
                        'credited on a track. Fields narrow it — pick one '
                        'below, or press Tab. A dash in front excludes.'
                    : query.describe(),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
