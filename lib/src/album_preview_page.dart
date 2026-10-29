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

  /// The file itself, at its own pixel size. Nothing is resampled before it
  /// is drawn, so the preview is the original photo fitted to the screen.
  ImageProvider _providerFor(File file) => FileImage(file);

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
            maxScale: 8,
            child: Center(
              child: Image(
                image: _providerFor(file),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                // The full photo can take a moment. Until it arrives, show
                // the same small decode the grid already has.
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) return child;
                  return Image.file(
                    file,
                    fit: BoxFit.contain,
                    cacheWidth: 240,
                    gaplessPlayback: true,
                  );
                },
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
