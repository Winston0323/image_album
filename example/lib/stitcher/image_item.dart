import 'dart:typed_data';

class ImageItem {
  final Uint8List bytes; // 图片原始字节（全平台可用）
  final String path; // 文件路径（仅 native 有实际路径，web 为文件名）
  final String name;
  Uint8List? thumbnailBytes;
  double? thumbWidth;
  double? thumbHeight;
  int? originalWidth;
  int? originalHeight;

  ImageItem({
    required this.bytes,
    required this.path,
    required this.name,
    this.thumbnailBytes,
    this.thumbWidth,
    this.thumbHeight,
    this.originalWidth,
    this.originalHeight,
  });

  /// 返回简化比例字符串，如 "16:9" "4:3" "1:1"
  String get aspectRatioLabel {
    final w = originalWidth ?? thumbWidth?.round();
    final h = originalHeight ?? thumbHeight?.round();
    if (w == null || h == null || w <= 0 || h <= 0) return '';
    return _simplifyRatio(w, h);
  }

  static String _simplifyRatio(int w, int h) {
    int a = w, b = h;
    while (b != 0) {
      final t = b;
      b = a % b;
      a = t;
    }
    final g = a;
    final nw = w ~/ g, nh = h ~/ g;
    const map = <String, String>{
      '1:1': '1:1',
      '4:3': '4:3',
      '3:4': '3:4',
      '16:9': '16:9',
      '9:16': '9:16',
      '3:2': '3:2',
      '2:3': '2:3',
      '5:4': '5:4',
      '4:5': '4:5',
    };
    final key = '$nw:$nh';
    if (map.containsKey(key)) return map[key]!;
    if (nw > 50 || nh > 50) {
      final r = w / h;
      if ((r - 1.0).abs() < 0.02) return '1:1';
      if ((r - 4 / 3).abs() < 0.03) return '4:3';
      if ((r - 3 / 4).abs() < 0.03) return '3:4';
      if ((r - 16 / 9).abs() < 0.03) return '16:9';
      if ((r - 9 / 16).abs() < 0.03) return '9:16';
      if ((r - 3 / 2).abs() < 0.03) return '3:2';
      if ((r - 2 / 3).abs() < 0.03) return '2:3';
    }
    return key;
  }
}

enum StitchMode { horizontal, vertical }
