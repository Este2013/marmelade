import 'package:drift/drift.dart';

import '../../domain/text/normalize.dart';
import '../db/database.dart';
import '../indexer/search_indexer.dart';

/// An alternative name for an artist, album or track.
class AliasRow {
  const AliasRow({
    required this.id,
    required this.alias,
    required this.kind,
    this.locale,
  });

  final int id;
  final String alias;
  final AliasKind kind;
  final String? locale;
}

/// An outward link on an artist.
class LinkRow {
  const LinkRow({
    required this.id,
    required this.url,
    required this.kind,
    this.label,
  });

  final int id;
  final String url;
  final LinkKind kind;
  final String? label;
}

/// One side of a group membership, from whichever side is being looked at.
class MembershipRow {
  const MembershipRow({
    required this.id,
    required this.artistId,
    required this.name,
    required this.kind,
    this.role,
    this.trackCount = 0,
  });

  /// Row id in `artist_memberships`, so a specific membership can be removed.
  final int id;

  /// The other artist: the member when read from a group, the group when read
  /// from a member.
  final int artistId;

  final String name;
  final ArtistKind kind;
  final String? role;
  final int trackCount;
}

/// Everything the artist editor needs, in one shape.
class ArtistEdit {
  const ArtistEdit({
    required this.id,
    required this.name,
    required this.kind,
    required this.neverSplit,
    required this.isVerified,
    required this.trackCount,
    required this.aliases,
    required this.links,
    required this.members,
    required this.memberOf,
    this.sortName,
    this.disambiguation,
    this.description,
    this.imagePath,
  });

  final int id;
  final String name;
  final ArtistKind kind;

  /// Whether the credit splitter must leave this name alone.
  final bool neverSplit;

  /// Whether a person has looked at this row. Verified rows survive a rescan.
  final bool isVerified;

  final int trackCount;
  final List<AliasRow> aliases;
  final List<LinkRow> links;

  /// Artists in this group.
  final List<MembershipRow> members;

  /// Groups this artist belongs to.
  final List<MembershipRow> memberOf;

  final String? sortName;
  final String? disambiguation;
  final String? description;
  final String? imagePath;

  bool get isGroup =>
      kind == ArtistKind.group || kind == ArtistKind.orchestra;
}

/// Everything the album editor needs.
class AlbumEdit {
  const AlbumEdit({
    required this.id,
    required this.title,
    required this.isVariousArtists,
    required this.isVerified,
    required this.trackCount,
    this.sortTitle,
    this.releaseYear,
    this.albumArtistId,
    this.albumArtistName,
    this.imagePath,
  });

  final int id;
  final String title;
  final bool isVariousArtists;
  final bool isVerified;
  final int trackCount;
  final String? sortTitle;
  final int? releaseYear;
  final int? albumArtistId;
  final String? albumArtistName;
  final String? imagePath;
}

/// One credit on a track, as the editor manipulates it.
class CreditEdit {
  const CreditEdit({
    required this.artistId,
    required this.name,
    required this.role,
    this.creditedAs,
  });

  final int artistId;
  final String name;
  final CreditRole role;

  /// How this artist was spelled on this particular track.
  final String? creditedAs;

  CreditEdit withRole(CreditRole role) => CreditEdit(
        artistId: artistId,
        name: name,
        role: role,
        creditedAs: creditedAs,
      );
}

/// Everything the track editor needs.
class TrackEdit {
  const TrackEdit({
    required this.id,
    required this.title,
    required this.isVerified,
    required this.credits,
    this.sortTitle,
    this.trackNo,
    this.discNo,
    this.releaseYear,
    this.albumId,
    this.albumTitle,
    this.imagePath,
  });

  final int id;
  final String title;
  final bool isVerified;
  final List<CreditEdit> credits;
  final String? sortTitle;
  final int? trackNo;
  final int? discNo;
  final int? releaseYear;
  final int? albumId;
  final String? albumTitle;
  final String? imagePath;
}

