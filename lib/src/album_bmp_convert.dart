import 'dart:io';

import 'package:bmp2tif_app/convert/convert_core.dart';
import 'package:bmp2tif_app/tiff/tiff_writer.dart';
import 'package:path/path.dart' as p;

/// Lists `.bmp` / `.BMP` files under [folder], skipping hidden names.
Future<List<String>> albumListBmpFiles(String folder) async {
  final root = Directory(folder);
  if (!await root.exists()) return const [];
  final found = <String>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (name.startsWith('.')) continue;
    final ext = p.extension(name).toLowerCase();
    if (ext == '.bmp') found.add(entity.path);
  }
  found.sort();
  return found;
}

/// Converts each BMP with Bmp2Tif defaults (ZIP, interleaved, no pyramid),
/// writes a sibling `.tif`, then deletes the BMP on success.
Future<AlbumBmpConvertResult> albumConvertBmpsToTif({
  required List<String> bmpPaths,
  void Function(String status)? onStatus,
  bool deleteBmp = true,
}) async {
  var ok = 0;
  var failed = 0;
  final errors = <String>[];

  for (var i = 0; i < bmpPaths.length; i++) {
    final bmpPath = bmpPaths[i];
    final name = p.basename(bmpPath);
    onStatus?.call('Converting ${i + 1} of ${bmpPaths.length}: $name');
    try {
      final bytes = await File(bmpPath).readAsBytes();
      final tiff = await convertBmpToTiffBytes(
        bmpBytes: bytes,
        compression: TiffCompression.zip,
        pixelOrder: PixelOrder.interleaved,
        imagePyramid: false,
        jpegQuality: 90,
      );
      final out = await _uniqueTifPath(bmpPath);
      await File(out).writeAsBytes(tiff, flush: true);
      if (deleteBmp) {
        await File(bmpPath).delete();
      }
      ok++;
    } on Object catch (error) {
      failed++;
      errors.add('$name: $error');
    }
  }

  return AlbumBmpConvertResult(
    converted: ok,
    failed: failed,
    errors: errors,
  );
}

class AlbumBmpConvertResult {
  const AlbumBmpConvertResult({
    required this.converted,
    required this.failed,
    required this.errors,
  });

  final int converted;
  final int failed;
  final List<String> errors;
}

Future<String> _uniqueTifPath(String bmpPath) async {
  final dir = p.dirname(bmpPath);
  final base = p.basenameWithoutExtension(bmpPath);
  var candidate = p.join(dir, '$base.tif');
  var n = 2;
  while (await FileSystemEntity.type(candidate) !=
      FileSystemEntityType.notFound) {
    candidate = p.join(dir, '${base}_$n.tif');
    n++;
  }
  return candidate;
}
