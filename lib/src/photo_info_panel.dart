import 'dart:async';
import 'dart:ui' as ui;

import 'package:exif/exif.dart';
import 'package:flutter/material.dart';

import 'album_photo.dart';

/// Everything the info panel shows about one local photo, gathered from the
/// file itself: size on disk, pixel dimensions from the image header, and
/// shot details from the JPEG's EXIF block.
class PhotoInfo {
  const PhotoInfo({
    required this.fileName,
    required this.path,
    required this.byteSize,
    this.width,
    this.height,
    this.shotDate,
    this.focalLength,
    this.lensModel,
  });

  final String fileName;
  final String path;
  final int byteSize;
  final int? width;
  final int? height;
  final DateTime? shotDate;

  /// Already formatted, e.g. `55 mm`.
  final String? focalLength;

  final String? lensModel;
}

Future<PhotoInfo> loadPhotoInfo(AlbumPhoto photo) async {
  final bytes = await photo.file.readAsBytes();

  // Dimensions come from the image header alone — no need to pay for a full
  // decode of a large frame just to print its pixel size.
  int? width;
  int? height;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    width = descriptor.width;
    height = descriptor.height;
    descriptor.dispose();
    buffer.dispose();
  } catch (_) {
    // Not decodable — the panel simply shows no dimensions.
  }

  Map<String, IfdTag> tags = const {};
  try {
    tags = await readExifFromBytes(bytes);
  } catch (_) {
    // No EXIF block, or an unreadable one — shot details fall back below.
  }

  return PhotoInfo(
    fileName: photo.fileName,
    path: photo.file.path,
    byteSize: bytes.length,
    width: width,
    height: height,
    // Same date the grid is sorted by: the capture time when the file has
    // one, otherwise the modification time [AlbumPhoto.takenAt] already holds.
    shotDate: photo.takenAt,
    focalLength: _exifFocalLength(tags['EXIF FocalLength']),
    lensModel: tags['EXIF LensModel']?.printable.trim(),
  );
}

String? _exifFocalLength(IfdTag? tag) {
  final raw = tag?.printable.trim();
  if (raw == null || raw.isEmpty) return null;

  double? mm;
  final parts = raw.split('/');
  if (parts.length == 2) {
    // Stored as a rational, e.g. '550/10' for 55mm.
    final numerator = double.tryParse(parts[0]);
    final denominator = double.tryParse(parts[1]);
    if (numerator != null && denominator != null && denominator != 0) {
      mm = numerator / denominator;
    }
  } else {
    mm = double.tryParse(raw);
  }

  if (mm == null) return '$raw mm';
  final whole = mm.truncateToDouble() == mm;
  return '${mm.toStringAsFixed(whole ? 0 : 1)} mm';
}

/// How long the panel waits on a photo before reading its file. Swiping
/// quickly through a burst then reads only the shot that was landed on.
const Duration _loadDelay = Duration(milliseconds: 150);

/// The details of [photo], laid out as a column for a sidebar.
///
/// Give it a new [photo] and it swaps to that one, so it can stay open while
/// the viewer pages through the album.
class PhotoInfoPanel extends StatefulWidget {
  const PhotoInfoPanel({super.key, required this.photo, required this.onClose});

  final AlbumPhoto photo;
  final VoidCallback onClose;

  @override
  State<PhotoInfoPanel> createState() => _PhotoInfoPanelState();
}

class _PhotoInfoPanelState extends State<PhotoInfoPanel> {
  // Held onto rather than created in build, so rebuilds (resizing the
  // window, say) do not re-read the file over and over.
  Future<PhotoInfo>? _info;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _info = loadPhotoInfo(widget.photo);
  }

  @override
  void didUpdateWidget(PhotoInfoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo.file.path == widget.photo.file.path) return;
    _timer?.cancel();
    final photo = widget.photo;
    _info = null;
    _timer = Timer(_loadDelay, () {
      if (!mounted) return;
      setState(() {
        _info = loadPhotoInfo(photo);
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surface,
      child: SafeArea(
        left: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Info',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close info',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<PhotoInfo>(
                // A builder keeps the last data it had when its future is
                // swapped, which would show the previous photo's details
                // under the new photo. A fresh one per photo starts empty.
                key: ValueKey(widget.photo.file.path),
                future: _info,
                builder: (context, snapshot) {
                  final info = snapshot.data;
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: info == null
                        ? const Center(
                            key: ValueKey('loading'),
                            child: CircularProgressIndicator(),
                          )
                        : _InfoList(key: ValueKey(info.path), info: info),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoList extends StatelessWidget {
  const _InfoList({super.key, required this.info});

  final PhotoInfo info;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            info.fileName,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          _InfoRow(
            icon: Icons.sd_storage_outlined,
            label: 'Size',
            value: _formatBytes(info.byteSize),
          ),
          if (info.width != null && info.height != null)
            _InfoRow(
              icon: Icons.aspect_ratio_rounded,
              label: 'Dimensions',
              value:
                  '${info.width} × ${info.height}'
                  ' (${_megapixels(info.width!, info.height!)} MP)',
            ),
          if (info.shotDate != null)
            _InfoRow(
              icon: Icons.calendar_today_outlined,
              label: 'Shot date',
              value: _formatDate(info.shotDate!),
            ),
          if (info.focalLength != null)
            _InfoRow(
              icon: Icons.center_focus_strong_outlined,
              label: 'Focal length',
              value: info.focalLength!,
            ),
          if (info.lensModel case final lens? when lens.isNotEmpty)
            _InfoRow(icon: Icons.camera_outlined, label: 'Lens', value: lens),
          _InfoRow(
            icon: Icons.folder_outlined,
            label: 'Path',
            value: info.path,
            selectable: true,
          ),
        ],
      ),
    );
  }

  static String _megapixels(int width, int height) =>
      (width * height / 1000000).toStringAsFixed(1);

  static String _formatDate(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.selectable = false,
  });

  final IconData icon;
  final String label;
  final String value;

  /// The path row is selectable so it can be copied out.
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 1),
                selectable
                    ? SelectableText(value, style: theme.textTheme.bodyMedium)
                    : Text(value, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
