import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'image_item.dart';
import 'image_stitcher_service.dart';

/// 单组图片拼接编辑器（参数调整页面，多组由外层标签页承载）。
///
/// 保留图片拼接工具的完整参数：拼接模式、边框颜色/粗细、图片排序/删除、
/// 单图缩放与平移、工程图标尺与实时预览。图片来自外部传入（[images]），
/// 不在本页选取。
class GroupEditor extends StatefulWidget {
  const GroupEditor({
    super.key,
    required this.images,
    required this.groupIndex,
  });

  /// 本组图片（进入页面时已选好）。
  final List<ImageItem> images;

  /// 组序号（0 开始，用于显示）。
  final int groupIndex;

  @override
  State<GroupEditor> createState() => GroupEditorState();
}

enum _ActiveTool { mode, border, image }

class GroupEditorState extends State<GroupEditor> {
  final List<ImageItem> _selectedImages = [];
  StitchMode _stitchMode = StitchMode.horizontal;
  _ActiveTool? _activeTool;

  // 边框设置
  int _borderColorIndex = 0; // 0=白色, 1=黑色
  double _borderPercent = 0.0;

  // 预览数据（GPU 实时绘制，不再缓存整张预览图）
  // 真正的输出尺寸（根据原图尺寸+边框计算，非预览缩放后的尺寸）
  int? _outputWidth;
  int? _outputHeight;
  bool _showRuler = true;
  final ScrollController _windowsThumbScroll = ScrollController();

  bool get _isWindowsDesktop => !kIsWeb && Platform.isWindows;

  // 大预览图点选 + 角点拖拽缩放
  int? _selectedSubImageIndex;
  // 每张图的缩放因子 (1.0=100%, 3.0=300%)
  List<double> _imageScales = [];
  // 每张图的平移偏移（源像素，0,0=居中）
  List<Offset> _imageOffsets = [];
  // 子图拖拽平移
  Offset? _panLastPos;
  Offset? _panStartPos; // 拖拽起始位置（用于阈值判断）
  bool _panActive = false; // 是否已越过阈值，开始实际拖拽
  int? _panPointerId;
  // 双指缩放
  final Map<int, Offset> _activePointers = {};
  double? _pinchStartDist;
  double _pinchStartScale = 1.0;
  // 选中子图的源/显示像素比
  double _selectedSrcToDispRatio = 1.0;
  // 大图变换
  final TransformationController _viewController = TransformationController();
  // 实时预览：缓存解码后的缩略图 ui.Image
  List<ui.Image?> _decodedThumbs = [];

  double _scaleOf(int index) =>
      index < _imageScales.length ? _imageScales[index] : 1.0;

  /// 所有缩略图都已解码，可以实时预览
  bool get _canLivePreview =>
      _selectedImages.isNotEmpty &&
      _decodedThumbs.length >= _selectedImages.length &&
      _decodedThumbs.every((e) => e != null);

  // ========== 暴露给外层（保存时读取本组参数）==========

  List<Uint8List> get imageBytes =>
      [for (final item in _selectedImages) item.bytes];

  StitchMode get stitchMode => _stitchMode;

  int get borderColorIndex => _borderColorIndex;

  double get borderPercent => _borderPercent;

  List<double> get imageScales => List.of(_imageScales);

  List<Offset> get imageOffsets => List.of(_imageOffsets);

  bool get isEmpty => _selectedImages.isEmpty;

  int get imageCount => _selectedImages.length;

  @override
  void initState() {
    super.initState();
    _selectedImages.addAll(widget.images);
    for (final item in _selectedImages) {
      _imageScales.add(1.0);
      _imageOffsets.add(Offset.zero);
      _decodedThumbs.add(null);
      // 异步生成缩略图（内部会补全尺寸并刷新输出尺寸）
      _generateThumbnail(item);
    }
    _calculateOutputDimensions();
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 600;

    if (isWide) {
      return _buildWideLayout();
    }
    // 窄屏（手机）
    if (!kIsWeb && Platform.isAndroid) {
      return _buildAndroidNarrowLayout();
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: _buildNarrowLayout(),
    );
  }

  // ========== 预览面板（常驻）==========

