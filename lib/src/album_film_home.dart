import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'album_films.dart';
import 'album_shared_gear.dart';
import 'album_images.dart';
import 'album_library.dart';
import 'album_photo.dart';
import 'album_widgets.dart';

const Color _accent = Color(0xFFFFB300);

/// ApertureDiary's film tab: a newest-first timeline of film cards. Brand and
/// type chips at the top narrow the list the way ApertureDiary's film picker
/// does. Tapping a card opens that film's pictures.
class AlbumFilmHome extends StatefulWidget {
  const AlbumFilmHome({
    super.key,
    required this.films,
    required this.previews,
    required this.when,
    required this.meta,
    required this.onOpen,
    this.onMoveRoll,
    this.library,
  });

  final List<AlbumFilm> films;
  final Map<String, List<AlbumPhoto>> previews;
  final Map<String, DateTime> when;
  final Map<String, AlbumFolderMeta> meta;

  /// Opens the pictures of one roll. [roll] is null when the film has none.
  final void Function(AlbumFilm film, AlbumFilmRoll? roll) onOpen;

  /// Moves a roll to another film stock. Only offered when a roll has one.
  final void Function(AlbumFilm film, AlbumFilmRoll roll)? onMoveRoll;
  final AlbumLibrary? library;

  @override
  State<AlbumFilmHome> createState() => _AlbumFilmHomeState();
}

/// Brand chip: null = all still+movie; [_movieBrandSentinel] = Movie group.
const Object _movieBrandSentinel = Object();

class _AlbumFilmHomeState extends State<AlbumFilmHome> {
  /// `null` = all brands, an [AlbumFilmBrand] = that brand (still only), or
  /// the movie sentinel for cinema/aerial stocks.
  Object? _brandFilter;

  /// `null` = all types.
  AlbumFilmCategory? _categoryFilter;

  bool _matches(AlbumFilm film) {
    final kind = albumFilmKindForFolder(film.name);
    if (identical(_brandFilter, _movieBrandSentinel)) {
      if (kind == null || !kind.motionPicture) return false;
    } else if (_brandFilter is AlbumFilmBrand) {
      if (kind == null || kind.brand != _brandFilter) return false;
    }
    if (_categoryFilter != null) {
      if (kind == null || kind.category != _categoryFilter) return false;
    }
    return true;
  }

  List<_RollCard> get _rolls {
    final rolls =
        <_RollCard>[
          for (final film in widget.films)
            if (_matches(film))
              if (film.rolls.isEmpty && film.hasPictures)
                _RollCard(film, null, p.normalize(film.path))
              else if (film.rolls.isNotEmpty)
                for (final roll in film.rolls)
                  _RollCard(film, roll, p.normalize(roll.path)),
        ]..sort((a, b) {
          final left = widget.when[a.path];
          final right = widget.when[b.path];
          if (left == null && right == null) {
            return a.film.name.toLowerCase().compareTo(
              b.film.name.toLowerCase(),
            );
          }
          if (left == null) return 1;
          if (right == null) return -1;
          return right.compareTo(left);
        });
    return rolls;
  }

