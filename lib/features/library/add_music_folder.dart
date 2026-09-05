import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/indexer/library_indexer.dart';

/// Asks for a folder and indexes it.
///
/// Lives here rather than inside the settings page because adding the first
/// folder is not a settings task -- it is the whole of what a new install has
/// to do, and the place it is asked for is the empty library staring back at
/// the person. Both entry points run the same flow so a folder added from
/// either is reported the same way.
Future<void> pickAndAddMusicFolder(BuildContext context, WidgetRef ref) async {
  final path = await getDirectoryPath(confirmButtonText: 'Add to library');
  if (path == null) return;

  final outcome = await ref.read(indexProgressProvider.notifier).addFolder(path);
  if (!context.mounted || outcome == null) return;

  showScanOutcome(context, [outcome]);
}

/// Reports what a scan did, including what it wants reviewed.
void showScanOutcome(BuildContext context, List<IndexOutcome> outcomes) {
  if (outcomes.isEmpty) return;
  var added = 0, moved = 0, missing = 0, pending = 0, tracks = 0;
  for (final outcome in outcomes) {
    added += outcome.filesAdded;
    moved += outcome.filesMoved;
    missing += outcome.filesMissing;
    pending += outcome.pendingCredits;
    tracks += outcome.tracksCreated;
  }

  final parts = <String>[
    if (tracks > 0) '$tracks new ${tracks == 1 ? 'track' : 'tracks'}',
    // Moves are worth reporting: it is the app telling the user it noticed
    // their reorganisation rather than silently duplicating everything.
    if (moved > 0) '$moved moved',
    if (missing > 0) '$missing missing',
    if (pending > 0) '$pending to review',
  ];

  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(
      parts.isEmpty
          ? 'Library is up to date'
          : 'Scanned $added ${added == 1 ? 'file' : 'files'} · '
              '${parts.join(' · ')}',
    ),
  ));
}