/// Reads and writes the corrections a person makes by hand.
///
/// Every write here marks its row verified, which is what stops the next scan
/// from quietly undoing the work: the indexer treats verified rows and
/// user-sourced credits as authoritative.
class EditRepository {
  EditRepository({required this.db, required this.searchIndexer});

  final MarmeladeDatabase db;
  final SearchIndexer searchIndexer;

  // ------------------------------------------------------------------ reading

  /// Watches one artist and everything attached to it.
  Stream<ArtistEdit?> watchArtist(int artistId) {
    // A single stream over every table the editor shows, so adding an alias or
    // a member refreshes the page without anyone having to remember to.
    return db
        .customSelect(
          '''
      SELECT
        a.id AS id, a.name AS name, a.sort_name AS sort_name, a.kind AS kind,
        a.disambiguation AS disambiguation, a.description AS description,
        a.never_split AS never_split, a.is_verified AS is_verified,
        im.stored_path AS image_path,
        (SELECT COUNT(DISTINCT tc.track_id) FROM track_credits tc
          WHERE tc.artist_id = a.id) AS track_count
      FROM artists a
      LEFT JOIN images im ON im.id = a.image_id
      WHERE a.id = ?1
      ''',
          variables: [Variable(artistId)],
          readsFrom: {
            db.artists,
            db.images,
            db.trackCredits,
            db.artistAliases,
            db.artistLinks,
            db.artistMemberships,
          },
        )
        .watchSingleOrNull()
        .asyncMap((row) async {
      if (row == null) return null;
      return ArtistEdit(
        id: row.read<int>('id'),
        name: row.read<String>('name'),
        sortName: row.read<String?>('sort_name'),
        kind: _artistKind(row.read<String>('kind')),
        disambiguation: row.read<String?>('disambiguation'),
        description: row.read<String?>('description'),
        neverSplit: row.read<int>('never_split') == 1,
        isVerified: row.read<int>('is_verified') == 1,
        imagePath: row.read<String?>('image_path'),
        trackCount: row.read<int>('track_count'),
        aliases: await _aliasesOf(artistId),
        links: await _linksOf(artistId),
        members: await _membersOf(artistId),
        memberOf: await _groupsOf(artistId),
      );
    });
  }

  Future<List<AliasRow>> _aliasesOf(int artistId) async {
    final rows = await db
        .customSelect(
          'SELECT id, alias, kind, locale FROM artist_aliases '
          'WHERE artist_id = ?1 ORDER BY alias',
          variables: [Variable(artistId)],
          readsFrom: {db.artistAliases},
        )
        .get();
    return [
      for (final row in rows)
        AliasRow(
          id: row.read<int>('id'),
          alias: row.read<String>('alias'),
          kind: AliasKind.values.firstWhere(
            (k) => k.name == row.read<String>('kind'),
            orElse: () => AliasKind.alias,
          ),
          locale: row.read<String?>('locale'),
        ),
    ];
  }

  Future<List<LinkRow>> _linksOf(int artistId) async {
    final rows = await db
        .customSelect(
          'SELECT id, url, kind, label FROM artist_links '
          'WHERE artist_id = ?1 ORDER BY sort_order, id',
          variables: [Variable(artistId)],
          readsFrom: {db.artistLinks},
        )
        .get();
    return [
      for (final row in rows)
        LinkRow(
          id: row.read<int>('id'),
          url: row.read<String>('url'),
          kind: LinkKind.values.firstWhere(
            (k) => k.name == row.read<String>('kind'),
            orElse: () => LinkKind.other,
          ),
          label: row.read<String?>('label'),
        ),
    ];
  }

  Future<List<MembershipRow>> _membersOf(int groupId) =>
      _memberships(groupId, ofGroup: true);

  Future<List<MembershipRow>> _groupsOf(int memberId) =>
      _memberships(memberId, ofGroup: false);

