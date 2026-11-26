// PNG 软编码 — 用 `image` 包把 RGBA 编码为 PNG，突破 GPU 纹理上限。
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 纯 Dart PNG 编码（用 `image` 包，突破 GPU 纹理上限）。
///
/// 在后台 isolate 里编码：长图的 deflate 是整个保存里最慢的一步，放在
/// worker 上跑，UI isolate 可以继续画进度条。RGBA 缓冲区用
/// [TransferableTypedData] 零拷贝移交，避免在 UI isolate 上同步复制。
Future<Uint8List> encodeRgbaToPng(int w, int h, Uint8List rgba) {
  final transfer = TransferableTypedData.fromList([rgba]);
  return Isolate.run(() {
    final pixels = transfer.materialize().asUint8List();
    final image = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: pixels.buffer,
      numChannels: 4,
    );
    return Uint8List.fromList(img.encodePng(image));
  });
}