  Widget _buildPreviewPanel() {
    if (!kIsWeb && Platform.isAndroid) return _buildAndroidPreview();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部工具栏（去卡片化）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.grey.shade300, width: 0.5)),
          ),
          child: Row(
            children: [
              const Icon(Icons.preview, size: 16, color: Colors.grey),
              const SizedBox(width: 6),
              Text('${_stitchMode == StitchMode.horizontal ? "Horizontal" : "Vertical"} stitch',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
              if (_outputWidth != null && _outputHeight != null) ...[
                const SizedBox(width: 8),
                Text('$_outputWidth × $_outputHeight px',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              ],
              const Spacer(),
              if (_outputWidth != null)
                SizedBox(
                  width: 28, height: 28,
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      _showRuler ? Icons.straighten : Icons.straighten_outlined,
                      size: 18,
                      color: _showRuler ? Colors.blue : Colors.grey,
                    ),
                    tooltip: _showRuler ? 'Hide ruler' : 'Show ruler',
                    onPressed: () => setState(() => _showRuler = !_showRuler),
                  ),
                ),
              SizedBox(
                width: 28, height: 28,
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Refresh preview',
                  onPressed: _selectedImages.isNotEmpty ? _autoPreview : null,
                ),
              ),
            ],
          ),
        ),
        // 内容区域
        Expanded(
          child: _buildPreviewContent(),
        ),
      ],
    );
  }

  /// 预览内容区（图片 + 工程图标注 + 保存进度）
  Widget _buildPreviewContent() {
    // 标注线需要的额外空间
    const extPad = 32.0;
    return Stack(
      alignment: Alignment.center,
      children: [
        // 图片或占位
        if (_canLivePreview && _outputWidth != null && _outputHeight != null)
          InteractiveViewer(
            transformationController: _viewController,
            panEnabled: _selectedSubImageIndex == null,
            scaleEnabled: _selectedSubImageIndex == null,
            minScale: 0.15,
            maxScale: 8.0,
            boundaryMargin: const EdgeInsets.all(40),
            child: Center(
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final containerW = constraints.maxWidth;
                  final containerH = constraints.maxHeight;
                  if (containerW <= 0 || containerH <= 0) return _buildEmptyPreview();
                  // 预留标注线空间
                  final availW = containerW - extPad;
                  final availH = containerH - extPad;
                  final imgAspect = _outputWidth! / _outputHeight!;
                  double dispW, dispH;
                  if (availW / availH > imgAspect) {
                    dispH = availH;
                    dispW = dispH * imgAspect;
                  } else {
                    dispW = availW;
                    dispH = dispW / imgAspect;
                  }
                  final left = (containerW - dispW) / 2;
                  final top = (containerH - dispH) / 2;
                  // 计算子图区域（用于点击检测和选中高亮）
                  final displayScaleX = dispW / _outputWidth!;
                  final displayScaleY = dispH / _outputHeight!;
                  final subRects = _buildSubRects(
                    left, top, displayScaleX, displayScaleY,
                  );
                  // 计算选中子图的源/显示像素比（供拖拽转换用）
                  if (_selectedSubImageIndex != null && _selectedSubImageIndex! < subRects.length) {
                    final item = _selectedImages[_selectedSubImageIndex!];
                    if (item.originalWidth != null) {
                      final s = _scaleOf(_selectedSubImageIndex!);
                      final cropW = item.originalWidth! / s;
                      final dispW_i = subRects[_selectedSubImageIndex!].width;
                      _selectedSrcToDispRatio = dispW_i > 0 ? cropW / dispW_i : 1.0;
                    }
                  }

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => _onPreviewTap(d.localPosition, subRects),
                    child: SizedBox(
                    width: containerW,
                    height: containerH,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // 图片（Listener 实现拖拽平移，绕过手势竞争）
                        Positioned(
                          left: left, top: top,
                          width: dispW, height: dispH,
                          child: Listener(
                            onPointerSignal: (e) {
                              if (e is! PointerScrollEvent) return;
                              if (_selectedSubImageIndex != null) {
                                // 滚轮缩放子图
                                final idx = _selectedSubImageIndex!;
                                final cur = _scaleOf(idx);
                                final newScale = (cur - e.scrollDelta.dy / 400).clamp(1.0, 3.0);
                                if ((newScale - cur).abs() > 0.002) {
                                  setState(() {
                                    while (_imageScales.length <= idx) _imageScales.add(1.0);
                                    _imageScales[idx] = double.parse(newScale.toStringAsFixed(2));
                                  });
                                  _calculateOutputDimensions();
                                }
                              } else {
                                // 滚轮缩放大图
                                final cur = _viewController.value.getMaxScaleOnAxis();
                                final newScale = (cur - e.scrollDelta.dy / 400).clamp(0.15, 8.0);
                                final factor = newScale / cur;
                                final matrix = _viewController.value.clone();
                                matrix.scale(factor);
                                _viewController.value = matrix;
                              }
                            },
                            onPointerDown: (e) {
                              if (_selectedSubImageIndex == null) return;
                              _activePointers[e.pointer] = e.localPosition;
                              if (_activePointers.length == 2) {
                                // 双指缩放开始
                                final pts = _activePointers.values.toList();
                                _pinchStartDist = (pts[0] - pts[1]).distance;
                                _pinchStartScale = _scaleOf(_selectedSubImageIndex!);
                                _panPointerId = null;
                                _panLastPos = null;
                                _panActive = false;
                              } else if (_activePointers.length == 1) {
                                // 单指：记录起始位置，延迟判断是点击还是拖拽
                                _panPointerId = e.pointer;
                                _panLastPos = e.localPosition;
                                _panStartPos = e.localPosition;
                                _panActive = false;
                              }
                            },
                            onPointerMove: (e) {
                              if (_selectedSubImageIndex == null) return;
                              if (!_activePointers.containsKey(e.pointer)) return;
                              _activePointers[e.pointer] = e.localPosition;
                              if (_activePointers.length >= 2 && _pinchStartDist != null) {
                                // 双指缩放子图
                                final pts = _activePointers.values.toList();
                                final dist = (pts[0] - pts[1]).distance;
                                final newScale = (_pinchStartScale * dist / _pinchStartDist!).clamp(1.0, 3.0);
                                final idx = _selectedSubImageIndex!;
                                final cur = _scaleOf(idx);
                                if ((newScale - cur).abs() > 0.002) {
                                  setState(() {
                                    while (_imageScales.length <= idx) _imageScales.add(1.0);
                                    _imageScales[idx] = double.parse(newScale.toStringAsFixed(2));
                                  });
                                  _calculateOutputDimensions();
                                }
                              } else if (e.pointer == _panPointerId && _panLastPos != null) {
                                // 单指：超过阈值才开始拖拽，避免误触
                                if (!_panActive && _panStartPos != null) {
                                  if ((e.localPosition - _panStartPos!).distance < 10) return;
                                  _panActive = true;
                                  _panLastPos = e.localPosition; // 重置基准，避免跳变
                                }
                                if (_panActive) {
                                  final delta = e.localPosition - _panLastPos!;
                                  _panLastPos = e.localPosition;
                                  _onImagePanDelta(delta);
                                }
                              }
                            },
                            onPointerUp: (e) {
                              _activePointers.remove(e.pointer);
                              if (e.pointer == _panPointerId) { _panPointerId = null; _panLastPos = null; _panActive = false; }
                              if (_activePointers.isEmpty) _pinchStartDist = null;
                            },
                            onPointerCancel: (e) {
                              _activePointers.remove(e.pointer);
                              if (e.pointer == _panPointerId) { _panPointerId = null; _panLastPos = null; _panActive = false; }
                              if (_activePointers.isEmpty) _pinchStartDist = null;
                            },
                            child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: CustomPaint(
                              size: Size(dispW, dispH),
                              painter: _LivePreviewPainter(
                                images: [for (var e in _decodedThumbs) e!],
                                mode: _stitchMode,
                                scales: _imageScales,
                                offsets: _imageOffsets,
                                originalDims: [
                                  for (var item in _selectedImages)
                                    if (item.originalWidth != null && item.originalHeight != null)
                                      (width: item.originalWidth!, height: item.originalHeight!),
                                ],
                                addBorder: _borderPercent > 0,
                                borderColor: _borderUiColor,
                                borderPercent: _borderPercent,
                                rainbowBorder: _isRainbowBorder,
                              ),
                            ),
                          ),
                          ),
                        ),
                        // 选中高亮（独立于标尺，始终显示）
                        if (_selectedSubImageIndex != null &&
                            _selectedSubImageIndex! < subRects.length)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _HighlightPainter(
                                  subRects[_selectedSubImageIndex!],
                                ),
                              ),
                            ),
                          ),
                        // 工程图样式标注 - 填满容器以确保有空间画延伸线
                        if (_showRuler)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _DimensionPainter(
                                imageLeft: left, imageTop: top,
                                imageWidth: dispW, imageHeight: dispH,
                                displayWidth: _outputWidth!,
                                displayHeight: _outputHeight!,
                                strokeColor: Colors.white70,
                                textColor: Colors.white,
                                stitchMode: _stitchMode,
                                originalDims: [
                                  for (var item in _selectedImages)
                                    if (item.originalWidth != null && item.originalHeight != null)
                                      (width: item.originalWidth!, height: item.originalHeight!),
                                ],
                                borderPercent: _borderPercent,
                                selectedIndex: _selectedSubImageIndex,
                                imageScales: _imageScales,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    ),
                  );
                },
              ),
            ),
          )
        else
          _buildEmptyPreview(),
      ],
    );
  }

  Widget _buildEmptyPreview() {
    return Container(
      color: Colors.grey.shade100,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.image_outlined, size: 48, color: Colors.grey[350]),
          const SizedBox(height: 12),
          Text('Select images to\nsee the preview here',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Colors.grey[400], height: 1.5)),
        ]),
      ),
    );
  }

  /// Android 平台：无卡片边框，预览居中全屏显示
  Widget _buildAndroidPreview() {
    return Stack(
      alignment: Alignment.center,
      children: [
        _canLivePreview
            ? InteractiveViewer(
                minScale: 0.15,
                maxScale: 8.0,
                boundaryMargin: const EdgeInsets.all(16),
                child: Center(
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
                        return const SizedBox.shrink();
                      }
                      return SizedBox(
                        width: constraints.maxWidth,
                        height: constraints.maxHeight,
                        child: CustomPaint(
                          painter: _LivePreviewPainter(
                            images: [for (var e in _decodedThumbs) e!],
                            mode: _stitchMode,
                            scales: _imageScales,
                            offsets: _imageOffsets,
                            originalDims: [
                              for (var item in _selectedImages)
                                if (item.originalWidth != null && item.originalHeight != null)
                                  (width: item.originalWidth!, height: item.originalHeight!),
                            ],
                            addBorder: _borderPercent > 0,
                            borderColor: _borderUiColor,
                            borderPercent: _borderPercent,
                            rainbowBorder: _isRainbowBorder,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              )
            : Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.image_outlined, size: 64, color: Colors.grey[350]),
                  const SizedBox(height: 12),
                  Text('Select images to\nsee the preview here',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: Colors.grey[500], height: 1.5)),
                ]),
              ),
      ],
    );
  }

  // ========== 宽屏布局 ==========

  /// 宽屏：左侧功能卡片 + 右侧预览。
  /// Windows 上「选择图片」整张卡片在预览下方，图片成一行，可滚动、可拖拽排序。
  Widget _buildWideLayout() {
    final windows = _isWindowsDesktop;
    final preview = windows
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildPreviewPanel()),
              const SizedBox(height: 12),
              _buildImageCard(),
            ],
          )
        : _buildPreviewPanel();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 280,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  if (!windows) ...[
                    _buildImageCard(),
                    const SizedBox(height: 12),
                  ],
                  _buildModeCard(),
                  const SizedBox(height: 12),
                  _buildBorderCard(),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(child: preview),
        ],
      ),
    );
  }

  /// Windows：预览卡片下方的输入图横条。拖拽换序，滚轮或底部滚动条左右移动。
  Widget _buildWindowsInputStrip() {
    const thumbHeight = 84.0;
    return SizedBox(
      height: thumbHeight + 14,
      child: Listener(
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent || !_windowsThumbScroll.hasClients) return;
          final position = _windowsThumbScroll.position;
          if (!position.hasContentDimensions || position.maxScrollExtent <= 0) return;
          final delta = event.scrollDelta.dy != 0 ? event.scrollDelta.dy : event.scrollDelta.dx;
          final target = (position.pixels + delta).clamp(0.0, position.maxScrollExtent).toDouble();
          _windowsThumbScroll.jumpTo(target);
        },
        child: Scrollbar(
          controller: _windowsThumbScroll,
          thumbVisibility: true,
          child: ReorderableListView.builder(
            scrollController: _windowsThumbScroll,
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.only(bottom: 12, right: 4),
            itemCount: _selectedImages.length,
            onReorderItem: (oldIndex, newIndex) {
              setState(() => _reorderImageLists(oldIndex, newIndex));
              _autoPreview();
            },
            proxyDecorator: (child, index, animation) {
              return AnimatedBuilder(
                animation: animation,
                builder: (context, child) => Material(
                  elevation: 4 * animation.value,
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.transparent,
                  child: child,
                ),
                child: child,
              );
            },
            itemBuilder: (_, index) {
              final item = _selectedImages[index];
              return Padding(
                key: ObjectKey(item),
                padding: const EdgeInsets.only(right: 8),
                child: _windowsInputThumb(index, thumbHeight),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _windowsInputThumb(int index, double thumbHeight) {
    final item = _selectedImages[index];
    var thumbWidth = thumbHeight;
    if (item.thumbWidth != null && item.thumbHeight != null && item.thumbHeight! > 0) {
      thumbWidth = thumbHeight * item.thumbWidth! / item.thumbHeight!;
    }
    return SizedBox(
      width: thumbWidth,
      height: thumbHeight,
      child: Stack(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Tooltip(
                message: 'Drag to reorder',
                child: Container(
                  width: thumbWidth,
                  height: thumbHeight,
                  decoration: BoxDecoration(
                    color: Colors.grey[800],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: item.thumbnailBytes != null
                        ? Image.memory(item.thumbnailBytes!, fit: BoxFit.cover)
                        : Image.memory(item.bytes, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _placeholderIcon()),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 2, left: 2,
            child: IgnorePointer(
              child: Container(
                width: 18, height: 18,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Text('${index + 1}',
                    style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
          Positioned(
            top: 0, right: 0,
            child: GestureDetector(
              onTap: () => _removeImageAt(index),
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.cancel, size: 16, color: Colors.white, shadows: [Shadow(blurRadius: 3, color: Colors.black45)]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 三张功能卡片（始终展开）----

  /// 图片卡片（图片已在进入页面时选好，这里只展示、排序、删除）
  Widget _buildImageCard() {
    return _wideCard(
      icon: Icons.add_photo_alternate_outlined,
      title: 'Images',
      subtitle: _selectedImages.isEmpty ? 'None' : '${_selectedImages.length} selected',
      onClear: _selectedImages.isNotEmpty ? () => setState(() { _selectedImages.clear(); _imageScales.clear(); _decodedThumbs.clear(); _imageOffsets.clear(); _selectedSubImageIndex = null; _outputWidth = null; _outputHeight = null; }) : null,
      child: _isWindowsDesktop
          ? (_selectedImages.isEmpty
              ? const SizedBox(
                  height: 24,
                  child: Center(
                    child: Text(
                      'No images in this group',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                )
              : _buildWindowsInputStrip())
          : _buildImageContentWide(),
    );
  }

  /// 拼接模式卡片
  Widget _buildModeCard() {
    final disabled = _selectedImages.length <= 1;
    return _wideCard(
      icon: Icons.settings_suggest,
      title: 'Stitch mode',
      subtitle: disabled ? 'At least 2 images' : (_stitchMode == StitchMode.horizontal ? 'Horizontal stitch' : 'Vertical stitch'),
      enabled: !disabled,
      child: _buildModeSubToolbar(),
    );
  }

  /// 边框卡片
  Widget _buildBorderCard() {
    return _wideCard(
      icon: Icons.border_style,
      title: 'Border',
      subtitle: _borderPercent > 0
          ? '${_borderColorIndex == 0 ? "White" : _borderColorIndex == 1 ? "Black" : "Rainbow"} · ${_borderPercent.toInt()}%'
          : 'None',
      child: _buildBorderSubToolbar(),
    );
  }

  /// 通用宽屏卡片（始终展开）
  Widget _wideCard({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? child,
    VoidCallback? onClear,
    bool enabled = true,
  }) {
    final disabled = !enabled;

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 卡片头部
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
            ),
            child: Row(
              children: [
                Icon(icon, size: 20,
                    color: disabled ? Colors.grey[400] : Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600,
                          color: disabled ? Colors.grey[400] : null)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: TextStyle(
                          fontSize: 11,
                          color: disabled ? Colors.grey[400] : Colors.grey[600])),
                    ],
                  ),
                ),
                if (onClear != null)
                  SizedBox(
                    width: 28, height: 28,
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      icon: Icon(Icons.delete_outline, size: 18, color: Colors.red[400]),
                      onPressed: onClear,
                    ),
                  ),
              ],
            ),
          ),
          // 内容区（始终可见）
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: child ?? const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  // ========== 组件方法 ==========

  Widget _buildNarrowLayout() {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.5,
                  ),
                  child: _buildPreviewPanel(),
                ),
              ],
            ),
          ),
        ),
        _buildSubToolbar(),
        _buildBottomToolbar(),
      ],
    );
  }

  /// Android 窄屏布局：固定布局不可滚动，预览居中占主要空间，控制区在底部
  Widget _buildAndroidNarrowLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 预览居中，填充主要空间
        Expanded(
          child: Center(child: _buildAndroidPreview()),
        ),
        const Divider(height: 1),
        // 底部紧凑控制区
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSubToolbar(),
            _buildBottomToolbar(),
          ],
        ),
      ],
    );
  }

  // ========== 底部工具栏 ==========

  /// 一排按钮，可横向滑动，固定在底部
  Widget _buildBottomToolbar() {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSafe + 8, left: 12, right: 12, top: 8),
      child: SizedBox(
        height: 64,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              SizedBox(
                width: 120,
                child: _toolbarButton(
                  icon: Icons.add_photo_alternate_outlined,
                  label: 'Images',
                  subtitle: '${_selectedImages.length} images',
                  isActive: _activeTool == _ActiveTool.image,
                  onTap: () => _toggleTool(_ActiveTool.image),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                child: _toolbarButton(
                  icon: Icons.settings_suggest,
                  label: 'Stitch mode',
                  subtitle: _stitchMode == StitchMode.horizontal ? 'Horizontal' : 'Vertical',
                  isActive: _activeTool == _ActiveTool.mode,
                  enabled: _selectedImages.length > 1,
                  onTap: () => _toggleTool(_ActiveTool.mode),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 130,
                child: _toolbarButton(
                  icon: Icons.border_style,
                  label: 'Border',
                  subtitle: _borderPercent > 0
                      ? '${_borderColorIndex == 0 ? "White" : _borderColorIndex == 1 ? "Black" : "Rainbow"} ${_borderPercent.toInt()}%'
                      : 'None',
                  isActive: _activeTool == _ActiveTool.border,
                  onTap: () => _toggleTool(_ActiveTool.border),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleTool(_ActiveTool tool) {
    // 只有一张图时不允许切换拼接模式
    if (tool == _ActiveTool.mode && _selectedImages.length <= 1) return;
    setState(() {
      _activeTool = _activeTool == tool ? null : tool;
    });
  }

  Widget _toolbarButton({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool isActive,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final activeColor = scheme.primary.withValues(alpha: 0.2);
    final defaultColor = scheme.surfaceContainerHighest.withValues(alpha: 0.6);
    final disabledColor = scheme.surfaceContainerHighest.withValues(alpha: 0.25);
    final isDisabled = !enabled;
    return Material(
      color: isDisabled ? disabledColor : (isActive ? activeColor : defaultColor),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: isDisabled ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 20, color: isDisabled ? Colors.grey[400] : (isActive ? scheme.primary : scheme.primary.withValues(alpha: 0.7))),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDisabled ? Colors.grey[400] : (isActive ? scheme.primary : null))),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(fontSize: 10, color: isDisabled ? Colors.grey[400] : Colors.grey[600])),
                  ],
                ),
              ),
              Icon(
                isActive ? Icons.expand_more : Icons.expand_less,
                size: 18,
                color: isDisabled ? Colors.grey[400] : (isActive ? scheme.primary : Colors.grey[500]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ========== 子工具栏（显示在主工具栏上方）==========

  /// 子工具栏容器（窄屏用）
  Widget _buildSubToolbar() {
    if (_activeTool == null) return const SizedBox.shrink();

    Widget content;
    switch (_activeTool!) {
      case _ActiveTool.mode:
        content = _buildModeSubToolbar();
        break;
      case _ActiveTool.border:
        content = _buildBorderSubToolbar();
        break;
      case _ActiveTool.image:
        content = _buildImageSubToolbar();
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: content,
    );
  }

  // --- 拼接模式子工具栏 ---
  Widget _buildModeSubToolbar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _subChip(
            icon: Icons.view_column,
            label: 'Horizontal',
            hint: 'Side by side',
            selected: _stitchMode == StitchMode.horizontal,
            onTap: () {
              setState(() => _stitchMode = StitchMode.horizontal);
              _autoPreview();
            },
          ),
          const SizedBox(width: 8),
          _subChip(
            icon: Icons.view_stream,
            label: 'Vertical',
            hint: 'Top to bottom',
            selected: _stitchMode == StitchMode.vertical,
            onTap: () {
              setState(() => _stitchMode = StitchMode.vertical);
              _autoPreview();
            },
          ),
        ],
      ),
    );
  }

  // --- 边框子工具栏 ---
  Widget _buildBorderSubToolbar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 第一栏：颜色选择（横向可滚动，防止溢出卡片）
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _subChip(
                color: Colors.white,
                label: 'White',
                selected: _borderColorIndex == 0,
                onTap: () {
                  setState(() => _borderColorIndex = 0);
                  _autoPreview();
                },
              ),
              const SizedBox(width: 8),
              _subChip(
                color: Colors.black,
                label: 'Black',
                selected: _borderColorIndex == 1,
                onTap: () {
                  setState(() => _borderColorIndex = 1);
                  _autoPreview();
                },
              ),
              const SizedBox(width: 8),
              _subChip(
                icon: Icons.gradient,
                label: 'Rainbow',
                selected: _borderColorIndex == 2,
                onTap: () {
                  setState(() => _borderColorIndex = 2);
                  _autoPreview();
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // 第二栏：粗细调节
        Row(
          children: [
            Text('Thickness', style: TextStyle(fontSize: 12, color: Colors.grey[700])),
            Expanded(
              child: Slider(
                value: _borderPercent,
                min: 0, max: 10, divisions: 10,
                label: '${_borderPercent.toInt()}%',
                onChanged: (v) => setState(() => _borderPercent = v),
                onChangeEnd: (_) => _autoPreview(),
              ),
            ),
            SizedBox(width: 30, child: Text('${_borderPercent.toInt()}%', style: const TextStyle(fontSize: 11))),
          ],
        ),
      ],
    );
  }

  // --- 选择图片子工具栏 ---
  Widget _buildImageSubToolbar() {
    final thumbHeight = 64.0;
    final thumbnailCount = _selectedImages.length;

    // empty state
    if (thumbnailCount == 0) {
      return const SizedBox(
        height: 64,
        child: Center(
          child: Text('No images in this group',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ),
      );
    }

    // 计算所有缩略图总宽度
    double totalThumbWidth = 0;
    for (var item in _selectedImages) {
      double w = thumbHeight;
      if (item.thumbWidth != null && item.thumbHeight != null && item.thumbHeight! > 0) {
        w = thumbHeight * item.thumbWidth! / item.thumbHeight!;
      }
      totalThumbWidth += w + 8; // 8 = right padding
    }

    // 整体可左右滚动，缩略图可长按拖拽排序、点按删除
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          SizedBox(
            width: totalThumbWidth,
            height: thumbHeight,
            child: ReorderableListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: thumbnailCount,
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex--;
                    final item = _selectedImages.removeAt(oldIndex);
                    final scale = _imageScales.length > oldIndex ? _imageScales.removeAt(oldIndex) : 1.0;
                    final thumb = _decodedThumbs.length > oldIndex ? _decodedThumbs.removeAt(oldIndex) : null;
                    final offset = _imageOffsets.length > oldIndex ? _imageOffsets.removeAt(oldIndex) : Offset.zero;
                    _selectedImages.insert(newIndex, item);
                    _imageScales.insert(newIndex, scale);
                    _decodedThumbs.insert(newIndex, thumb);
                    _imageOffsets.insert(newIndex, offset);
                  });
                  _autoPreview();
                },
              proxyDecorator: (child, index, animation) {
                return AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    final scale = 1.0 + animation.value * 0.1;
                    return Transform.scale(
                      scale: scale,
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(8),
                        child: child,
                      ),
                    );
                  },
                  child: child,
                );
              },
              buildDefaultDragHandles: false,
              itemBuilder: (_, index) {
                final item = _selectedImages[index];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(item.path),
                  index: index,
                  child: _imageThumbItem(index, thumbHeight),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _imageThumbItem(int index, double thumbHeight) {
    final item = _selectedImages[index];
    double thumbWidth = thumbHeight;
    if (item.thumbWidth != null && item.thumbHeight != null && item.thumbHeight! > 0) {
      thumbWidth = thumbHeight * item.thumbWidth! / item.thumbHeight!;
    }
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() {
            _selectedImages.removeAt(index);
            _imageScales.removeAt(index);
            _decodedThumbs.removeAt(index);
            _imageOffsets.removeAt(index);
            _autoPreview();
          }),
          child: Stack(
            children: [
              Container(
                width: thumbWidth,
                height: thumbHeight,
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: item.thumbnailBytes != null
                      ? Image.memory(item.thumbnailBytes!, fit: BoxFit.cover)
                      : Image.memory(item.bytes, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _placeholderIcon()),
                ),
              ),
              // 序号角标
              Positioned(
                top: 2, left: 2,
                child: Container(
                  width: 18, height: 18,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: Text('${index + 1}',
                      style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
              // 尺寸标注
              if (item.originalWidth != null && item.originalHeight != null)
                Positioned(
                  bottom: 2, right: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text('${item.originalWidth}×${item.originalHeight}',
                        style: const TextStyle(fontSize: 8, color: Colors.white70)),
                  ),
                ),
              // 删除遮罩
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => setState(() {
                      _selectedImages.removeAt(index);
                      _imageScales.removeAt(index);
                      _decodedThumbs.removeAt(index);
                      _imageOffsets.removeAt(index);
                      _autoPreview();
                    }),
                    child: const Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.cancel, size: 16, color: Colors.white, shadows: [Shadow(blurRadius: 3, color: Colors.black45)]),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- 宽屏选择图片瀑布流 ---

  Widget _buildImageContentWide() {
    final thumbnailCount = _selectedImages.length;

    // empty state
    if (thumbnailCount == 0) {
      return const SizedBox(
        height: 48,
        child: Center(
          child: Text(
            'No images in this group',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      );
    }

    // 单列，按原图比例计算高度，顺序自上而下
    const gap = 6.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 排序按钮（图片已在进入页面时选好）
        if (thumbnailCount > 1) ...[
          Row(
            children: [
              const Spacer(),
              SizedBox(
                width: 40,
                height: 40,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  tooltip: 'Reorder',
                  onPressed: _reorderImages,
                  icon: const Icon(Icons.swap_vert, size: 20),
                  style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: Theme.of(context).colorScheme.outline),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Drag an image onto another, or tap the sort button',
              style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        ],
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (_, constraints) {
            final tileW = constraints.maxWidth;
            return Column(
              children: [
                for (var i = 0; i < thumbnailCount; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: gap),
                    child: _wideImageTile(i, tileW, tileW / _thumbAspect(i)),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  double _thumbAspect(int index) {
    final item = _selectedImages[index];
    if (item.thumbWidth != null && item.thumbHeight != null && item.thumbHeight! > 0) {
      return item.thumbWidth! / item.thumbHeight!;
    }
    return 1.0;
  }

  /// 宽屏缩略图：按住拖到另一张上即可换序。父级是滚动区域，用短按长按拖拽避免和滚动抢手势。
  Widget _wideImageTile(int index, double w, double h) {
    final item = _selectedImages[index];
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) => _moveImageTo(details.data, index),
      builder: (context, candidate, rejected) {
        final highlighted = candidate.isNotEmpty;
        return LongPressDraggable<int>(
          data: index,
          delay: const Duration(milliseconds: 150),
          rootOverlay: true,
          hapticFeedbackOnStart: false,
          feedback: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(6),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(width: w, height: h, child: _wideTileImage(item)),
          ),
          childWhenDragging: Opacity(
            opacity: 0.3,
            child: _wideTileFrame(item, index, w, h),
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: _wideTileFrame(
              item,
              index,
              w,
              h,
              highlighted: highlighted,
              onRemove: () => _removeImageAt(index),
            ),
          ),
        );
      },
    );
  }

  Widget _wideTileImage(ImageItem item) {
    if (item.thumbnailBytes != null) {
      return Image.memory(item.thumbnailBytes!, fit: BoxFit.cover);
    }
    return Image.memory(item.bytes, fit: BoxFit.cover);
  }

  Widget _wideTileFrame(ImageItem item, int index, double w, double h, {bool highlighted = false, VoidCallback? onRemove}) {
    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: Colors.grey[800],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: _wideTileImage(item),
            ),
          ),
          Positioned(
            top: 2, left: 2,
            child: Container(
              width: 16, height: 16,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text('${index + 1}',
                  style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
          if (onRemove != null)
            Positioned(
              top: 0, right: 0,
              child: GestureDetector(
                onTap: onRemove,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: Icon(Icons.close, size: 10, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          if (item.originalWidth != null && item.originalHeight != null)
            Positioned(
              bottom: 2, right: 2,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text('${item.originalWidth}×${item.originalHeight}',
                      style: const TextStyle(fontSize: 8, color: Colors.white70)),
                ),
              ),
            ),
          if (highlighted)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(6)),
                  border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 把 [from] 放到 [to] 的位置，缩放、偏移和缩略图一起移动。
  void _moveImageTo(int from, int to) {
    if (from == to || from < 0 || to < 0) return;
    if (from >= _selectedImages.length || to >= _selectedImages.length) return;
    setState(() => _reorderImageLists(from, to));
    _autoPreview();
  }

  void _reorderImageLists(int from, int to) {
    final item = _selectedImages.removeAt(from);
    final scale = from < _imageScales.length ? _imageScales.removeAt(from) : 1.0;
    final thumb = from < _decodedThumbs.length ? _decodedThumbs.removeAt(from) : null;
    final offset = from < _imageOffsets.length ? _imageOffsets.removeAt(from) : Offset.zero;
    _selectedImages.insert(to, item);
    _imageScales.insert(math.min(to, _imageScales.length), scale);
    _decodedThumbs.insert(math.min(to, _decodedThumbs.length), thumb);
    _imageOffsets.insert(math.min(to, _imageOffsets.length), offset);
    if (_selectedSubImageIndex == from) _selectedSubImageIndex = to;
  }

  void _removeImageAt(int index) {
    setState(() {
      _selectedImages.removeAt(index);
      if (index < _imageScales.length) _imageScales.removeAt(index);
      if (index < _decodedThumbs.length) _decodedThumbs.removeAt(index);
      if (index < _imageOffsets.length) _imageOffsets.removeAt(index);
      if (_selectedSubImageIndex == index) {
        _selectedSubImageIndex = null;
      } else if (_selectedSubImageIndex != null && _selectedSubImageIndex! > index) {
        _selectedSubImageIndex = _selectedSubImageIndex! - 1;
      }
    });
    _autoPreview();
  }

  Widget _subChip({
    IconData? icon,
    Color? color,
    required String label,
    String? hint,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary.withValues(alpha: 0.2) : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.7)),
                const SizedBox(width: 6),
              ] else if (color != null) ...[
                Container(
                  width: 18, height: 18,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: color == Colors.white ? Border.all(color: Colors.grey[400]!) : null,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(label, style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.8))),
              if (hint != null) ...[
                const SizedBox(width: 4),
                Text(hint, style: TextStyle(fontSize: 10, color: Colors.grey[500])),
              ],
            ],
          ),
        ),
      ),
    );
  }


  Widget _placeholderIcon() => Container(width: 44, height: 44, color: Colors.grey[200], child: const Icon(Icons.image, color: Colors.grey, size: 22));

  // ========== 核心功能 ==========

  Future<void> _generateThumbnail(ImageItem item) async {
    try {
      final thumb = await ImageStitcherService.createThumbnail(item.bytes, percent: 10);
      // 解码缩略图获取尺寸 + 缓存 ui.Image 供实时预览用
      final dims = await ImageStitcherService.getImageDimensions(thumb);
      final decoded = await _decodeUiImage(thumb);
      final idx = _selectedImages.indexOf(item);
      if (mounted) {
        setState(() {
          item.thumbnailBytes = thumb;
          if (dims != null) {
            item.thumbWidth = dims.width.toDouble();
            item.thumbHeight = dims.height.toDouble();
          }
          if (decoded != null && idx >= 0) {
            while (_decodedThumbs.length <= idx) _decodedThumbs.add(null);
            if (idx < _decodedThumbs.length) {
              _decodedThumbs[idx] = decoded;
            } else {
              _decodedThumbs.add(decoded);
            }
          }
        });
      }
      // 如果还没有原始尺寸，解码原图获取；补全后刷新输出尺寸
      if (item.originalWidth == null || item.originalHeight == null) {
        final origDims = await ImageStitcherService.getImageDimensions(item.bytes);
        if (origDims != null && mounted) {
          setState(() {
            item.originalWidth = origDims.width;
            item.originalHeight = origDims.height;
            _calculateOutputDimensions();
          });
        }
      }
    } catch (_) {
      // 缩略图生成失败不影响主流程
    }
  }

  Color get _borderUiColor {
    if (_borderColorIndex == 0) return Colors.white;
    if (_borderColorIndex == 1) return Colors.black;
    return Colors.black; // 彩虹模式下 borderColor 不会实际使用
  }
  bool get _isRainbowBorder => _borderColorIndex == 2;

  /// 预览更新：GPU 实时绘制，只需同步计算尺寸 + 触发重绘
  void _autoPreview() {
    if (_selectedImages.isEmpty) {
      setState(() { _outputWidth = null; _outputHeight = null; _selectedSubImageIndex = null; });
      return;
    }
    _calculateOutputDimensions();
    setState(() {}); // 触发 _LivePreviewPainter 重绘
  }

  /// 根据原始图片尺寸和边框设置，计算拼接后真正的输出尺寸（与 stitchImages 保存模式一致）
  void _calculateOutputDimensions() {
    // 需要所有图片都有原始尺寸
    for (var item in _selectedImages) {
      if (item.originalWidth == null || item.originalHeight == null) {
        _outputWidth = null;
        _outputHeight = null;
        return;
      }
    }

    final widths = _selectedImages.map((e) => e.originalWidth!).toList();
    final heights = _selectedImages.map((e) => e.originalHeight!).toList();

    int bw = 0;
    if (_borderPercent > 0) {
      final refDim = _stitchMode == StitchMode.horizontal
          ? heights.reduce((a, b) => a > b ? a : b)
          : widths.reduce((a, b) => a > b ? a : b);
      bw = (refDim * _borderPercent / 100).round().clamp(1, 9999);
    }

    if (_stitchMode == StitchMode.horizontal) {
      final maxH = heights.reduce((a, b) => a > b ? a : b);
      int totalW = 0;
      for (int i = 0; i < _selectedImages.length; i++) {
        totalW += (widths[i] * maxH / heights[i]).round();
      }
      _outputWidth = totalW + bw * (_selectedImages.length + 1);
      _outputHeight = maxH + 2 * bw;
    } else {
      final maxW = widths.reduce((a, b) => a > b ? a : b);
      int totalH = 0;
      for (int i = 0; i < _selectedImages.length; i++) {
        totalH += (heights[i] * maxW / widths[i]).round();
      }
      _outputWidth = maxW + 2 * bw;
      _outputHeight = totalH + bw * (_selectedImages.length + 1);
    }
  }

  /// 解码 bytes 为 ui.Image（供实时预览用）
  Future<ui.Image?> _decodeUiImage(Uint8List bytes) async {
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromList(bytes, (img) => completer.complete(img));
    return completer.future;
  }

  /// 计算每张子图在大预览中的显示矩形（用于点击检测）
  List<ui.Rect> _buildSubRects(double offsetX, double offsetY,
      double scaleX, double scaleY) {
    if (_selectedImages.length <= 1) return [];
    final rects = <ui.Rect>[];
    final n = _selectedImages.length;
    final widths = <int>[];
    final heights = <int>[];
    for (var item in _selectedImages) {
      widths.add(item.originalWidth ?? 0);
      heights.add(item.originalHeight ?? 0);
    }
    if (widths.contains(0)) return [];

    int bw = 0;
    if (_borderPercent > 0) {
      final refDim = _stitchMode == StitchMode.horizontal
          ? heights.reduce((a, b) => a > b ? a : b)
          : widths.reduce((a, b) => a > b ? a : b);
      bw = (refDim * _borderPercent / 100).round().clamp(1, 9999);
    }
    final bwDispX = bw * scaleX;
    final bwDispY = bw * scaleY;

    if (_stitchMode == StitchMode.horizontal) {
      final maxH = heights.reduce((a, b) => a > b ? a : b);
      double x = offsetX + bwDispX;
      for (int i = 0; i < n; i++) {
        final wDisp = (widths[i] * maxH / heights[i]) * scaleX;
        rects.add(ui.Rect.fromLTWH(x, offsetY + bwDispY, wDisp, maxH * scaleY));
        x += wDisp + bwDispX;
      }
    } else {
      final maxW = widths.reduce((a, b) => a > b ? a : b);
      double y = offsetY + bwDispY;
      for (int i = 0; i < n; i++) {
        final hDisp = (heights[i] * maxW / widths[i]) * scaleY;
        rects.add(ui.Rect.fromLTWH(offsetX + bwDispX, y, maxW * scaleX, hDisp));
        y += hDisp + bwDispY;
      }
    }
    return rects;
  }

  /// 大预览图点击 → 选中对应子图
  void _onPreviewTap(Offset localPos, List<ui.Rect> subRects) {
    for (int i = 0; i < subRects.length; i++) {
      if (subRects[i].contains(localPos)) {
        setState(() {
          _selectedSubImageIndex = _selectedSubImageIndex == i ? null : i;
        });
        return;
      }
    }
    // 点到空白区域 → 取消选中
    setState(() { _selectedSubImageIndex = null; });
  }

  /// 选中子图拖拽：平移裁剪中心，限制在图片范围内
  void _onImagePanDelta(Offset displayDelta) {
    if (_selectedSubImageIndex == null) return;
    final idx = _selectedSubImageIndex!;
    final item = _selectedImages[idx];
    if (item.originalWidth == null || item.originalHeight == null) return;

    final s = _scaleOf(idx);
    if (s <= 1.0) return; // 未缩放时无法平移
    // 显示 delta → 源像素 delta（取反：向右拖图片向右移 = 裁剪中心向左移）
    final srcDelta = -displayDelta * _selectedSrcToDispRatio;
    while (_imageOffsets.length <= idx) _imageOffsets.add(Offset.zero);
    var newOffset = _imageOffsets[idx] + srcDelta;

    // 限制在图片范围内（裁剪区域不超出原图边界）
    final cropW = item.originalWidth! / s;
    final cropH = item.originalHeight! / s;
    final maxX = (item.originalWidth! - cropW) / 2;
    final maxY = (item.originalHeight! - cropH) / 2;
    newOffset = Offset(
      newOffset.dx.clamp(-maxX, maxX),
      newOffset.dy.clamp(-maxY, maxY),
    );

    if (newOffset != _imageOffsets[idx]) {
      setState(() => _imageOffsets[idx] = newOffset);
    }
  }



  @override
  void dispose() {
    _windowsThumbScroll.dispose();
    _viewController.dispose();
    super.dispose();
  }

  void _reorderImages() {
    final reordered = List<ImageItem>.from(_selectedImages);
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.sort, size: 20),
            SizedBox(width: 8),
            Text('Reorder images'),
          ]),
          content: SizedBox(
            width: 360,
            height: 320,
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: reordered.length,
              onReorderItem: (oldIndex, newIndex) {
                setDialogState(() {
                  final item = reordered.removeAt(oldIndex);
                  reordered.insert(newIndex, item);
                });
                setState(() => _reorderImageLists(oldIndex, newIndex));
                _autoPreview();
              },
              itemBuilder: (ctx, index) {
                final item = reordered[index];
                return ReorderableDragStartListener(
                  key: ObjectKey(item),
                  index: index,
                  child: ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: Theme.of(ctx).colorScheme.primary,
                      foregroundColor: Colors.white,
                      child: Text('${index + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                    title: Text(item.name, overflow: TextOverflow.ellipsis, maxLines: 1, style: const TextStyle(fontSize: 13)),
                    trailing: const Icon(Icons.drag_handle, color: Colors.grey, size: 20),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
          ],
        ),
      ),
    );
  }

}