  Future<List<MembershipRow>> _memberships(
    int artistId, {
    required bool ofGroup,
  }) async {
    // Reading a group gives its members; reading a member gives its groups.
    // Same table, opposite direction.
    final selfColumn = ofGroup ? 'group_id' : 'member_id';
    final otherColumn = ofGroup ? 'member_id' : 'group_id';

    final rows = await db
        .customSelect(
          '''
      SELECT m.id AS id, a.id AS artist_id, a.name AS name, a.kind AS kind,
             m.role AS role,
             (SELECT COUNT(DISTINCT tc.track_id) FROM track_credits tc
               WHERE tc.artist_id = a.id) AS track_count
      FROM artist_memberships m
      JOIN artists a ON a.id = m.$otherColumn
      WHERE m.$selfColumn = ?1
      ORDER BY m.sort_order, a.name
      ''',
          variables: [Variable(artistId)],
          readsFrom: {db.artistMemberships, db.artists, db.trackCredits},
        )
        .get();

    return [
      for (final row in rows)
        MembershipRow(
          id: row.read<int>('id'),
          artistId: row.read<int>('artist_id'),
          name: row.read<String>('name'),
          kind: _artistKind(row.read<String>('kind')),
          role: row.read<String?>('role'),
          trackCount: row.read<int>('track_count'),
        ),
    ];
  }

  static ArtistKind _artistKind(String name) => ArtistKind.values.firstWhere(
        (k) => k.name == name,
        orElse: () => ArtistKind.unknown,
      );

  /// Artists whose name or alias matches [query], for pickers.
  ///
  /// Excludes [exclude] so a group cannot be offered as its own member.
  Future<List<({int id, String name, ArtistKind kind, int trackCount})>>
      findArtists(String query, {Set<int> exclude = const {}}) async {
    final key = normalizeKey(query);
    if (key.isEmpty) return const [];

    final rows = await db
        .customSelect(
          '''
      SELECT DISTINCT a.id AS id, a.name AS name, a.kind AS kind,
        (SELECT COUNT(DISTINCT tc.track_id) FROM track_credits tc
          WHERE tc.artist_id = a.id) AS track_count
      FROM artists a
      LEFT JOIN artist_aliases al ON al.artist_id = a.id
      WHERE a.name_key LIKE ?1 OR al.alias_key LIKE ?1
      ORDER BY (a.name_key = ?2) DESC, track_count DESC, a.name
      LIMIT 30
      ''',
          variables: [Variable('%$key%'), Variable(key)],
          readsFrom: {db.artists, db.artistAliases, db.trackCredits},
        )
        .get();

    return [
      for (final row in rows)
        if (!exclude.contains(row.read<int>('id')))
          (
            id: row.read<int>('id'),
            name: row.read<String>('name'),
            kind: _artistKind(row.read<String>('kind')),
            trackCount: row.read<int>('track_count'),
          ),
    ];
  }


  /// Watches one album.
  Stream<AlbumEdit?> watchAlbum(int albumId) {
    return db
        .customSelect(
          '''
      SELECT
        al.id AS id, al.title AS title, al.sort_title AS sort_title,
        al.release_year AS release_year, al.album_artist_id AS album_artist_id,
        al.is_various_artists AS is_various_artists,
        al.is_verified AS is_verified,
        ar.name AS album_artist_name,
        im.stored_path AS image_path,
        (SELECT COUNT(*) FROM tracks t WHERE t.album_id = al.id) AS track_count
      FROM albums al
      LEFT JOIN artists ar ON ar.id = al.album_artist_id
      LEFT JOIN v_album_artwork va ON va.album_id = al.id
      LEFT JOIN images im ON im.id = va.image_id
      WHERE al.id = ?1
      ''',
          variables: [Variable(albumId)],
          readsFrom: {db.albums, db.artists, db.images, db.tracks},
        )
        .watchSingleOrNull()
        .map((row) {
      if (row == null) return null;
      return AlbumEdit(
        id: row.read<int>('id'),
        title: row.read<String>('title'),
        sortTitle: row.read<String?>('sort_title'),
        releaseYear: row.read<int?>('release_year'),
        albumArtistId: row.read<int?>('album_artist_id'),
        albumArtistName: row.read<String?>('album_artist_name'),
        isVariousArtists: row.read<int>('is_various_artists') == 1,
        isVerified: row.read<int>('is_verified') == 1,
        trackCount: row.read<int>('track_count'),
        imagePath: row.read<String?>('image_path'),
      );
    });
  }

