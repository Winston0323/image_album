import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerScrollEvent, kBackMouseButton, kForwardMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'album_adjust_page.dart';
import 'album_images.dart';
import 'album_libraw.dart';
import 'album_view.dart';
import 'album_library.dart';
import 'album_photo.dart';
import 'album_widgets.dart';
import 'photo_info_panel.dart';

/// Scale a double-tap zooms to.
const double _doubleTapScale = 2.5;

/// Image cache budget while a preview is open. Full-resolution photos are
/// large; keep room for the current shot and a neighbor on each side.
const int _previewCacheBytes = 512 << 20;

/// Window width from which on-screen previous/next buttons are shown. Narrower
/// screens are assumed to be touch devices that swipe.
const double _sideButtonsMinWidth = 700;

/// Width of the info sidebar.
const double _infoWidth = 340;

/// Window width from which the info sidebar sits beside the photo, which then
/// shrinks to make room. On narrower screens it slides over the photo instead.
const double _infoDockMinWidth = 900;

/// Full-screen viewer for photos already on disk. Swiping moves through
/// [photos] in the same order the grid shows them.
///
/// Tap the photo to hide or show the bars, double-tap to zoom, pinch or scroll
/// to zoom further. On desktop the arrow keys, on-screen side buttons, and the
/// mouse previous/next (back/forward) buttons move between photos (so do Page
/// Up and Page Down); Escape closes the viewer. Moving the pointer near the
/// bottom edge reveals a filmstrip over the photo (it never shrinks the
/// photo); leaving that edge hides it again.
///
/// The info button opens a sidebar on the right with the current photo's
/// details. On a wide window it sits beside the photo, which shrinks to make
/// room; on a narrow one it slides over the photo. It follows the photo as you
/// swipe.
///
/// When [onDelete] is set, a delete button (and the Delete or D key) removes
/// the photo on screen after [onDelete] returns true. Press D once for the
/// warning, then D again to confirm.
///
/// A "show in file explorer" button opens the current file in the system file
/// manager (Explorer / Finder / the parent folder on Linux), or calls
/// [onReveal] when that is set.
class AlbumPreviewPage extends StatefulWidget {
  const AlbumPreviewPage({
    super.key,
    required this.photos,
    required this.initialIndex,
    this.library,
    this.onClose,
    this.onPhotoChanged,
    this.onDelete,
    this.onReveal,
    this.crop = true,
    this.info = true,
    this.filmstrip = true,
    this.reveal = true,
    this.corner,
    this.veil = true,
  });

  final List<AlbumPhoto> photos;
  final int initialIndex;

  /// Called with the photo now showing each time the viewer moves to another.
  final ValueChanged<AlbumPhoto>? onPhotoChanged;

  /// Called when the user closes the viewer (back button or Escape). Without
  /// it the viewer is taken to be a route of its own and pops itself.
  final VoidCallback? onClose;

  /// Asks to delete [photo] from disk. Return true when it was removed, so
  /// the viewer can leave it. The album uses this to confirm and delete.
  final Future<bool> Function(AlbumPhoto photo)? onDelete;

  /// Opens [photo] in the file manager. When null, the viewer uses the
  /// platform default on desktop (selects the file in Explorer/Finder).
  final Future<void> Function(AlbumPhoto photo)? onReveal;

  /// Offers turning and cropping the photo. The file is not rewritten.
  final bool crop;

  /// Offers the photo info panel.
  final bool info;

  /// Offers the row of nearby photos.
  final bool filmstrip;

  /// Offers showing the photo in the file manager.
  final bool reveal;

  /// The album file the grid's thumbnails are kept in, so the preview finds
  /// the same ones already decoded.
  final AlbumLibrary? library;

  /// Drawn at the top right of the photo, over it. The import page uses it to
  /// show the files of the shot (its JPEG and its raw) and to switch which
  /// one is on screen.
  final Widget Function(AlbumPhoto photo)? corner;

  /// When true, paints an opaque black scaffold. Open/close transitions that
  /// already fade a black barrier set this false so the veil is not doubled.
  final bool veil;

  @override
  State<AlbumPreviewPage> createState() => _AlbumPreviewPageState();
}