/// 工程图风格的尺寸标注 Painter
/// 在图片四周绘制标注线、箭头和尺寸文字
class _DimensionPainter extends CustomPainter {
  final double imageLeft, imageTop, imageWidth, imageHeight;
  final int displayWidth, displayHeight;
  final Color strokeColor;
  final Color textColor;
  final StitchMode stitchMode;
  final List<({int width, int height})> originalDims;
  final double borderPercent;
  final int? selectedIndex;
  final List<double> imageScales;

  _DimensionPainter({
    required this.imageLeft,
    required this.imageTop,
    required this.imageWidth,
    required this.imageHeight,
    required this.displayWidth,
    required this.displayHeight,
    required this.strokeColor,
    required this.textColor,
    required this.stitchMode,
    required this.originalDims,
    required this.borderPercent,
    this.selectedIndex,
    this.imageScales = const [],
  });

  static const double _extensionGap = 12;  // 延伸线与图片边缘的间距
  static const double _extendLength = 18;  // 延伸线伸出长度
  static const double _arrowSize = 7;       // 箭头大小

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = strokeColor
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final imgLeft = imageLeft;
    final imgTop = imageTop;
    final imgRight = imageLeft + imageWidth;
    final imgBottom = imageTop + imageHeight;
    final scaleX = imageWidth / displayWidth;
    final scaleY = imageHeight / displayHeight;