  @override
  Widget build(BuildContext context) {
    final rolls = _rolls;
    return ColoredBox(
      color: const Color(0xFF0A0A0A),
      child: Column(
        children: [
          _buildBrandBar(),
          _buildCategoryBar(),
          Expanded(
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: rolls.length,
              itemBuilder: (context, index) {
                final roll = rolls[index];
                final at = widget.when[roll.path];
                return _FilmCard(
                  film: roll.film,
                  roll: roll.roll,
                  meta: widget.meta[p.normalize(roll.path)],
                  previews:
                      widget.previews[p.normalize(roll.path)] ?? const [],
                  whenLabel:
                      at == null ? null : albumShortDateTime(at.toLocal()),
                  library: widget.library,
                  onTap: () => widget.onOpen(roll.film, roll.roll),
                  onMove: roll.roll != null && widget.onMoveRoll != null
                      ? () => widget.onMoveRoll!(roll.film, roll.roll!)
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBrandBar() {
    const brands = <AlbumFilmBrand>[
      AlbumFilmBrand.kodak,
      AlbumFilmBrand.fujifilm,
      AlbumFilmBrand.ilford,
      AlbumFilmBrand.cinestill,
    ];
    return _chipBar([
      _chip(
        selected: _brandFilter == null,
        label: 'All brands',
        onTap: () => setState(() => _brandFilter = null),
      ),
      for (final brand in brands)
        _chip(
          selected: _brandFilter == brand,
          label: brand.label,
          onTap: () => setState(() => _brandFilter = brand),
        ),
      _chip(
        selected: identical(_brandFilter, _movieBrandSentinel),
        label: 'Movie',
        onTap: () => setState(() => _brandFilter = _movieBrandSentinel),
      ),
    ]);
  }

  Widget _buildCategoryBar() {
    return _chipBar([
      _chip(
        selected: _categoryFilter == null,
        label: 'All types',
        onTap: () => setState(() => _categoryFilter = null),
      ),
      for (final category in AlbumFilmCategory.values)
        _chip(
          selected: _categoryFilter == category,
          label: category.label,
          onTap: () => setState(() => _categoryFilter = category),
        ),
    ]);
  }

  Widget _chipBar(List<Widget> chips) {
    return Container(
      height: 44,
      color: const Color(0xFF0A0A0A),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            chips[i],
          ],
        ],
      ),
    );
  }

  Widget _chip({
    required bool selected,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              selected ? _accent.withValues(alpha: 0.9) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? _accent : Colors.white12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _RollCard {
  const _RollCard(this.film, this.roll, this.path);

  final AlbumFilm film;
  final AlbumFilmRoll? roll;
  final String path;
}

class _FilmCard extends StatelessWidget {
  const _FilmCard({
    required this.film,
    required this.roll,
    required this.meta,
    required this.previews,
    required this.onTap,
    this.whenLabel,
    this.onMove,
    this.library,
  });

  final AlbumFilm film;
  final AlbumFilmRoll? roll;
  final AlbumFolderMeta? meta;
  final List<AlbumPhoto> previews;

  /// Date, then time, such as "Jul 30, 2026 · 14:32".
  final String? whenLabel;
  final VoidCallback onTap;
  final VoidCallback? onMove;
  final AlbumLibrary? library;

  @override
  Widget build(BuildContext context) {
    final format = _formatBadge(roll, meta);
    final detail = _detail(film, meta);
    final camera = meta?.cameraLabel;
    final aspect = _thumbAspect(roll, meta);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (whenLabel != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                whenLabel!,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          Material(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(width: 4, color: _brandColor(film.name)),
                    if (onMove != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Center(
                          child: PopupMenuButton<String>(
                            tooltip: 'Roll options',
                            icon: const Icon(
                              Icons.more_vert_rounded,
                              color: Colors.white54,
                              size: 20,
                            ),
                            onSelected: (value) {
                              if (value == 'move') onMove!();
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'move',
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.drive_file_move_outline),
                                  title: Text('Move to film…'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 64,
                              height: 64,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  AlbumFilmIcon(
                                    asset: film.iconAsset,
                                    name: film.name,
                                  ),
                                  if (format != null)
                                    Positioned(
                                      right: 0,
                                      bottom: 0,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 2,
                                        ),
                                        decoration: const BoxDecoration(
                                          color: Color(0xE60A0A0A),
                                          borderRadius: BorderRadius.only(
                                            topLeft: Radius.circular(6),
                                            bottomRight: Radius.circular(10),
                                          ),
                                        ),
                                        child: Text(
                                          format,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 11,
                                            height: 1.1,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    film.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    detail,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (camera != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      camera,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                  if (previews.isNotEmpty) ...[
                                    const SizedBox(height: 10),
                                    SizedBox(
                                      height: 56,
                                      child: ListView.separated(
                                        scrollDirection: Axis.horizontal,
                                        itemCount: previews.length,
                                        separatorBuilder: (_, _) =>
                                            const SizedBox(width: 6),
                                        itemBuilder: (context, index) {
                                          return ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            child: Image(
                                              image: albumThumbnailProvider(
                                                previews[index].file,
                                                library: library,
                                              ),
                                              width: 56 * aspect,
                                              height: 56,
                                              fit: BoxFit.cover,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _detail(AlbumFilm film, AlbumFolderMeta? meta) {
  final kind = albumFilmKindForFolder(film.name);
  final brand = kind?.brand.label ??
      switch (albumFilmBrandName(film.name)) {
        'kodak' => 'Kodak',
        'fujifilm' => 'Fuji',
        'ilford' => 'Ilford',
        'cinestill' => 'CineStill',
        _ => 'Other',
      };
  final iso = meta?.iso ?? kind?.iso;
  return [
    if (kind != null) kind.category.label,
    brand,
    if (iso != null) 'ISO $iso',
  ].join('  ·  ');
}

String? _formatBadge(AlbumFilmRoll? roll, AlbumFolderMeta? meta) {
  return switch (meta?.frameFormat) {
    '6x6' => '6×6',
    '645' => '645',
    'instax-mini' => 'Mini',
    'instax-sq' => 'SQ',
    _ =>
      roll?.format == '135' || roll?.format == '120'
          ? roll!.format
          : meta?.format == '135' || meta?.format == '120'
          ? meta!.format
          : null,
  };
}

double _thumbAspect(AlbumFilmRoll? roll, AlbumFolderMeta? meta) {
  return switch (meta?.frameFormat) {
    '6x6' || 'instax-sq' => 1,
    '645' => 56 / 41.5,
    'instax-mini' => 62 / 46,
    _ => roll?.format == '120' || meta?.format == '120' ? 1 : 3 / 2,
  };
}

Color _brandColor(String name) {
  return switch (albumFilmBrandName(name)) {
    'kodak' => _accent,
    'fujifilm' => const Color(0xFF2E7D32),
    'ilford' => const Color(0xFFB0BEC5),
    'cinestill' => const Color(0xFFE53935),
    _ => const Color(0xFF6B6B6B),
  };
}