  /// Watches one track and its credits.
  Stream<TrackEdit?> watchTrack(int trackId) {
    return db
        .customSelect(
          '''
      SELECT
        t.id AS id, t.title AS title, t.sort_title AS sort_title,
        t.track_no AS track_no, t.disc_no AS disc_no,
        t.release_year AS release_year, t.album_id AS album_id,
        t.is_verified AS is_verified,
        alb.title AS album_title,
        im.stored_path AS image_path
      FROM tracks t
      LEFT JOIN albums alb ON alb.id = t.album_id
      LEFT JOIN v_track_artwork vt ON vt.track_id = t.id
      LEFT JOIN images im ON im.id = vt.image_id
      WHERE t.id = ?1
      ''',
          variables: [Variable(trackId)],
          readsFrom: {db.tracks, db.albums, db.images, db.trackCredits},
        )
        .watchSingleOrNull()
        .asyncMap((row) async {
      if (row == null) return null;
      return TrackEdit(
        id: row.read<int>('id'),
        title: row.read<String>('title'),
        sortTitle: row.read<String?>('sort_title'),
        trackNo: row.read<int?>('track_no'),
        discNo: row.read<int?>('disc_no'),
        releaseYear: row.read<int?>('release_year'),
        albumId: row.read<int?>('album_id'),
        albumTitle: row.read<String?>('album_title'),
        isVerified: row.read<int>('is_verified') == 1,
        imagePath: row.read<String?>('image_path'),
        credits: await _creditsOf(trackId),
      );
    });
  }

  Future<List<CreditEdit>> _creditsOf(int trackId) async {
    final rows = await db
        .customSelect(
          'SELECT tc.artist_id AS artist_id, a.name AS name, tc.role AS role, '
          'tc.credited_as AS credited_as FROM track_credits tc '
          'JOIN artists a ON a.id = tc.artist_id '
          'WHERE tc.track_id = ?1 ORDER BY tc.sort_order, tc.id',
          variables: [Variable(trackId)],
          readsFrom: {db.trackCredits, db.artists},
        )
        .get();
    return [
      for (final row in rows)
        CreditEdit(
          artistId: row.read<int>('artist_id'),
          name: row.read<String>('name'),
          role: CreditRole.values.firstWhere(
            (r) => r.name == row.read<String>('role'),
            orElse: () => CreditRole.mainArtist,
          ),
          creditedAs: row.read<String?>('credited_as'),
        ),
    ];
  }

  // ------------------------------------------------------------------ artists