    // ---------- 计算每张子图的显示区域 ----------
    final subRects = _computeSubRects(scaleX, scaleY, imgLeft, imgTop);

    // ---------- 总体标注：底部宽度 ----------
    final hExtLeft = imgLeft + _extensionGap;
    final hExtRight = imgRight - _extensionGap;
    final hLineY = imgBottom + _extendLength + 6;
    canvas.drawLine(Offset(imgLeft, imgBottom), Offset(imgLeft, hLineY), paint);
    canvas.drawLine(Offset(imgRight, imgBottom), Offset(imgRight, hLineY), paint);
    canvas.drawLine(Offset(hExtLeft, hLineY), Offset(hExtRight, hLineY), paint);
    _drawArrow(canvas, Offset(hExtLeft, hLineY), -1, paint);
    _drawArrow(canvas, Offset(hExtRight, hLineY), 1, paint);
    _drawDimText(canvas, '${displayWidth}px',
        Offset((hExtLeft + hExtRight) / 2, hLineY - 7),
        TextAlign.center);

    // ---------- 总体标注：右侧高度 ----------
    final vExtTop = imgTop + _extensionGap;
    final vExtBottom = imgBottom - _extensionGap;
    final vLineX = imgRight + _extendLength + 6;
    canvas.drawLine(Offset(imgRight, imgTop), Offset(vLineX, imgTop), paint);
    canvas.drawLine(Offset(imgRight, imgBottom), Offset(vLineX, imgBottom), paint);
    canvas.drawLine(Offset(vLineX, vExtTop), Offset(vLineX, vExtBottom), paint);
    _drawArrow(canvas, Offset(vLineX, vExtTop), -2, paint);
    _drawArrow(canvas, Offset(vLineX, vExtBottom), 2, paint);
    _drawDimText(canvas, '${displayHeight}px',
        Offset(vLineX + 7, (imgTop + imgBottom) / 2),
        TextAlign.left, rotate: false);

