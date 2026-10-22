import 'dart:ui' as ui;

import 'package:exif/exif.dart';
import 'package:flutter/material.dart';

import 'album_photo.dart';

/// Everything the info sheet shows about one local photo, gathered from the
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
    // Not decodable — the sheet simply shows no dimensions.
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
    // The file's modification time is the fallback when the EXIF block
    // carries no capture date.
    shotDate: _exifDate(tags['EXIF DateTimeOriginal']) ?? photo.takenAt,
    focalLength: _exifFocalLength(tags['EXIF FocalLength']),
    lensModel: tags['EXIF LensModel']?.printable.trim(),
  );
}

DateTime? _exifDate(IfdTag? tag) {
  final raw = tag?.printable.trim();
  if (raw == null) return null;
  // EXIF writes 'YYYY:MM:DD HH:MM:SS' — colons in the date part too.
  final match = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
      .firstMatch(raw);
  if (match == null) return null;
  return DateTime(
    int.parse(match[1]!),
    int.parse(match[2]!),
    int.parse(match[3]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
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

/// Opens the bottom sheet with [photo]'s details.
Future<void> showPhotoInfoSheet(BuildContext context, AlbumPhoto photo) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _PhotoInfoSheet(photo: photo),
  );
}

class _PhotoInfoSheet extends StatefulWidget {
  const _PhotoInfoSheet({required this.photo});

  final AlbumPhoto photo;

  @override
  State<_PhotoInfoSheet> createState() => _PhotoInfoSheetState();
}

class _PhotoInfoSheetState extends State<_PhotoInfoSheet> {
  // Held onto rather than created in build, so sheet rebuilds (keyboard,
  // metrics changes) do not re-read the file over and over.
  late final Future<PhotoInfo> _info = loadPhotoInfo(widget.photo);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PhotoInfo>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        if (info == null) {
          return const SizedBox(
            height: 160,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.fileName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                _InfoRow(label: 'Size', value: _formatBytes(info.byteSize)),
                if (info.width != null && info.height != null)
                  _InfoRow(
                    label: 'Dimensions',
                    value: '${info.width} × ${info.height}'
                        ' (${_megapixels(info.width!, info.height!)} MP)',
                  ),
                if (info.shotDate != null)
                  _InfoRow(
                    label: 'Shot date',
                    value: _formatDate(info.shotDate!),
                  ),
                if (info.focalLength != null)
                  _InfoRow(label: 'Focal length', value: info.focalLength!),
                if (info.lensModel case final lens? when lens.isNotEmpty)
                  _InfoRow(label: 'Lens', value: lens),
                _InfoRow(label: 'Path', value: info.path, selectable: true),
              ],
            ),
          ),
        );
      },
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
    required this.label,
    required this.value,
    this.selectable = false,
  });

  final String label;
  final String value;

  /// The path row is selectable so it can be copied out.
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueStyle = theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            ),
          ),
          Expanded(
            child: selectable
                ? SelectableText(value, style: valueStyle)
                : Text(value, style: valueStyle),
          ),
        ],
      ),
    );
  }
}