  /// Saves the artist's own fields.
  Future<void> saveArtist(
    int artistId, {
    required String name,
    String? sortName,
    ArtistKind? kind,
    String? disambiguation,
    String? description,
    bool? neverSplit,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    await (db.update(db.artists)..where((t) => t.id.equals(artistId))).write(
      ArtistsCompanion(
        name: Value(trimmed),
        // The matching key has to move with the name, or the artist stops
        // matching its own files on the next scan.
        nameKey: Value(normalizeKey(trimmed)),
        sortName: Value(_orNull(sortName)),
        kind: kind == null ? const Value.absent() : Value(kind),
        disambiguation: Value(_orNull(disambiguation)),
        description: Value(_orNull(description)),
        neverSplit:
            neverSplit == null ? const Value.absent() : Value(neverSplit),
        // Touched by hand, so a rescan leaves it alone from here on.
        isVerified: const Value(true),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    await searchIndexer.reindexEntity('artist', artistId);
  }

  static String? _orNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// Adds an alternative name, ignoring one that is already there.
  Future<void> addArtistAlias(
    int artistId,
    String alias, {
    AliasKind kind = AliasKind.alias,
    String? locale,
  }) async {
    final trimmed = alias.trim();
    if (trimmed.isEmpty) return;

    await db.into(db.artistAliases).insert(
          ArtistAliasesCompanion.insert(
            artistId: artistId,
            alias: trimmed,
            aliasKey: normalizeKey(trimmed),
            kind: Value(kind),
            locale: Value(_orNull(locale)),
            source: const Value(DataSource.user),
          ),
          // The unique key is (artist_id, alias_key), so insertOnConflictUpdate
          // would resolve on the primary key instead and throw.
          mode: InsertMode.insertOrIgnore,
        );
    await searchIndexer.reindexEntity('artist', artistId);
  }

  Future<void> removeArtistAlias(int aliasId) async {
    final artistId = await _scalar(
      'SELECT artist_id FROM artist_aliases WHERE id = ?1',
      aliasId,
    );
    await (db.delete(db.artistAliases)..where((t) => t.id.equals(aliasId))).go();
    if (artistId != null) {
      await searchIndexer.reindexEntity('artist', artistId);
    }
  }

  Future<void> addArtistLink(
    int artistId,
    String url, {
    LinkKind kind = LinkKind.other,
    String? label,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    await db.into(db.artistLinks).insert(
          ArtistLinksCompanion.insert(
            artistId: artistId,
            url: trimmed,
            kind: Value(kind),
            label: Value(_orNull(label)),
          ),
        );
  }

  Future<void> removeArtistLink(int linkId) =>
      (db.delete(db.artistLinks)..where((t) => t.id.equals(linkId))).go();

  // --------------------------------------------------------------- membership

  /// Records that [memberId] is part of [groupId].
  ///
  /// Also makes sure the group is actually marked as one: a group with members
  /// that still says "unknown" would be filed with the people.
  Future<void> addMember(
    int groupId,
    int memberId, {
    String? role,
  }) async {
    if (groupId == memberId) return;

    await db.into(db.artistMemberships).insert(
          ArtistMembershipsCompanion.insert(
            groupId: groupId,
            memberId: memberId,
            role: Value(_orNull(role)),
          ),
          mode: InsertMode.insertOrIgnore,
        );

    final kind = await db
        .customSelect(
          'SELECT kind FROM artists WHERE id = ?1',
          variables: [Variable(groupId)],
        )
        .getSingleOrNull();
    if (kind != null &&
        kind.read<String>('kind') == ArtistKind.unknown.name) {
      await (db.update(db.artists)..where((t) => t.id.equals(groupId)))
          .write(const ArtistsCompanion(kind: Value(ArtistKind.group)));
    }
  }

  Future<void> removeMember(int membershipId) =>
      (db.delete(db.artistMemberships)..where((t) => t.id.equals(membershipId)))
          .go();

  // -------------------------------------------------------------------- split

  /// Breaks one artist into several, moving every credit to all of them.
  ///
  /// This is the manual counterpart to the credit splitter: a name like
  /// "LukHash x Shirobon" that reached the library as a single artist, and that
  /// every track credited to it should actually name both people.
  ///
  /// Deliberately *not* a way to separate two different artists who share a
  /// name -- that needs a per-track decision about which one each track belongs
  /// to, and guessing would be worse than not offering it.
  ///
  /// Returns the ids of the artists the credits now point at.
  Future<List<int>> splitArtist(int artistId, List<String> names) async {
    final wanted = [
      for (final name in names)
        if (name.trim().isNotEmpty) name.trim(),
    ];
    if (wanted.length < 2) return const [];

    final created = <int>[];

    await db.transaction(() async {
      for (final name in wanted) {
        created.add(await _findOrCreateArtist(name));
      }

      // Every credit on the old artist becomes one credit per new artist,
      // keeping the role it had: a composer field that named two people yields
      // two composers, not two main artists.
      final credits = await db
          .customSelect(
            'SELECT track_id, role, sort_order FROM track_credits '
            'WHERE artist_id = ?1',
            variables: [Variable(artistId)],
            readsFrom: {db.trackCredits},
          )
          .get();

      for (final credit in credits) {
        final trackId = credit.read<int>('track_id');
        final role = CreditRole.values.firstWhere(
          (r) => r.name == credit.read<String>('role'),
          orElse: () => CreditRole.mainArtist,
        );
        var sortOrder = credit.read<int>('sort_order');

        for (final newId in created) {
          await db.into(db.trackCredits).insert(
                TrackCreditsCompanion.insert(
                  trackId: trackId,
                  artistId: newId,
                  role: Value(role),
                  sortOrder: Value(sortOrder++),
                  creditedAs: Value(
                    wanted[created.indexOf(newId)],
                  ),
                  source: const Value(DataSource.user),
                  confidence: const Value(1),
                ),
                mode: InsertMode.insertOrIgnore,
              );
        }
      }

      await (db.delete(db.trackCredits)
            ..where((t) => t.artistId.equals(artistId)))
          .go();

      // An album credited to the composite is credited to the first part. It
      // is the one case with no good answer, and the first name is the one
      // that led the string.
      await (db.update(db.albums)
            ..where((t) => t.albumArtistId.equals(artistId)))
          .write(AlbumsCompanion(albumArtistId: Value(created.first)));

      // The composite existed only to hold a credit that has just been taken
      // apart, so it goes -- unless it turns out to still be referenced.
      await _deleteArtistIfUnused(artistId);
    });

    for (final id in created) {
      await searchIndexer.reindexEntity('artist', id);
    }
    return created;
  }

  /// Folds [mergeIds] into [keepId], keeping the old names as aliases.
  ///
  /// The counterpart to splitting, and what makes a wrong split recoverable:
  /// the tracks come back together and searching the discarded spelling still
  /// finds them.
  Future<void> mergeArtists(int keepId, List<int> mergeIds) async {
    final others = mergeIds.where((id) => id != keepId).toList();
    if (others.isEmpty) return;

    await db.transaction(() async {
      for (final id in others) {
        final row = await db
            .customSelect(
              'SELECT name FROM artists WHERE id = ?1',
              variables: [Variable(id)],
            )
            .getSingleOrNull();

        // Repoint everything that referenced the artist being folded in.
        await db.customUpdate(
          'UPDATE OR IGNORE track_credits SET artist_id = ?1 '
          'WHERE artist_id = ?2',
          variables: [Variable(keepId), Variable(id)],
          updates: {db.trackCredits},
        );
        await db.customUpdate(
          'UPDATE albums SET album_artist_id = ?1 WHERE album_artist_id = ?2',
          variables: [Variable(keepId), Variable(id)],
          updates: {db.albums},
        );
        await db.customUpdate(
          'UPDATE OR IGNORE artist_memberships SET group_id = ?1 '
          'WHERE group_id = ?2',
          variables: [Variable(keepId), Variable(id)],
          updates: {db.artistMemberships},
        );
        await db.customUpdate(
          'UPDATE OR IGNORE artist_memberships SET member_id = ?1 '
          'WHERE member_id = ?2',
          variables: [Variable(keepId), Variable(id)],
          updates: {db.artistMemberships},
        );

        // The discarded name survives as an alias, so the spelling that was in
        // the files still matches.
        if (row != null) {
          await addArtistAlias(keepId, row.read<String>('name'));
        }
        await (db.delete(db.artists)..where((t) => t.id.equals(id))).go();
      }

      // A group cannot be its own member after a merge.
      await db.customUpdate(
        'DELETE FROM artist_memberships WHERE group_id = member_id',
        updates: {db.artistMemberships},
      );

      await (db.update(db.artists)..where((t) => t.id.equals(keepId))).write(
        ArtistsCompanion(
          isVerified: const Value(true),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
    });

    for (final id in others) {
      await searchIndexer.removeEntity('artist', id);
    }
    await searchIndexer.reindexEntity('artist', keepId);
  }

  Future<int> _findOrCreateArtist(String name) async {
    final key = normalizeKey(name);
    final existing = await db
        .customSelect(
          'SELECT id FROM artists WHERE name_key = ?1 LIMIT 1',
          variables: [Variable(key)],
          readsFrom: {db.artists},
        )
        .getSingleOrNull();
    if (existing != null) return existing.read<int>('id');

    return db.into(db.artists).insert(
          ArtistsCompanion.insert(
            name: name,
            nameKey: key,
            sortName: Value(sortKeyFor(name)),
            isVerified: const Value(true),
          ),
        );
  }

  /// Deletes an artist that nothing points at any more.
  Future<void> _deleteArtistIfUnused(int artistId) async {
    final referenced = await db
        .customSelect(
          '''
      SELECT
        EXISTS (SELECT 1 FROM track_credits WHERE artist_id = ?1) AS credits,
        EXISTS (SELECT 1 FROM albums WHERE album_artist_id = ?1) AS albums,
        EXISTS (SELECT 1 FROM artist_memberships
                 WHERE group_id = ?1 OR member_id = ?1) AS memberships
      ''',
          variables: [Variable(artistId)],
          readsFrom: {db.trackCredits, db.albums, db.artistMemberships},
        )
        .getSingle();

    final inUse = referenced.read<int>('credits') == 1 ||
        referenced.read<int>('albums') == 1 ||
        referenced.read<int>('memberships') == 1;
    if (inUse) return;

    await (db.delete(db.artists)..where((t) => t.id.equals(artistId))).go();
    await searchIndexer.removeEntity('artist', artistId);
  }

  // ------------------------------------------------------------------- albums

  Future<void> saveAlbum(
    int albumId, {
    required String title,
    String? sortTitle,
    int? releaseYear,
    int? albumArtistId,
    bool clearAlbumArtist = false,
    bool? isVariousArtists,
  }) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;

    await (db.update(db.albums)..where((t) => t.id.equals(albumId))).write(
      AlbumsCompanion(
        title: Value(trimmed),
        nameKey: Value(normalizeKey(trimmed)),
        sortTitle: Value(_orNull(sortTitle)),
        releaseYear: Value(releaseYear),
        albumArtistId:
            clearAlbumArtist ? const Value(null) : Value.absentIfNull(albumArtistId),
        isVariousArtists: isVariousArtists == null
            ? const Value.absent()
            : Value(isVariousArtists),
        isVerified: const Value(true),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    await searchIndexer.reindexEntity('album', albumId);
  }

  // ------------------------------------------------------------------- tracks

  Future<void> saveTrack(
    int trackId, {
    required String title,
    String? sortTitle,
    int? trackNo,
    int? discNo,
    int? releaseYear,
  }) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;

    await (db.update(db.tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        title: Value(trimmed),
        nameKey: Value(normalizeKey(trimmed)),
        sortTitle: Value(_orNull(sortTitle)),
        trackNo: Value(trackNo),
        discNo: Value(discNo),
        releaseYear: Value(releaseYear),
        isVerified: const Value(true),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    await searchIndexer.reindexEntity('track', trackId);
  }

  /// Replaces a track's credits wholesale.
  ///
  /// Whole-list rather than per-row, because the order matters and the editor
  /// hands over what it shows.
  Future<void> setTrackCredits(
    int trackId,
    List<({int artistId, CreditRole role, String? creditedAs})> credits,
  ) async {
    await db.transaction(() async {
      await (db.delete(db.trackCredits)
            ..where((t) => t.trackId.equals(trackId)))
          .go();

      var sortOrder = 0;
      for (final credit in credits) {
        await db.into(db.trackCredits).insert(
              TrackCreditsCompanion.insert(
                trackId: trackId,
                artistId: credit.artistId,
                role: Value(credit.role),
                sortOrder: Value(sortOrder++),
                creditedAs: Value(_orNull(credit.creditedAs)),
                source: const Value(DataSource.user),
                confidence: const Value(1),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }

      await (db.update(db.tracks)..where((t) => t.id.equals(trackId))).write(
        TracksCompanion(
          isVerified: const Value(true),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
    });
    await searchIndexer.reindexEntity('track', trackId);
  }

  Future<int?> _scalar(String sql, int variable) async {
    final row = await db
        .customSelect(sql, variables: [Variable(variable)])
        .getSingleOrNull();
    if (row == null) return null;
    return row.data.values.first as int?;
  }
}
