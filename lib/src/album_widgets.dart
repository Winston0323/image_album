import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'album_images.dart';
import 'album_library.dart';
import 'album_photo.dart';
import 'album_view.dart';

const List<String> _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const List<String> _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Heading and secondary line for a day's section.
///
/// Recent days read naturally ("Today", "Yesterday", then the weekday for the
/// rest of the week) and older ones show their date, with the year only when
/// it is not this year. The secondary line carries whichever of date and
/// weekday the heading leaves out.
({String title, String subtitle}) albumDayLabels(
  DateTime day, {
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  // Compared as UTC dates so a daylight-saving change cannot make a day 23
  // or 25 hours long.
  final age = DateTime.utc(
    current.year,
    current.month,
    current.day,
  ).difference(DateTime.utc(day.year, day.month, day.day)).inDays;

  final weekday = _weekdayNames[day.weekday - 1];
  final date =
      '${_monthNames[day.month - 1]} ${day.day}'
      '${day.year == current.year ? '' : ', ${day.year}'}';

  final shortWeekday = weekday.substring(0, 3);
  return switch (age) {
    0 => (title: 'Today', subtitle: '$shortWeekday, $date'),
    1 => (title: 'Yesterday', subtitle: '$shortWeekday, $date'),
    > 1 && < 7 => (title: weekday, subtitle: date),
    _ => (title: date, subtitle: weekday),
  };
}

/// "Jul 30, 2026", the date half of a film waterfall divider.
String albumFullDate(DateTime day) =>
    '${_monthNames[day.month - 1]} ${day.day}, ${day.year}';

/// "Jul 30, 2026 · 12:05", for the line under a photo in the viewer.
String albumShortDateTime(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${albumFullDate(at)} · ${two(at.hour)}:${two(at.minute)}';
}

/// "1,234" style grouping for counts of a thousand or more.
String albumFormatCount(int count) {
  final digits = count.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// Day heading that stays at the top of the screen while its photos scroll
/// beneath it, and hands over to the next day's heading when that arrives.
class AlbumDayHeaderDelegate extends SliverPersistentHeaderDelegate {
  const AlbumDayHeaderDelegate(
    this.section, {
    this.height = baseHeight,
    this.selected,
    this.onSelect,
    this.title,
    this.subtitle,
    this.onSubtitle,
  });

  final AlbumDaySection section;

  /// Whether this day's photos are picked: all of them, none, or some.
  /// Shown only when [onSelect] is set.
  final bool? selected;

  /// Picks or clears every photo from this day.
  final VoidCallback? onSelect;

  /// Replaces the day name. A film roll uses the date, such as "Jul 30, 2026".
  final String? title;

  /// Replaces the day subtitle. A film roll uses the time, after the date.
  final String? subtitle;

  /// What a tap on [subtitle] does. Set for a film roll, whose format can be
  /// changed. The day's own tap is left alone.
  final VoidCallback? onSubtitle;

  /// Height of the heading at the default text size.
  static const double baseHeight = 48;

  /// Height of the heading, which must be fixed for the sliver, grown to keep
  /// room for the title when text is larger than the default, whether the
  /// theme's type scale or the system's text size setting made it so.
  static double heightFor(BuildContext context) {
    const defaultTitleSize = 16.0; // Material 3 titleMedium
    final size =
        Theme.of(context).textTheme.titleMedium?.fontSize ?? defaultTitleSize;
    final scaled = MediaQuery.textScalerOf(context).scale(size);
    return baseHeight * math.max(1, scaled / defaultTitleSize);
  }

  final double height;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  bool shouldRebuild(AlbumDayHeaderDelegate oldDelegate) =>
      oldDelegate.section != section ||
      oldDelegate.height != height ||
      oldDelegate.selected != selected ||
      oldDelegate.onSelect != onSelect ||
      oldDelegate.title != title ||
      oldDelegate.subtitle != subtitle ||
      oldDelegate.onSubtitle != onSubtitle;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labels = title == null
        ? albumDayLabels(section.day)
        : (title: title!, subtitle: subtitle ?? '');

    // Persistent headers are laid out loosely, so the height is spelled out.
    // Otherwise the header would be as tall as its text, and the sliver's
    // declared extent would disagree with what is painted.
    return SizedBox(
      height: height,
      child: _buildContent(theme, scheme, labels, overlapsContent),
    );
  }

  Widget _subtitle(
    ThemeData theme,
    ColorScheme scheme,
    ({String title, String subtitle}) labels,
  ) {
    final text = Text(
      labels.subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: onSubtitle == null ? scheme.onSurfaceVariant : scheme.primary,
      ),
    );
    final tap = onSubtitle;
    if (tap == null) return text;
    return GestureDetector(onTap: tap, child: text);
  }

  Widget _buildContent(
    ThemeData theme,
    ColorScheme scheme,
    ({String title, String subtitle}) labels,
    bool overlapsContent,
  ) {
    final select = onSelect;
    // Opaque: the next day's heading slides over this one.
    return Material(
      color: scheme.surface,
      child: GestureDetector(
        onTap: select,
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(
                  alpha: overlapsContent ? 0.6 : 0,
                ),
              ),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(select == null ? 16 : 4, 0, 12, 0),
            child: Row(
              children: [
                if (select != null)
                  IgnorePointer(
                    child: Checkbox(
                      value: selected,
                      tristate: true,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (_) {},
                    ),
                  ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          labels.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: _subtitle(theme, scheme, labels)),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            child: Text(
                              albumFormatCount(section.photos.length),
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
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
    );
  }
}

/// One rounded grid tile.
///
/// The photo fades in once decoded (and not at all when it is already in
/// memory, so scrolling back never flickers). Picking a tile shrinks it a
/// little and tints it, and a check badge at the corner both shows the
/// selection and, on desktop, appears on hover so a tile can be picked with a
/// single click without opening it.
class AlbumPhotoTile extends StatefulWidget {
  const AlbumPhotoTile({
    super.key,
    required this.photo,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onToggle,
    this.onLongPress,
    this.selectable = true,
    this.adjustment = const AlbumViewAdjustment(),
    this.library,
  });

  /// Where the thumbnail is kept. See [albumThumbnailProvider].
  final AlbumLibrary? library;

  final AlbumPhoto photo;

  /// Whether the album is in selection mode — every tile then shows its
  /// check marker, not just the selected ones, so the mode is visible.
  final bool selecting;

  /// Whether this tile can be picked. When false the check never appears.
  final bool selectable;

  /// How the picture is turned and cropped for display. The file is unchanged.
  final AlbumViewAdjustment adjustment;

  final bool selected;

  /// Opens or otherwise handles a tap. [origin] is this tile's global bounds,
  /// used to zoom the preview out of the tile.
  final void Function(Rect? origin) onTap;

  /// Picks or unpicks this tile. Called by the badge, and by a long-press
  /// unless [onLongPress] says otherwise.
  final VoidCallback onToggle;

  /// Called by a long-press. Defaults to [onToggle].
  final VoidCallback? onLongPress;

  @override
  State<AlbumPhotoTile> createState() => _AlbumPhotoTileState();
}

class _AlbumPhotoTileState extends State<AlbumPhotoTile> {
  static const Duration _quick = Duration(milliseconds: 150);

  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.selected;
    final showBadge = widget.selectable && (widget.selecting || _hovered);

    return Semantics(
      label: widget.photo.fileName,
      image: true,
      button: true,
      selected: selected,
      // Lets a drag across the grid work out which photo is under the pointer.
      child: MetaData(
        metaData: widget.photo,
        behavior: HitTestBehavior.translucent,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: () {
              final box = context.findRenderObject() as RenderBox?;
              final origin = box != null && box.hasSize && box.attached
                  ? box.localToGlobal(Offset.zero) & box.size
                  : null;
              widget.onTap(origin);
            },
            onLongPress: widget.onLongPress ?? widget.onToggle,
            child: AnimatedScale(
              scale: selected ? 0.86 : 1,
              duration: _quick,
              curve: Curves.easeOutCubic,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(selected ? 12 : 8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: AlbumAdjustedView(
                        adjustment: widget.adjustment,
                        child: Image(
                          // Decoded at roughly tile resolution rather than
                          // full size. The preview reuses this decode as its
                          // placeholder.
                          image: albumThumbnailProvider(
                            widget.photo.file,
                            library: widget.library,
                          ),
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          frameBuilder: (context, child, frame, sync) {
                            if (sync) return child;
                            return AnimatedOpacity(
                              opacity: frame == null ? 0 : 1,
                              duration: const Duration(milliseconds: 240),
                              curve: Curves.easeOut,
                              child: child,
                            );
                          },
                          errorBuilder: (_, _, _) => Center(
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Darkens the top edge so the badge reads on pale photos.
                    if (showBadge)
                      const Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: 44,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0x66000000), Color(0x00000000)],
                              ),
                            ),
                          ),
                        ),
                      ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedContainer(
                          duration: _quick,
                          color: selected
                              ? scheme.primary.withValues(alpha: 0.22)
                              : _hovered
                              ? Colors.white.withValues(alpha: 0.08)
                              : Colors.transparent,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 6,
                      top: 6,
                      child: AnimatedOpacity(
                        opacity: showBadge ? 1 : 0,
                        duration: _quick,
                        child: IgnorePointer(
                          ignoring: !showBadge,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.onToggle,
                            child: _CheckBadge(selected: selected),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckBadge extends StatelessWidget {
  const _CheckBadge({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? scheme.primary : Colors.black.withValues(alpha: 0.28),
        border: Border.all(
          color: selected ? scheme.onPrimary : Colors.white,
          width: 1.6,
        ),
        boxShadow: const [BoxShadow(blurRadius: 4, color: Color(0x40000000))],
      ),
      child: selected
          ? Icon(Icons.check_rounded, size: 15, color: scheme.onPrimary)
          : null,
    );
  }
}

/// Centered illustration, heading and note, used for the empty and error
/// states.
class AlbumStateView extends StatelessWidget {
  const AlbumStateView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.color,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;

  /// Tint of the icon and its halo. Defaults to the theme's primary color.
  final Color? color;

  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tint.withValues(alpha: 0.12),
              ),
              child: Icon(icon, size: 44, color: tint),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}

/// Turns and crops [child] the way [adjustment] says, without touching the file.
///
/// [aspect] is the child's width divided by its height. A square thumbnail is 1.
class AlbumAdjustedView extends StatelessWidget {
  const AlbumAdjustedView({
    super.key,
    required this.adjustment,
    required this.child,
    this.aspect = 1,
  });

  final AlbumViewAdjustment adjustment;
  final Widget child;
  final double aspect;

  @override
  Widget build(BuildContext context) {
    if (adjustment.isOriginal) return child;
    final scale = albumCoverScale(
      degrees: adjustment.degrees,
      imageAspect: aspect > 0 ? aspect : 1,
    );
    return ClipRect(
      child: FractionalTranslation(
        translation: Offset(adjustment.panX, adjustment.panY),
        child: Transform.scale(
          scale: scale,
          child: Transform.rotate(
            angle: adjustment.degrees * math.pi / 180,
            child: child,
          ),
        ),
      ),
    );
  }
}