class _AlbumPreviewPageState extends State<AlbumPreviewPage>
    with SingleTickerProviderStateMixin {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  final List<AlbumPhoto> _photos = [];
  bool _chromeVisible = true;
  bool _infoVisible = false;
  var _deleting = false;

  /// Pointer is in the bottom hot zone (or on the open strip).
  bool _filmHover = false;

  /// Hover change waiting for the next frame. Applying it inside the mouse
  /// callback rebuilds the strip's mouse regions while the tracker is updating.
  bool? _filmHoverQueued;

  /// 0 with the info sidebar closed, 1 fully open.
  late final AnimationController _infoSlide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _infoCurve = CurvedAnimation(
    parent: _infoSlide,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  /// True while the current photo is zoomed in. Swiping is switched off then,
  /// so dragging to pan the photo cannot also flip to the next one.
  final ValueNotifier<bool> _zoomed = ValueNotifier(false);

  late final ImageCache _imageCache = PaintingBinding.instance.imageCache;
  late final int _previousCacheBytes = _imageCache.maximumSizeBytes;

  var _primedNeighbors = false;

  /// Crop and rotation, keyed by file path. Kept outside the photo.
  final Map<String, AlbumViewAdjustment> _viewAdjustments = {};

  /// Takes the keyboard when the viewer opens. `autofocus` alone would lose to
  /// the album underneath when the viewer is shown over it rather than as a
  /// route of its own.
  final FocusNode _focus = FocusNode(debugLabel: 'AlbumPreview');

  @override
  void initState() {
    super.initState();
    _photos.addAll(widget.photos);
    if (_previousCacheBytes < _previewCacheBytes) {
      _imageCache.maximumSizeBytes = _previewCacheBytes;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _rememberView(_photos[_index]);
    });
  }

  AlbumViewAdjustment _adjustmentOf(AlbumPhoto photo) =>
      _viewAdjustments[photo.file.path] ?? const AlbumViewAdjustment();

  Future<void> _rememberView(AlbumPhoto photo) async {
    final adjustment = await albumViewAdjustment(photo.file);
    if (!mounted) return;
    if (_viewAdjustments[photo.file.path] == adjustment) return;
    setState(() => _viewAdjustments[photo.file.path] = adjustment);
  }

  Future<void> _adjust() async {
    final photo = _photos[_index];
    final next = await Navigator.of(context).push<AlbumViewAdjustment>(
      MaterialPageRoute<AlbumViewAdjustment>(
        builder: (context) =>
            AlbumAdjustPage(file: photo.file, initial: _adjustmentOf(photo)),
      ),
    );
    if (next == null || !mounted) return;
    try {
      await albumSetViewAdjustment(photo.file, next);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not remember the adjustment')),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _viewAdjustments[photo.file.path] = next);
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _imageCache.maximumSizeBytes = _previousCacheBytes;
    _infoSlide.dispose();
    _zoomed.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_primedNeighbors) return;
    _primedNeighbors = true;
    _precacheNeighborsAfterFrame(_index);
  }

  /// Starts decoding the shots on either side at full resolution, so by the
  /// time a swipe lands the neighbor is already sitting decoded in the cache.
  ///
  /// Run after the frame, so the photo on screen gets the decoder first.
  void _precacheNeighborsAfterFrame(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final neighbor in [index + 1, index - 1]) {
        if (neighbor < 0 || neighbor >= _photos.length) continue;
        if (albumFullDecodeIsHeavy(_photos[neighbor].file)) continue;
        precacheImage(
          albumFullProvider(_photos[neighbor].file),
          context,
          // A corrupt neighbor should surface when it is actually shown (the
          // error builder below), not as a stray exception during a swipe.
          onError: (_, _) {},
        );
      }
    });
  }

  void _go(int delta) {
    if (_zoomed.value) return;
    final target = _index + delta;
    if (target < 0 || target >= _photos.length) return;
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  /// Deletes the photo on screen once [onDelete] says it is gone. Moves to the
  /// next one, or closes when none are left.
  Future<void> _deleteCurrent() async {
    final onDelete = widget.onDelete;
    if (onDelete == null || _deleting || _photos.isEmpty) return;
    setState(() => _deleting = true);
    final photo = _photos[_index];
    final removed = await onDelete(photo);
    if (!mounted) return;
    if (!removed) {
      setState(() => _deleting = false);
      return;
    }
    _photos.removeAt(_index);
    // Closing with an empty list must not rebuild the viewer first.
    if (_photos.isEmpty) {
      _close();
      return;
    }
    setState(() {
      _deleting = false;
      if (_index >= _photos.length) _index = _photos.length - 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.jumpToPage(_index);
      widget.onPhotoChanged?.call(_photos[_index]);
      _precacheNeighborsAfterFrame(_index);
    });
  }

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  void _toggleInfo() {
    setState(() => _infoVisible = !_infoVisible);
    if (_infoVisible) {
      _infoSlide.forward();
    } else {
      _infoSlide.reverse();
    }
  }

  bool get _canReveal =>
      widget.reveal &&
      (widget.onReveal != null ||
          Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux);

  String get _revealTooltip {
    if (Platform.isMacOS) return 'Show in Finder';
    if (Platform.isWindows) return 'Show in Explorer';
    return 'Show in file manager';
  }

  /// Opens the photo on screen in the system file manager and selects it.
  Future<void> _revealCurrent() async {
    if (_photos.isEmpty) return;
    final photo = _photos[_index];
    try {
      final reveal = widget.onReveal;
      if (reveal != null) {
        await reveal(photo);
        return;
      }
      await albumRevealInFileManager(photo.file);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not open the file location: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = _photos[_index];
    final info = PhotoInfoPanel(photo: photo, onClose: _toggleInfo);

    return Scaffold(
      backgroundColor: widget.veil ? Colors.black : Colors.transparent,
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          // Mouse X1 / X2 with album direction: forward = previous, back = next.
          final buttons = event.buttons;
          if (buttons & kForwardMouseButton != 0) {
            _go(-1);
          } else if (buttons & kBackMouseButton != 0) {
            _go(1);
          }
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
            const SingleActivator(LogicalKeyboardKey.pageUp): () => _go(-1),
            const SingleActivator(LogicalKeyboardKey.pageDown): () => _go(1),
            const SingleActivator(LogicalKeyboardKey.escape): _close,
            if (widget.onDelete != null) ...{
              const SingleActivator(LogicalKeyboardKey.delete): () {
                _deleteCurrent();
              },
              const SingleActivator(LogicalKeyboardKey.backspace): () {
                _deleteCurrent();
              },
              // First D opens the warning; the dialog accepts D again to delete.
              const SingleActivator(LogicalKeyboardKey.keyD): () {
                _deleteCurrent();
              },
            },
          },
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            // Sized by the room the viewer is given, not the window: beside the
            // album's folder panel it has less than the whole width.
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return _layout(photo, info, width);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _layout(AlbumPhoto photo, Widget info, double width) {
    final wide = width >= _sideButtonsMinWidth;
    final docked = width >= _infoDockMinWidth;
    return Stack(
      children: [
        Row(
          children: [
            Expanded(child: _viewer(photo, wide)),
            // The photo gives up room as the sidebar opens, and takes it
            // back as it closes. The sidebar keeps its full width and is
            // revealed from the right edge, so its text never reflows.
            if (docked)
              AnimatedBuilder(
                animation: _infoCurve,
                builder: (context, _) => _infoSlide.isDismissed
                    ? const SizedBox.shrink()
                    : ClipRect(
                        child: Align(
                          alignment: Alignment.centerRight,
                          widthFactor: _infoCurve.value,
                          child: SizedBox(width: _infoWidth, child: info),
                        ),
                      ),
              ),
          ],
        ),
        if (!docked)
          AnimatedBuilder(
            animation: _infoCurve,
            builder: (context, _) => _infoSlide.isDismissed
                ? const SizedBox.shrink()
                : Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: math.min(_infoWidth, width * 0.85),
                    child: FractionalTranslation(
                      translation: Offset(1 - _infoCurve.value, 0),
                      child: Material(elevation: 8, child: info),
                    ),
                  ),
          ),
      ],
    );
  }

  /// Moves to the photo at [index], as the filmstrip asks. A short hop
  /// slides; a long one jumps, so the pager does not decode every photo it
  /// would pass.
  void _goTo(int index) {
    if (index == _index || index < 0 || index >= _photos.length) return;
    // Leaving a zoomed photo: the next one starts at its own size, and
    // swiping is allowed again.
    _zoomed.value = false;
    if ((index - _index).abs() > 3) {
      _controller.jumpToPage(index);
    } else {
      _controller.animateToPage(
        index,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// Shows or hides the filmstrip on the next frame, not inside the mouse event.
  void _queueFilmHover(bool near) {
    if (near == (_filmHoverQueued ?? _filmHover)) return;
    final schedule = _filmHoverQueued == null;
    _filmHoverQueued = near;
    if (!schedule) return;
    // The callback alone does not draw a frame, so a move with nothing else
    // animating would leave the strip stuck.
    WidgetsBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final wanted = _filmHoverQueued;
      _filmHoverQueued = null;
      if (!mounted || wanted == null || wanted == _filmHover) return;
      setState(() => _filmHover = wanted);
    });
  }

  /// The photo, edge to edge. The filmstrip overlays the bottom when the
  /// pointer is near that edge so the photo never resizes.
  Widget _viewer(AlbumPhoto photo, bool wide) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final showStrip = widget.filmstrip && _photos.length > 1;
        if (!showStrip) return _photoArea(photo, wide);
        final stripH = _filmStripHeight(constraints.maxWidth);
        // Wider while the strip is open so moving onto it does not dismiss it.
        final hotZone = _filmHover
            ? stripH + 28
            : math.max(56.0, stripH * 0.55);
        return MouseRegion(
          onHover: (event) {
            _queueFilmHover(event.localPosition.dy >= height - hotZone);
          },
          onExit: (_) => _queueFilmHover(false),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _photoArea(photo, wide),
              if (showStrip)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    ignoring: !_filmHover,
                    child: AnimatedSlide(
                      offset: Offset(0, _filmHover ? 0 : 1),
                      duration: const Duration(milliseconds: 200),
                      curve: _filmHover
                          ? Curves.easeOutCubic
                          : Curves.easeInCubic,
                      child: AnimatedOpacity(
                        opacity: _filmHover ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: _Filmstrip(
                          photos: _photos,
                          index: _index,
                          library: widget.library,
                          adjustmentOf: _adjustmentOf,
                          onSelect: _goTo,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// The photo pager with its bars and buttons.
  Widget _photoArea(AlbumPhoto photo, bool wide) {
    return Stack(
      children: [
        Positioned.fill(
          child: ValueListenableBuilder<bool>(
            valueListenable: _zoomed,
            builder: (context, zoomed, _) => PageView.builder(
              controller: _controller,
              physics: zoomed ? const NeverScrollableScrollPhysics() : null,
              itemCount: _photos.length,
              onPageChanged: (index) {
                setState(() => _index = index);
                widget.onPhotoChanged?.call(_photos[index]);
                _rememberView(_photos[index]);
                _precacheNeighborsAfterFrame(index);
              },
              itemBuilder: (context, index) {
                final file = _photos[index].file;
                return _PreviewPhoto(
                  key: ValueKey(file.path),
                  file: file,
                  adjustment:
                      _viewAdjustments[file.path] ??
                      const AlbumViewAdjustment(),
                  zoomed: _zoomed,
                  onTap: _toggleChrome,
                );
              },
            ),
          ),
        ),
        if (widget.corner != null)
          Positioned(top: 72, right: 16, child: widget.corner!(photo)),
        if (wide) ...[
          _SideButton(
            alignment: Alignment.centerLeft,
            icon: Icons.chevron_left_rounded,
            tooltip: 'Previous photo',
            visible: _chromeVisible && _index > 0,
            onPressed: () => _go(-1),
          ),
          _SideButton(
            alignment: Alignment.centerRight,
            icon: Icons.chevron_right_rounded,
            tooltip: 'Next photo',
            visible: _chromeVisible && _index < _photos.length - 1,
            onPressed: () => _go(1),
          ),
        ],
        _Bar(
          visible: _chromeVisible,
          top: true,
          child: Row(
            children: [
              BackButton(color: Colors.white, onPressed: _close),
              Expanded(
                child: Text(
                  '${_index + 1} / ${_photos.length}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (widget.onDelete != null)
                IconButton(
                  tooltip: 'Delete (D)',
                  color: Colors.white,
                  onPressed: _deleting ? null : _deleteCurrent,
                  icon: _deleting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.delete_outline_rounded),
                ),
              if (_canReveal)
                IconButton(
                  tooltip: _revealTooltip,
                  color: Colors.white,
                  onPressed: _revealCurrent,
                  icon: const Icon(Icons.folder_open_rounded),
                ),
              if (widget.crop)
                IconButton(
                  tooltip: 'Crop',
                  color: Colors.white,
                  onPressed: _adjust,
                  icon: const Icon(Icons.crop_rotate_rounded),
                ),
              if (widget.info)
                IconButton(
                  tooltip: 'Photo info',
                  color: Colors.white,
                  onPressed: _toggleInfo,
                  style: IconButton.styleFrom(
                    backgroundColor: _infoVisible
                        ? Colors.white.withValues(alpha: 0.18)
                        : Colors.transparent,
                  ),
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: animation, child: child),
                    ),
                    child: Icon(
                      _infoVisible
                          ? Icons.view_sidebar_rounded
                          : Icons.view_sidebar_outlined,
                      key: ValueKey(_infoVisible),
                    ),
                  ),
                ),
              const SizedBox(width: 4),
            ],
          ),
        ),
        _Bar(
          visible: _chromeVisible,
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  photo.fileName,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  albumShortDateTime(photo.takenAt),
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// How many filmstrip thumbnails fit across the strip at once.
const int _filmVisibleCount = 8;

/// Space between thumbnails, and above and below the strip.
const double _filmGap = 10;

/// Width of the highlight around the current thumbnail. Every thumbnail has a
/// border this wide, clear when it is not the current one, so none moves when
/// the highlight does.
const double _filmBorder = 3;

/// Horizontal inset of the filmstrip list.
const double _filmEdge = 16;

/// Slot width so [_filmVisibleCount] thumbs fill [width].
double _filmItemExtent(double width) =>
    math.max(72, (width - _filmEdge * 2) / _filmVisibleCount);

/// Image side inside one slot (square).
double _filmThumbSize(double width) =>
    _filmItemExtent(width) - _filmBorder * 2 - _filmGap;

/// Height of the filmstrip for [width].
double _filmStripHeight(double width) =>
    _filmThumbSize(width) + _filmGap * 2 + _filmBorder * 2;

/// A row of small copies of the photos before and after the current one, with
/// a highlighted border on the current one. It scrolls to keep that one in the
/// middle, and a tap on another moves to it. About [_filmVisibleCount] thumbs
/// fit across; the row scales with the viewer width.
class _Filmstrip extends StatefulWidget {
  const _Filmstrip({
    required this.photos,
    required this.index,
    required this.library,
    required this.adjustmentOf,
    required this.onSelect,
  });

  final List<AlbumPhoto> photos;
  final int index;
  final AlbumLibrary? library;
  final AlbumViewAdjustment Function(AlbumPhoto photo) adjustmentOf;
  final ValueChanged<int> onSelect;

  @override
  State<_Filmstrip> createState() => _FilmstripState();
}

class _FilmstripState extends State<_Filmstrip> {
  final ScrollController _scroll = ScrollController();
  double _extent = 72;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _center(animate: false),
    );
  }

  @override
  void didUpdateWidget(_Filmstrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) _center(animate: true);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls so the current thumbnail is in the middle, or as near as the ends
  /// of the strip allow.
  void _center({required bool animate}) {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    final target =
        (_filmEdge +
                widget.index * _extent +
                _extent / 2 -
                position.viewportDimension / 2)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final extent = _filmItemExtent(constraints.maxWidth);
        final thumb = _filmThumbSize(constraints.maxWidth);
        final height = _filmStripHeight(constraints.maxWidth);
        if (extent != _extent) {
          _extent = extent;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _center(animate: false),
          );
        }
        return Container(
          height: height,
          // Slight shade so the strip reads as a menu over the photo, not a
          // second layout band that reflows the page.
          color: const Color(0xE6000000),
          // A mouse wheel scrolls the strip sideways, which it would not do on
          // its own.
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent && _scroll.hasClients) {
                final position = _scroll.position;
                _scroll.jumpTo(
                  (_scroll.offset + event.scrollDelta.dy).clamp(
                    position.minScrollExtent,
                    position.maxScrollExtent,
                  ),
                );
              }
            },
            child: ListView.builder(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: _filmEdge),
              itemExtent: extent,
              itemCount: widget.photos.length,
              itemBuilder: (context, i) {
                final current = i == widget.index;
                final photo = widget.photos[i];
                return Padding(
                  padding: const EdgeInsets.only(right: _filmGap),
                  child: Semantics(
                    button: true,
                    selected: current,
                    label: photo.fileName,
                    child: GestureDetector(
                      onTap: () => widget.onSelect(i),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          width: thumb + _filmBorder * 2,
                          margin: const EdgeInsets.symmetric(
                            vertical: _filmGap,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: current ? accent : Colors.transparent,
                              width: _filmBorder,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(7),
                            child: AnimatedOpacity(
                              opacity: current ? 1 : 0.6,
                              duration: const Duration(milliseconds: 160),
                              child: AlbumAdjustedView(
                                adjustment: widget.adjustmentOf(photo),
                                child: Image(
                                  image: albumThumbnailProvider(
                                    photo.file,
                                    library: widget.library,
                                  ),
                                  fit: BoxFit.cover,
                                  width: thumb,
                                  height: thumb,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, _, _) => ColoredBox(
                                    color: Colors.white12,
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      color: Colors.white38,
                                      size: thumb * 0.35,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Top or bottom bar laid over the photo on a fading shade, so the photo can
/// run edge to edge and the bar text stays readable on any picture.
class _Bar extends StatelessWidget {
  const _Bar({required this.visible, required this.top, required this.child});

  final bool visible;
  final bool top;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const shade = Color(0xB3000000);
    return Positioned(
      left: 0,
      right: 0,
      top: top ? 0 : null,
      bottom: top ? null : 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: top ? Alignment.topCenter : Alignment.bottomCenter,
                end: top ? Alignment.bottomCenter : Alignment.topCenter,
                colors: const [shade, Color(0x00000000)],
              ),
            ),
            child: SafeArea(top: top, bottom: !top, child: child),
          ),
        ),
      ),
    );
  }
}

class _SideButton extends StatelessWidget {
  const _SideButton({
    required this.alignment,
    required this.icon,
    required this.tooltip,
    required this.visible,
    required this.onPressed,
  });

  final Alignment alignment;
  final IconData icon;
  final String tooltip;
  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IconButton(
                tooltip: tooltip,
                iconSize: 32,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.16),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(10),
                ),
                onPressed: onPressed,
                icon: Icon(icon),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One pannable, zoomable photo, decoded at the file's own pixel size.
///
/// The photo is laid out at one logical pixel per device pixel of the file,
/// then scaled down to fit the window. Zooming back toward 1:1 shows those
/// original pixels. A screen-sized decode would be rasterized into the window
/// and could never get sharper when zoomed.
class _PreviewPhoto extends StatefulWidget {
  const _PreviewPhoto({
    super.key,
    required this.file,
    this.adjustment = const AlbumViewAdjustment(),
    required this.zoomed,
    required this.onTap,
  });

  final File file;

  /// Crop and rotation used only while drawing. The file is not involved.
  final AlbumViewAdjustment adjustment;

  /// Set to whether this photo is currently zoomed in.
  final ValueNotifier<bool> zoomed;

  final VoidCallback onTap;

  @override
  State<_PreviewPhoto> createState() => _PreviewPhotoState();
}

class _PreviewPhotoState extends State<_PreviewPhoto>
    with SingleTickerProviderStateMixin {
  /// Transform once the photo is laid out at its real pixel size.
  final TransformationController _transform = TransformationController();

  /// Transform while that size is still unknown. Starts at 1, which fills the
  /// window, so the viewer is usable before the decode reports its dimensions.
  final TransformationController _fallback = TransformationController();

  late final AnimationController _zoomAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _zoomTween;
  TransformationController? _animating;
  late final ImageStreamListener _imageListener = ImageStreamListener(
    _onImage,
    onError: (_, _) {
      _failed = true;
      _publish();
    },
  );

  ImageStream? _stream;
  ImageProvider? _provider;
  Size? _pixels;
  Size? _viewport;
  Matrix4 _fitMatrix = Matrix4.identity();
  double _fitScale = 1;
  Offset _doubleTapAt = Offset.zero;
  var _didFit = false;
  var _userMoved = false;
  var _fitScheduled = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
    _fallback.addListener(_onTransform);
    _zoomAnimation.addListener(() {
      final tween = _zoomTween;
      final target = _animating;
      if (tween != null && target != null) target.value = tween.value;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = albumFullProvider(widget.file);
    if (provider == _provider) return;
    _stream?.removeListener(_imageListener);
    _provider = provider;
    _pixels = null;
    _didFit = false;
    _failed = false;
    _stream = provider.resolve(createLocalImageConfiguration(context));
    _stream!.addListener(_imageListener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_imageListener);
    _zoomAnimation.dispose();
    _transform.removeListener(_onTransform);
    _fallback.removeListener(_onTransform);
    _transform.dispose();
    _fallback.dispose();
    super.dispose();
  }

  void _onImage(ImageInfo info, bool _) {
    final next = Size(
      info.image.width.toDouble(),
      info.image.height.toDouble(),
    );
    if (next == _pixels && _didFit) return;
    _pixels = next;
    _failed = false;
    if (!_userMoved && _viewport != null) _fitToViewport();
    _publish();
  }

  void _publish() {
    if (!mounted) return;
    final phase = WidgetsBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(_PreviewPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.adjustment != widget.adjustment) {
      _userMoved = false;
    }
  }

  /// Lays the photo out so one file pixel is one physical pixel, then scales
  /// that down until it fits [viewport].
  void _fitToViewport() {
    final pixels = _pixels;
    final viewport = _viewport;
    if (pixels == null || viewport == null) return;
    if (viewport.width <= 0 || viewport.height <= 0) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final childW = pixels.width / dpr;
    final childH = pixels.height / dpr;
    if (childW <= 0 || childH <= 0) return;
    final fit = math.min(viewport.width / childW, viewport.height / childH);
    if (!fit.isFinite || fit <= 0) return;
    _fitScale = fit;
    final dx = (viewport.width - childW * fit) / 2;
    final dy = (viewport.height - childH * fit) / 2;
    _fitMatrix = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(fit, fit, fit, 1);
    _transform.value = _fitMatrix.clone();
    _didFit = true;
  }

  void _scheduleFit() {
    if (_fitScheduled || _userMoved || _didFit) return;
    if (_pixels == null || _viewport == null) return;
    _fitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitScheduled = false;
      if (!mounted || _userMoved || _pixels == null || _viewport == null) {
        return;
      }
      _fitToViewport();
      setState(() {});
    });
  }

  TransformationController get _active => _didFit ? _transform : _fallback;

  void _onTransform() {
    final scale = _active.value.getMaxScaleOnAxis();
    final home = _didFit ? _fitScale : 1.0;
    final zoomed = scale > home * 1.05;
    if (widget.zoomed.value != zoomed) widget.zoomed.value = zoomed;
  }

  void _onInteract(ScaleStartDetails _) {
    _userMoved = true;
    _zoomAnimation.stop();
  }

  Widget _photo(BoxFit fit, double? width, double? height) {
    final sharp = albumFullProvider(widget.file);
    // The embedded preview shows at once. The Windows raw decode replaces it
    // when the full sensor image is ready.
    final quick = sharp is AlbumLibRawImage
        ? AlbumConvertedImage(widget.file, embeddedOnly: true)
        : null;
    Widget image(ImageProvider provider, {required bool wait}) {
      return Image(
        image: provider,
        width: width,
        height: height,
        fit: fit,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (!wait || wasSynchronouslyLoaded || frame != null) return child;
          return const SizedBox.shrink();
        },
        errorBuilder: (_, _, _) => const Center(
          child: Icon(
            Icons.broken_image_outlined,
            color: Colors.white54,
            size: 48,
          ),
        ),
      );
    }

    final picture = quick == null
        ? image(sharp, wait: false)
        : Stack(
            // Pass the picture's own size through. Expand would demand the
            // viewer's max constraint, which is infinite in the full-size viewer.
            fit: StackFit.passthrough,
            children: [image(quick, wait: false), image(sharp, wait: true)],
          );
    return picture;
  }

  /// Zooms in on the spot that was tapped, or back out to the fitted view.
  void _toggleZoom() {
    final controller = _active;
    _userMoved = true;
    _zoomAnimation.stop();
    _animating = controller;
    final current = controller.value.getMaxScaleOnAxis();
    final home = _didFit ? _fitScale : 1.0;
    final atHome = (current - home).abs() < home * 0.08;
    final Matrix4 end;
    if (!atHome) {
      end = _didFit ? _fitMatrix.clone() : Matrix4.identity();
    } else {
      final limit = _didFit ? math.max(_fitScale * 8, 1.0) : 8.0;
      final target = math.min(
        math.max(home * _doubleTapScale, _didFit ? 1.0 : _doubleTapScale),
        limit,
      );
      final change = target / current;
      final focal = _doubleTapAt;
      end = Matrix4.identity()
        ..translateByDouble(focal.dx, focal.dy, 0, 1)
        ..scaleByDouble(change, change, change, 1)
        ..translateByDouble(-focal.dx, -focal.dy, 0, 1)
        ..multiply(controller.value);
    }
    _zoomTween = Matrix4Tween(begin: controller.value.clone(), end: end)
        .animate(
          CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOutCubic),
        );
    _zoomAnimation.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        if (viewport != _viewport) {
          _viewport = viewport;
          if (!_userMoved) _didFit = false;
        }
        _scheduleFit();

        final pixels = _pixels;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final childW = pixels == null ? 0.0 : pixels.width / dpr;
        final childH = pixels == null ? 0.0 : pixels.height / dpr;
        final fit = _fitScale <= 0 ? 1.0 : _fitScale;
        final minScale = math.min(fit, 1.0);
        final maxScale = math.max(fit * 8, 1.0);
        // InteractiveViewer will not scale below the size that covers the
        // window. A tall raw is much narrower than that, so zooming out stops
        // while the top and bottom are still off screen. Pad the boundary
        // until the floor is the fitted view, which shows the whole photo.
        final containW = viewport.width / fit;
        final containH = viewport.height / fit;
        final boundaryMargin = EdgeInsets.fromLTRB(
          math.max(0.0, containW - childW) / 2 + 1,
          math.max(0.0, containH - childH) / 2 + 1,
          math.max(0.0, containW - childW) / 2 + 1,
          math.max(0.0, containH - childH) / 2 + 1,
        );

        final native = pixels != null && _didFit && childW > 0 && childH > 0;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
          onDoubleTap: _toggleZoom,
          child: _failed
              ? const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                    size: 48,
                  ),
                )
              : native
              ? InteractiveViewer(
                  transformationController: _transform,
                  alignment: Alignment.topLeft,
                  constrained: false,
                  boundaryMargin: boundaryMargin,
                  minScale: minScale,
                  maxScale: maxScale,
                  onInteractionStart: _onInteract,
                  child: SizedBox(
                    width: childW,
                    height: childH,
                    child: AlbumFramedPhoto(
                      adjustment: widget.adjustment,
                      pixels: pixels,
                      image: _photo(BoxFit.fill, childW, childH),
                    ),
                  ),
                )
              : InteractiveViewer(
                  transformationController: _fallback,
                  minScale: 1,
                  maxScale: 8,
                  onInteractionStart: _onInteract,
                  child: SizedBox.expand(
                    child: AlbumAdjustedView(
                      adjustment: widget.adjustment,
                      aspect: pixels == null || pixels.height == 0
                          ? 1
                          : pixels.width / pixels.height,
                      child: _photo(BoxFit.contain, null, null),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
