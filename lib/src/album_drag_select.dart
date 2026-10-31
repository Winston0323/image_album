import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'album_photo.dart';

/// Pixels the mouse moves with the button down before it counts as a drag
/// rather than a click.
const double _dragSlop = 4;

/// How close to the top or bottom edge a drag has to get before the grid
/// scrolls under it, in logical pixels.
const double _scrollEdge = 64;

/// Fastest the grid scrolls during a drag, in pixels per tick.
const double _scrollMaxSpeed = 22;

/// Longest gap, in pixels, between the places a fast drag is sampled. A
/// mouse can cross several tiles between two events; sampling along the line
/// it travelled means none of them is skipped.
const double _sampleEvery = 12;

/// Lets a pressed pointer sweep over photo tiles and select (or unselect)
/// every one it passes over.
///
/// A mouse starts a sweep by pressing on a tile and moving. A finger starts
/// one with a long-press, which the album hands over through [beginHold];
/// keeping the finger down and moving then keeps selecting. Whichever tile the
/// sweep begins on decides what it does: starting on an unselected tile
/// selects what it crosses, starting on a selected one unselects it.
///
/// Near the top or bottom edge the grid scrolls on its own, so a sweep can
/// reach photos that are off screen.
///
/// Tiles are found by what is under the pointer: every tile is wrapped in a
/// [MetaData] carrying its [AlbumPhoto].
class AlbumDragSelect extends StatefulWidget {
  const AlbumDragSelect({
    super.key,
    required this.controller,
    required this.onStart,
    required this.onPaint,
    required this.child,
  });

  /// The scrollable under [child], scrolled when a sweep nears its edge.
  final ScrollController controller;

  /// A sweep began on [photo]. Applies it and returns whether the sweep
  /// selects (true) or unselects (false) what it crosses.
  final bool Function(AlbumPhoto photo) onStart;

  /// The sweep passed over [photos].
  final void Function(Iterable<AlbumPhoto> photos, bool select) onPaint;

  final Widget child;

  @override
  State<AlbumDragSelect> createState() => AlbumDragSelectState();
}

class AlbumDragSelectState extends State<AlbumDragSelect> {
  int? _mousePointer;
  Offset _mouseDownAt = Offset.zero;
  AlbumPhoto? _mouseDownPhoto;

  int? _touchPointer;
  Offset _touchAt = Offset.zero;

  /// The pointer currently sweeping, if any.
  int? _active;
  bool _select = true;
  Offset _last = Offset.zero;

  Timer? _scrollTimer;
  double _scrollSpeed = 0;

  bool _justDragged = false;

  /// True from the moment a sweep begins until the next press. The tap a
  /// sweep ends with must not also open or toggle the tile it ends on, and
  /// that tap arrives after the release, so the album asks this first.
  bool get justDragged => _justDragged;

  /// Starts a sweep for the finger that is down, on [photo], which was just
  /// long-pressed. Returns false when there is no finger to follow.
  bool beginHold(AlbumPhoto photo) {
    if (_touchPointer == null) return false;
    _begin(_touchPointer!, photo, _touchAt);
    return true;
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    super.dispose();
  }

  AlbumPhoto? _photoAt(Offset position) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      position,
      View.of(context).viewId,
    );
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is AlbumPhoto) {
        return target.metaData as AlbumPhoto;
      }
    }
    return null;
  }

  void _begin(int pointer, AlbumPhoto photo, Offset at) {
    _active = pointer;
    _justDragged = true;
    _last = at;
    _select = widget.onStart(photo);
  }

  void _down(PointerDownEvent event) {
    _justDragged = false;
    if (event.kind == PointerDeviceKind.mouse) {
      _mousePointer = null;
      if (event.buttons != kPrimaryButton) return;
      // Shift-click and ctrl-click are clicks, not the start of a sweep.
      if (HardwareKeyboard.instance.isShiftPressed) return;
      _mousePointer = event.pointer;
      _mouseDownAt = event.position;
      _mouseDownPhoto = _photoAt(event.position);
    } else {
      _touchPointer = event.pointer;
      _touchAt = event.position;
    }
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer == _touchPointer && _active == null) {
      _touchAt = event.position;
    }

    if (event.pointer == _mousePointer && _active == null) {
      final start = _mouseDownPhoto;
      if (start == null) return;
      if ((event.position - _mouseDownAt).distance <= _dragSlop) return;
      _begin(event.pointer, start, _mouseDownAt);
    }

    if (event.pointer != _active) return;
    _paint(_last, event.position);
    _last = event.position;
    _updateAutoScroll(event.position);
  }

  void _up(PointerEvent event) {
    if (event.pointer == _touchPointer) _touchPointer = null;
    if (event.pointer == _mousePointer) {
      _mousePointer = null;
      _mouseDownPhoto = null;
    }
    if (event.pointer != _active) return;
    _active = null;
    _stopScrolling();
  }

  /// Selects what lies along the line from [from] to [to].
  void _paint(Offset from, Offset to) {
    final steps = ((to - from).distance / _sampleEvery).ceil().clamp(1, 200);
    final crossed = <String, AlbumPhoto>{};
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final at = Offset(
        lerpDouble(from.dx, to.dx, t)!,
        lerpDouble(from.dy, to.dy, t)!,
      );
      final photo = _photoAt(at);
      if (photo != null) crossed[photo.id] = photo;
    }
    if (crossed.isNotEmpty) widget.onPaint(crossed.values, _select);
  }

  void _updateAutoScroll(Offset position) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final y = box.globalToLocal(position).dy;

    // How far into the edge zone the pointer is, 0 to 1, signed by edge.
    double speed = 0;
    if (y < _scrollEdge) {
      speed = -((_scrollEdge - y) / _scrollEdge).clamp(0.0, 1.0);
    } else if (y > box.size.height - _scrollEdge) {
      speed = ((y - (box.size.height - _scrollEdge)) / _scrollEdge).clamp(
        0.0,
        1.0,
      );
    }

    _scrollSpeed = speed * _scrollMaxSpeed;
    if (_scrollSpeed == 0) {
      _stopScrolling();
    } else {
      _scrollTimer ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _scrollTick(),
      );
    }
  }

  void _scrollTick() {
    final controller = widget.controller;
    if (!controller.hasClients) return;
    final position = controller.position;
    final target = (position.pixels + _scrollSpeed).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    controller.jumpTo(target);

    // The tiles moved under a pointer that did not, so what it is over has
    // changed. Look again once the new frame is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _active != null) _paint(_last, _last);
    });
  }

  void _stopScrolling() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
    _scrollSpeed = 0;
  }

  @override
  Widget build(BuildContext context) {
    // The mouse is for sweeping selections, so it must not also drag-scroll
    // the grid (touch, a pen and the trackpad still do).
    final behavior = ScrollConfiguration.of(context);
    return ScrollConfiguration(
      behavior: behavior.copyWith(
        dragDevices: {...behavior.dragDevices}..remove(PointerDeviceKind.mouse),
      ),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: widget.child,
      ),
    );
  }
}
