import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;

import 'album_raw.dart';
import 'album_wic.dart';

/// 8-bit RGBA pixels from LibRaw, width * height * 4 bytes.
typedef AlbumLibRawImageData = ({int width, int height, Uint8List pixels});

/// A camera raw drawn by [LibRaw](https://www.libraw.org/), which develops the
/// sensor data instead of the small JPEG preview stored in the file.
@immutable
class AlbumLibRawImage extends ImageProvider<AlbumLibRawImage> {
  const AlbumLibRawImage(this.file);

  final File file;

  @override
  Future<AlbumLibRawImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AlbumLibRawImage>(this);

  @override
  ImageStreamCompleter loadImage(
    AlbumLibRawImage key,
    ImageDecoderCallback decode,
  ) {
    return _RawImageCompleter(_load(key, decode));
  }

  Future<ui.Image> _load(
    AlbumLibRawImage key,
    ImageDecoderCallback decode,
  ) async {
    final path = key.file.absolute.path;
    final developed = await Isolate.run(() => albumLibRawRgba(path));
    if (developed != null) {
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        developed.pixels,
        developed.width,
        developed.height,
        ui.PixelFormat.rgba8888,
        done.complete,
        rowBytes: developed.width * 4,
      );
      return done.future;
    }
    // LibRaw missing or this camera is unsupported: Windows Photos' codec,
    // then the embedded preview.
    if (Platform.isWindows) {
      final wic = await Isolate.run(() => albumWicBgra(path));
      if (wic != null) {
        final done = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          wic.pixels,
          wic.width,
          wic.height,
          ui.PixelFormat.bgra8888,
          done.complete,
          rowBytes: wic.width * 4,
        );
        return done.future;
      }
    }
    final bytes = await Isolate.run(() => albumDecodableBytes(path));
    if (bytes == null) {
      throw FileSystemException('Nothing to show in this file', path);
    }
    final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AlbumLibRawImage && other.file.path == file.path;

  @override
  int get hashCode => file.path.hashCode;

  @override
  String toString() => 'AlbumLibRawImage("${file.path}")';
}

class _RawImageCompleter extends ImageStreamCompleter {
  _RawImageCompleter(Future<ui.Image> image) {
    image.then<void>(
      (ui.Image result) {
        setImage(ImageInfo(image: result, scale: 1));
      },
      onError: (Object error, StackTrace stack) {
        reportError(
          exception: error,
          stack: stack,
          context: ErrorDescription('while developing the raw photo'),
        );
      },
    );
  }
}

/// The JPEG preview the raw names, the picture a viewer shows first.
///
/// Imaging Edge opens that JPEG (`OpenJPEGFileAtFirst`) before it develops
/// the sensor. LibRaw's thumbnail is that same JPEG. Null when there is none
/// or it is not a JPEG. Safe to call from an isolate.
Uint8List? albumLibRawThumbBytes(String path) {
  final lib = _libraw();
  if (lib == null) return null;
  final init = lib
      .lookupFunction<
        Pointer<Void> Function(Uint32),
        Pointer<Void> Function(int)
      >('libraw_init');
  final open = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint16>),
        int Function(Pointer<Void>, Pointer<Uint16>)
      >('libraw_open_wfile');
  final unpackThumb = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('libraw_unpack_thumb');
  final makeThumb = lib
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>, Pointer<Int32>),
        Pointer<Uint8> Function(Pointer<Void>, Pointer<Int32>)
      >('libraw_dcraw_make_mem_thumb');
  final clear = lib
      .lookupFunction<
        Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)
      >('libraw_dcraw_clear_mem');
  final close = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('libraw_close');

  final raw = init(0);
  if (raw == nullptr) return null;
  Pointer<Uint16>? wide;
  Pointer<Uint8>? image;
  try {
    wide = _utf16(path);
    if (open(raw, wide) != 0) return null;
    if (unpackThumb(raw) != 0) return null;
    final err = _heapAlloc(4).cast<Int32>();
    try {
      image = makeThumb(raw, err);
      if (image == nullptr) return null;
      final header = ByteData.sublistView(image.asTypedList(16));
      // libraw_processed_image_t: type, height, width, colors, bits, data_size.
      final type = header.getInt32(0, Endian.host);
      final dataSize = header.getUint32(12, Endian.host);
      // 1 is the JPEG the camera stored. A bitmap thumb is not that preview.
      if (type != 1 || dataSize < 4096 || dataSize > (16 << 20)) return null;
      return Uint8List.fromList((image + 16).asTypedList(dataSize));
    } finally {
      _heapFree(err);
    }
  } finally {
    if (wide != null) _heapFree(wide);
    if (image != null && image != nullptr) clear(image);
    close(raw);
  }
}

/// Develops [path] with LibRaw into 8-bit RGBA. Null when LibRaw is not
/// available or cannot read the file. Safe to call from an isolate.
AlbumLibRawImageData? albumLibRawRgba(String path) {
  final lib = _libraw();
  if (lib == null) return null;
  return _develop(lib, path);
}