    // ---------- 每张图的独立标注：上边（宽度）+ 边框 ----------
    if (subRects.length > 1) {
      final perPaint = Paint()
        ..color = strokeColor.withValues(alpha: 0.45)
        ..strokeWidth = 0.8
        ..style = PaintingStyle.stroke;
      final borderPaint = Paint()
        ..color = strokeColor.withValues(alpha: 0.3)
        ..strokeWidth = 0.5
        ..style = PaintingStyle.stroke;
      final topLineY = imgTop - _extendLength - 2;

      for (int i = 0; i < subRects.length; i++) {
        final r = subRects[i];
        final midX = r.left + r.width / 2;
        canvas.drawLine(Offset(midX, imgTop), Offset(midX, imgTop - 8), perPaint);
        _drawDimTextSmall(canvas, '${originalDims[i].width}',
            Offset(midX, topLineY), TextAlign.center);

        // 边框标注：每张图之间的间隙
        if (i < subRects.length - 1) {
          final gapLeft = r.right;
          final gapRight = subRects[i + 1].left;
          if (gapRight > gapLeft) {
            final gapMid = (gapLeft + gapRight) / 2;
            canvas.drawLine(Offset(gapLeft, imgTop), Offset(gapLeft, imgTop - 5), borderPaint);
            canvas.drawLine(Offset(gapRight, imgTop), Offset(gapRight, imgTop - 5), borderPaint);
            final bwPx = stitchMode == StitchMode.horizontal
                ? ((gapRight - gapLeft) / scaleX).round()
                : ((gapRight - gapLeft) / scaleY).round();
            _drawDimTextTiny(canvas, '↔$bwPx',
                Offset(gapMid, topLineY), TextAlign.center);
          }
        }
      }

      // ---------- 每张图的独立标注：左边（高度）+ 边框 ----------
      final leftLineX = imgLeft - _extendLength - 2;

      for (int i = 0; i < subRects.length; i++) {
        final r = subRects[i];
        final midY = r.top + r.height / 2;
        canvas.drawLine(Offset(imgLeft, midY), Offset(imgLeft - 8, midY), perPaint);
        _drawDimTextSmall(canvas, '${originalDims[i].height}',
            Offset(leftLineX, midY + 1), TextAlign.right);

        // 边框标注：每张图之间的间隙
        if (i < subRects.length - 1) {
          final gapTop = r.bottom;
          final gapBottom = subRects[i + 1].top;
          if (gapBottom > gapTop) {
            final gapMid = (gapTop + gapBottom) / 2;
            canvas.drawLine(Offset(imgLeft, gapTop), Offset(imgLeft - 5, gapTop), borderPaint);
            canvas.drawLine(Offset(imgLeft, gapBottom), Offset(imgLeft - 5, gapBottom), borderPaint);
            final bwPx = ((gapBottom - gapTop) / (stitchMode == StitchMode.horizontal ? scaleY : scaleX)).round();
            _drawDimTextTiny(canvas, '↕$bwPx',
                Offset(leftLineX - 14, gapMid), TextAlign.right);
          }
        }
      }
    }
  }

  /// 计算每张子图在显示屏上的矩形区域（含边框间距）
  List<ui.Rect> _computeSubRects(double scaleX, double scaleY,
      double offsetX, double offsetY) {
    if (originalDims.isEmpty) return [];
    final rects = <ui.Rect>[];
    final n = originalDims.length;
    final widths = originalDims.map((e) => e.width).toList();
    final heights = originalDims.map((e) => e.height).toList();

    int bw = 0; // border width in output pixels
    if (borderPercent > 0) {
      final refDim = stitchMode == StitchMode.horizontal
          ? heights.reduce((a, b) => a > b ? a : b)
          : widths.reduce((a, b) => a > b ? a : b);
      bw = (refDim * borderPercent / 100).round().clamp(1, 9999);
    }
    final bwDispX = bw * scaleX;
    final bwDispY = bw * scaleY;

    if (stitchMode == StitchMode.horizontal) {
      final maxH = heights.reduce((a, b) => a > b ? a : b);
      double x = offsetX + bwDispX;
      for (int i = 0; i < n; i++) {
        final wDisp = (widths[i] * maxH / heights[i]) * scaleX;
        rects.add(ui.Rect.fromLTWH(x, offsetY + bwDispY, wDisp, maxH * scaleY));
        x += wDisp + bwDispX;
      }
    } else {
      final maxW = widths.reduce((a, b) => a > b ? a : b);
      double y = offsetY + bwDispY;
      for (int i = 0; i < n; i++) {
        final hDisp = (heights[i] * maxW / widths[i]) * scaleY;
        rects.add(ui.Rect.fromLTWH(offsetX + bwDispX, y, maxW * scaleX, hDisp));
        y += hDisp + bwDispY;
      }
    }
    return rects;
  }

  void _drawArrow(Canvas canvas, Offset tip, int direction, Paint paint) {
    // direction: -1=left, 1=right, -2=up, 2=down
    double dx1, dy1, dx2, dy2;
    if (direction == -1) {
      dx1 = _arrowSize; dy1 = -_arrowSize / 2; dx2 = _arrowSize; dy2 = _arrowSize / 2;
    } else if (direction == 1) {
      dx1 = -_arrowSize; dy1 = -_arrowSize / 2; dx2 = -_arrowSize; dy2 = _arrowSize / 2;
    } else if (direction == -2) {
      dx1 = -_arrowSize / 2; dy1 = _arrowSize; dx2 = _arrowSize / 2; dy2 = _arrowSize;
    } else {
      dx1 = -_arrowSize / 2; dy1 = -_arrowSize; dx2 = _arrowSize / 2; dy2 = -_arrowSize;
    }
    final fillPaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx + dx1, tip.dy + dy1)
      ..lineTo(tip.dx + dx2, tip.dy + dy2)
      ..close();
    canvas.drawPath(path, fillPaint);
  }

  void _drawDimText(Canvas canvas, String text, Offset center,
      TextAlign align, {bool rotate = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
        ),
      ),
      textAlign: align,
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: 300);

    if (rotate) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(-math.pi / 2);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    } else {
      tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height));
    }
  }

  /// 小号文字（每张图的独立标注）
  void _drawDimTextSmall(Canvas canvas, String text, Offset center,
      TextAlign align) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor.withValues(alpha: 0.6),
          fontSize: 9,
          fontWeight: FontWeight.w500,
          fontFamily: 'monospace',
        ),
      ),
      textAlign: align,
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: 200);

    // 半透明背景
    final bgPaint = Paint()
      ..color = const ui.Color(0x33000000)
      ..style = PaintingStyle.fill;
    final bgRect = ui.Rect.fromCenter(
      center: center, width: tp.width + 6, height: tp.height + 2,
    );
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(bgRect, const Radius.circular(3)),
      bgPaint,
    );

    final paintX = align == TextAlign.right
        ? center.dx - tp.width - 3
        : center.dx - tp.width / 2;
    tp.paint(canvas, Offset(paintX, center.dy - tp.height / 2));
  }

  /// 极小文字（边框宽度标注）
  void _drawDimTextTiny(Canvas canvas, String text, Offset center,
      TextAlign align) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor.withValues(alpha: 0.45),
          fontSize: 8,
          fontWeight: FontWeight.w400,
          fontFamily: 'monospace',
        ),
      ),
      textAlign: align,
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: 160);

    final paintX = align == TextAlign.right
        ? center.dx - tp.width
        : center.dx - tp.width / 2;
    tp.paint(canvas, Offset(paintX, center.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _DimensionPainter oldDelegate) {
    return imageLeft != oldDelegate.imageLeft ||
        imageTop != oldDelegate.imageTop ||
        imageWidth != oldDelegate.imageWidth ||
        imageHeight != oldDelegate.imageHeight ||
        displayWidth != oldDelegate.displayWidth ||
        displayHeight != oldDelegate.displayHeight ||
        stitchMode != oldDelegate.stitchMode ||
        selectedIndex != oldDelegate.selectedIndex;
  }
}


