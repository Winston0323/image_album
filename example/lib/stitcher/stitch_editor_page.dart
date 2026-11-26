import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../pick_album_folder.dart';
import 'group_editor.dart';
import 'image_item.dart';
import 'image_stitcher_service.dart';

/// 多组图片拼接编辑器：顶部「组」标签页，每组独立调参、独立保存。
///
/// 在相册里选好照片（可能分成多组）后进入此页。每组是一个
/// [GroupEditor]，保留图片拼接工具的全部参数（模式、边框、缩放、平移、
/// 排序、标尺、实时预览）。保存时让用户指定一个文件夹，把每组分别拼成
/// 一张 PNG 写入其中。
class StitchEditorPage extends StatefulWidget {
  const StitchEditorPage({super.key, required this.groups});

  /// 各组照片，每个内层列表按选择顺序，拼成一张图。
  final List<List<ImageItem>> groups;

  @override
  State<StitchEditorPage> createState() => _StitchEditorPageState();
}

class _StitchEditorPageState extends State<StitchEditorPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final List<GlobalKey<GroupEditorState>> _keys = [];

  bool _busy = false;
  double? _progress;

  /// Where stitched PNGs go. Defaults to the folder the photos came from, and
  /// is changed only by Save as.
  String? _outputFolder;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: widget.groups.length, vsync: this);
    for (var g = 0; g < widget.groups.length; g++) {
      _keys.add(GlobalKey<GroupEditorState>());
    }
    _outputFolder = _defaultOutputFolder;
  }

  /// The folder the picked photos live in: the directory of the first photo
  /// that has a path. Null when no photo has one.
  String? get _defaultOutputFolder {
    for (final group in widget.groups) {
      for (final item in group) {
        if (item.path.isNotEmpty) {
          final dir = p.dirname(item.path);
          if (dir.isNotEmpty) return dir;
        }
      }
    }
    return null;
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _save({bool saveAs = false}) async {
    if (_busy) return;

    var folder = _outputFolder;
    // Save as always asks; plain Save only asks when no folder is known yet.
    if (saveAs || folder == null) {
      final chosen = await pickAlbumFolder(
        context,
        initialDirectory: folder ?? _defaultOutputFolder,
      );
      if (chosen == null || !mounted) return;
      _outputFolder = chosen;
      folder = chosen;
    }

    setState(() {
      _busy = true;
      _progress = 0;
    });

    final outputs = <String>[];
    String? error;
    try {
      for (var g = 0; g < widget.groups.length; g++) {
        final state = _keys[g].currentState;
        if (state == null || state.isEmpty) continue;

        final bytes = await ImageStitcherService.stitchImages(
          state.imageBytes,
          mode: state.stitchMode,
          onProgress: (value) {
            if (!mounted) return;
            setState(() {
              _progress = (g + value) / widget.groups.length;
            });
          },
          addBorder: state.borderPercent > 0,
          borderColor: state.borderColorIndex == 0
              ? const ui.Color(0xFFFFFFFF)
              : const ui.Color(0xFF000000),
          borderPercent: state.borderPercent,
          rainbowBorder: state.borderColorIndex == 2,
          scales: state.imageScales,
          offsets: state.imageOffsets,
        );

        // Same naming as ImageStitching: stitched_H / stitched_V + a timestamp.
        final name =
            'stitched_${state.stitchMode == StitchMode.horizontal ? 'H' : 'V'}'
            '_${DateTime.now().millisecondsSinceEpoch}.png';
        final file = File(p.join(folder, name));
        await file.writeAsBytes(bytes);
        outputs.add(file.path);
      }
    } catch (e) {
      error = '$e';
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _progress = null;
    });
    await _showResult(outputs, folder, error);
  }

  Future<void> _showResult(
    List<String> outputs,
    String folder,
    String? error,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(error == null ? 'Saved' : 'Save failed'),
        content: Text(
          error ?? '${outputs.length} images saved to\n$folder',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Stitch ${widget.groups.length} group${widget.groups.length == 1 ? '' : 's'}'),
        actions: [
          if (!_busy)
            IconButton(
              icon: const Icon(Icons.save_alt),
              tooltip: 'Save to the photos folder',
              onPressed: _save,
            ),
          if (!_busy)
            IconButton(
              icon: const Icon(Icons.save_as),
              tooltip: 'Save as…',
              onPressed: () => _save(saveAs: true),
            ),
        ],
        bottom: TabBar(
          controller: _tab,
          onTap: (_) => setState(() {}),
          tabs: [
            for (var g = 0; g < widget.groups.length; g++)
              Tab(text: 'Group ${g + 1} · ${widget.groups[g].length}'),
          ],
        ),
      ),
      body: Stack(
        children: [
          IndexedStack(
            index: _tab.index,
            children: [
              for (var g = 0; g < widget.groups.length; g++)
                GroupEditor(
                  key: _keys[g],
                  images: widget.groups[g],
                  groupIndex: g,
                ),
            ],
          ),
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black38,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 56,
                          height: 56,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CircularProgressIndicator(
                                value: _progress,
                                strokeWidth: 5,
                              ),
                              Center(
                                child: Text(
                                  '${((_progress ?? 0) * 100).toInt()}%',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text('Stitching and saving…'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