DynamicLibrary? _opened;

DynamicLibrary? _libraw() {
  final cached = _opened;
  if (cached != null) return cached;
  final found = _findDll();
  if (found == null) return null;
  try {
    return _opened = DynamicLibrary.open(found);
  } on Object {
    return null;
  }
}

String? _findDll() {
  final candidates = <String>[
    p.join(p.dirname(Platform.resolvedExecutable), 'libraw.dll'),
  ];
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    candidates.add(p.join(dir.path, 'third_party', 'libraw', 'libraw.dll'));
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

AlbumLibRawImageData? _develop(DynamicLibrary lib, String path) {
  final init = lib
      .lookupFunction<
        Pointer<Void> Function(Uint32),
        Pointer<Void> Function(int)
      >('libraw_init');
  final open = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint16>),
        int Function(Pointer<Void>, Pointer<Uint16>)
      >('libraw_open_wfile');
  final setBps = lib
      .lookupFunction<
        Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)
      >('libraw_set_output_bps');
  final setColor = lib
      .lookupFunction<
        Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)
      >('libraw_set_output_color');
  final setDemosaic = lib
      .lookupFunction<
        Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)
      >('libraw_set_demosaic');
  final setNoAutoBright = lib
      .lookupFunction<
        Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)
      >('libraw_set_no_auto_bright');
  final unpack = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('libraw_unpack');
  final process = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('libraw_dcraw_process');
  final make = lib
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>, Pointer<Int32>),
        Pointer<Uint8> Function(Pointer<Void>, Pointer<Int32>)
      >('libraw_dcraw_make_mem_image');
  final clear = lib
      .lookupFunction<
        Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)
      >('libraw_dcraw_clear_mem');
  final close = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('libraw_close');

  final raw = init(0);
  if (raw == nullptr) return null;
  Pointer<Uint16>? wide;
  Pointer<Uint8>? image;
  try {
    wide = _utf16(path);
    if (open(raw, wide) != 0) return null;
    // Imaging Edge then develops the sensor itself (its own tile decoder,
    // not LibRaw). This is the open equivalent: the full sensor, camera white
    // balance (LibRaw's default), 8-bit sRGB, bilinear so it stays quick.
    setBps(raw, 8);
    setColor(raw, 1);
    setDemosaic(raw, 0);
    setNoAutoBright(raw, 1);
    if (unpack(raw) != 0) return null;
    if (process(raw) != 0) return null;
    final err = _heapAlloc(4).cast<Int32>();
    try {
      image = make(raw, err);
      if (image == nullptr) return null;
      return _copyRgba(image);
    } finally {
      _heapFree(err);
    }
  } finally {
    if (wide != null) _heapFree(wide);
    if (image != null && image != nullptr) clear(image);
    close(raw);
  }
}

/// Reads a LibRaw `libraw_processed_image_t` and copies it to RGBA.
AlbumLibRawImageData? _copyRgba(Pointer<Uint8> image) {
  final header = image.asTypedList(16);
  final data = ByteData.sublistView(header);
  final height = data.getUint16(4, Endian.host);
  final width = data.getUint16(6, Endian.host);
  final colors = data.getUint16(8, Endian.host);
  final bits = data.getUint16(10, Endian.host);
  if (width == 0 || height == 0 || colors < 3) return null;
  final pixels = width * height;
  if (pixels > 100000000) return null;
  final rgb = image + 16;
  final out = Uint8List(pixels * 4);
  if (bits == 8) {
    final source = rgb.asTypedList(pixels * colors);
    for (var i = 0, o = 0; i < source.length; i += colors, o += 4) {
      out[o] = source[i];
      out[o + 1] = source[i + 1];
      out[o + 2] = source[i + 2];
      out[o + 3] = 255;
    }
  } else if (bits == 16) {
    final source = rgb.cast<Uint16>().asTypedList(pixels * colors);
    for (var i = 0, o = 0; i < source.length; i += colors, o += 4) {
      out[o] = source[i] >> 8;
      out[o + 1] = source[i + 1] >> 8;
      out[o + 2] = source[i + 2] >> 8;
      out[o + 3] = 255;
    }
  } else {
    return null;
  }
  return (width: width, height: height, pixels: out);
}

Pointer<Uint16> _utf16(String value) {
  final units = value.codeUnits;
  final data = _heapAlloc((units.length + 1) * 2).cast<Uint16>();
  final view = data.asTypedList(units.length + 1);
  for (var i = 0; i < units.length; i++) {
    view[i] = units[i];
  }
  return data;
}

Pointer<Void> _heapAlloc(int bytes) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final heap = kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      )();
  final alloc = kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');
  return alloc(heap, 0x8, bytes);
}

void _heapFree(Pointer<NativeType> pointer) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final heap = kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      )();
  final free = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');
  free(heap, 0, pointer.cast());
}