/// 选中高亮 Painter（独立于标尺，仅由选中状态决定）
class _HighlightPainter extends CustomPainter {
  final ui.Rect rect;
  _HighlightPainter(this.rect);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      rect,
      Paint()..color = const ui.Color(0xFF4488FF)..strokeWidth = 3.0..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _HighlightPainter oldDelegate) =>
      rect != oldDelegate.rect;
}

/// 实时预览 Painter：拖拽时直接用 GPU 画布绘制，跳过 PNG 编解码
class _LivePreviewPainter extends CustomPainter {
  final List<ui.Image> images;
  final StitchMode mode;
  final List<double> scales;
  final List<Offset> offsets;
  final List<({int width, int height})> originalDims;
  final bool addBorder;
  final ui.Color borderColor;
  final double borderPercent;
  final bool rainbowBorder;

  _LivePreviewPainter({
    required this.images,
    required this.mode,
    required this.scales,
    required this.offsets,
    required this.originalDims,
    required this.addBorder,
    required this.borderColor,
    required this.borderPercent,
    required this.rainbowBorder,
  });

  /// 计算源裁剪区域（scale>1 时取中心 1/s 区域，offset 偏移裁剪中心）
  /// offset 以原图像素存储，需转换为缩略图像素
  ui.Rect _computeSrcRect(ui.Image src, double s, Offset offset, int origW, int origH) {
    if (s <= 1.0) {
      return ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble());
    }
    // 原图像素 → 缩略图像素
    final sx = src.width / origW;
    final sy = src.height / origH;
    final thumbOffset = Offset(offset.dx * sx, offset.dy * sy);
    final cw = src.width / s;
    final ch = src.height / s;
    final cx = src.width / 2 + thumbOffset.dx;
    final cy = src.height / 2 + thumbOffset.dy;
    return ui.Rect.fromLTWH(
      (cx - cw / 2).clamp(0.0, src.width - cw),
      (cy - ch / 2).clamp(0.0, src.height - ch),
      cw, ch,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (images.isEmpty) return;

    // 计算画布尺寸（与 stitchImages 一致，但不含 scale 对框的影响）
    int maxHeight = images.map((e) => e.height).reduce((a, b) => a > b ? a : b);
    int maxWidth = images.map((e) => e.width).reduce((a, b) => a > b ? a : b);
    int bw = 0;
    if (addBorder) {
      final ref = mode == StitchMode.horizontal ? maxHeight : maxWidth;
      bw = (ref * borderPercent / 100).round().clamp(1, 9999);
    }

    // 计算 dstRects + srcRects
    final dstRects = <ui.Rect>[];
    final srcRects = <ui.Rect>[];
    int canvasW, canvasH;

    if (mode == StitchMode.horizontal) {
      int totalW = 0;
      for (int i = 0; i < images.length; i++) {
        final src = images[i];
        final s = i < scales.length ? scales[i] : 1.0;
        final w = (src.width * maxHeight / src.height).round();
        dstRects.add(ui.Rect.fromLTWH(totalW.toDouble(), 0, w.toDouble(), maxHeight.toDouble()));
        final origW = i < originalDims.length ? originalDims[i].width : src.width;
        final origH = i < originalDims.length ? originalDims[i].height : src.height;
        srcRects.add(_computeSrcRect(src, s, i < offsets.length ? offsets[i] : Offset.zero, origW, origH));
        totalW += w;
      }
      canvasW = totalW + bw * (images.length + 1);
      canvasH = maxHeight + 2 * bw;
      if (addBorder) {
        double ox = bw.toDouble();
        for (int i = 0; i < dstRects.length; i++) {
          dstRects[i] = ui.Rect.fromLTWH(ox, bw.toDouble(), dstRects[i].width, dstRects[i].height);
          ox += dstRects[i].width + bw;
        }
      }
    } else {
      int totalH = 0;
      for (int i = 0; i < images.length; i++) {
        final src = images[i];
        final s = i < scales.length ? scales[i] : 1.0;
        final h = (src.height * maxWidth / src.width).round();
        dstRects.add(ui.Rect.fromLTWH(0, totalH.toDouble(), maxWidth.toDouble(), h.toDouble()));
        final origW2 = i < originalDims.length ? originalDims[i].width : src.width;
        final origH2 = i < originalDims.length ? originalDims[i].height : src.height;
        srcRects.add(_computeSrcRect(src, s, i < offsets.length ? offsets[i] : Offset.zero, origW2, origH2));
        totalH += h;
      }
      canvasW = maxWidth + 2 * bw;
      canvasH = totalH + bw * (images.length + 1);
      if (addBorder) {
        double oy = bw.toDouble();
        for (int i = 0; i < dstRects.length; i++) {
          dstRects[i] = ui.Rect.fromLTWH(bw.toDouble(), oy, dstRects[i].width, dstRects[i].height);
          oy += dstRects[i].height + bw;
        }
      }
    }

    // 缩放到画布显示区域（BoxFit.contain）
    final scaleX = size.width / canvasW;
    final scaleY = size.height / canvasH;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final dispW = canvasW * scale;
    final dispH = canvasH * scale;
    final offX = (size.width - dispW) / 2;
    final offY = (size.height - dispH) / 2;

    canvas.save();
    canvas.translate(offX, offY);
    canvas.scale(scale);

    // 白色背景
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, canvasW.toDouble(), canvasH.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    // 彩虹边框：渐变跨越整个画布（与 stitchImages 服务端一致）
    ui.Shader? rainbowShader;
    if (addBorder && rainbowBorder) {
      rainbowShader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          ui.Color(0xFFFF0000), ui.Color(0xFFFF7F00),
          ui.Color(0xFFFFFF00), ui.Color(0xFF00FF00),
          ui.Color(0xFF0000FF), ui.Color(0xFF4B0082),
          ui.Color(0xFF8B00FF),
        ],
      ).createShader(ui.Rect.fromLTWH(0, 0, canvasW.toDouble(), canvasH.toDouble()));
    }

    // 边框 + 图片
    for (int i = 0; i < images.length; i++) {
      final dst = dstRects[i];
      if (addBorder) {
        final br = ui.Rect.fromLTWH(dst.left - bw, dst.top - bw, dst.width + 2 * bw, dst.height + 2 * bw);
        if (rainbowBorder && rainbowShader != null) {
          canvas.drawRect(br, ui.Paint()..shader = rainbowShader);
        } else {
          canvas.drawRect(br, ui.Paint()..color = borderColor);
        }
      }
      canvas.drawImageRect(
        images[i],
        srcRects[i],
        dst,
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LivePreviewPainter oldDelegate) => true;
}
