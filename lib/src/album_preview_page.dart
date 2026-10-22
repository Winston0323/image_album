import 'dart:io';

import 'package:flutter/material.dart';

import 'album_photo.dart';
import 'photo_info_sheet.dart';

/// Full-screen viewer for photos already on disk. Swiping moves through
/// [photos] in the same order the grid shows them.
class AlbumPreviewPage extends StatefulWidget {
  const AlbumPreviewPage({
    super.key,
    required this.photos,
    required this.initialIndex,
  });

  final List<AlbumPhoto> photos;
  final int initialIndex;

  @override
  State<AlbumPreviewPage> createState() => _AlbumPreviewPageState();
}

class _AlbumPreviewPageState extends State<AlbumPreviewPage> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precacheNeighbors(_index);
  }

  /// Decodes at roughly twice the screen's pixel width instead of the shot's
  /// full resolution. Twice the screen keeps a pinch-zoom reasonably sharp;
  /// `fit` never upscales anything already smaller.
  ImageProvider _providerFor(File file) {
    final size = MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return ResizeImage(
      FileImage(file),
      width: (size.width * ratio * 2).round(),
      policy: ResizeImagePolicy.fit,
    );
  }

  /// Starts decoding the shots on either side, so by the time a swipe lands
  /// the neighbor is already sitting decoded in the image cache.
  void _precacheNeighbors(int index) {
    for (final neighbor in [index - 1, index + 1]) {
      if (neighbor < 0 || neighbor >= widget.photos.length) continue;
      precacheImage(
        _providerFor(widget.photos[neighbor].file),
        context,
        // A corrupt neighbor should surface when it is actually shown (the
        // error builder below), not as a stray exception during a swipe.
        onError: (_, _) {},
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photo = widget.photos[_index];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          '${_index + 1} / ${widget.photos.length}',
          style: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
        ),
        actions: [
          IconButton(
            tooltip: 'Photo info',
            onPressed: () => showPhotoInfoSheet(context, photo),
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.photos.length,
        onPageChanged: (index) {
          setState(() => _index = index);
          _precacheNeighbors(index);
        },
        itemBuilder: (context, index) {
          final file = widget.photos[index].file;
          return InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: Center(
              child: Image(
                image: _providerFor(file),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white54,
                  size: 48,
                ),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Text(
            photo.fileName,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
          ),
        ),
      ),
    );
  }
}
