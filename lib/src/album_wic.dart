import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'album_raw.dart';

/// Pixels of [file] decoded by the Windows image codec, the same one the
/// Photos app uses for a raw. Null when the codec cannot read [file].
///
/// The bytes are 32-bit BGRA, top to bottom, [width] * 4 bytes a row.
typedef AlbumWicImage = ({int width, int height, Uint8List pixels});

/// A raw or TIFF drawn at the size Windows itself decodes it to.
///
/// The embedded JPEG inside an ARW is only a preview. Windows Photos decodes
/// the sensor data, which is what this asks the Windows codec for.
@immutable
class AlbumWindowsRawImage extends ImageProvider<AlbumWindowsRawImage> {
  const AlbumWindowsRawImage(this.file);

  final File file;

  @override
  Future<AlbumWindowsRawImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AlbumWindowsRawImage>(this);

  @override
  ImageStreamCompleter loadImage(
    AlbumWindowsRawImage key,
    ImageDecoderCallback decode,
  ) {
    return _RawImageCompleter(_load(key, decode));
  }

  Future<ui.Image> _load(
    AlbumWindowsRawImage key,
    ImageDecoderCallback decode,
  ) async {
    final path = key.file.absolute.path;
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
    // No Windows codec for this file: the embedded preview is all there is.
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
      other is AlbumWindowsRawImage && other.file.path == file.path;

  @override
  int get hashCode => file.path.hashCode;

  @override
  String toString() => 'AlbumWindowsRawImage("${file.path}")';
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
          context: ErrorDescription('while decoding the raw photo'),
        );
      },
    );
  }
}

/// Decodes [path] with the Windows Imaging Component. Safe to call from an
/// isolate. Null when the file cannot be decoded.
AlbumWicImage? albumWicBgra(String path) {
  if (!Platform.isWindows) return null;
  return _WicSession().decode(path);
}

class _WicSession {
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final DynamicLibrary _ole32 = DynamicLibrary.open('ole32.dll');

  static final Pointer<Void> _heap = _kernel32
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      )();

  static final Pointer<Void> Function(Pointer<Void>, int, int) _heapAlloc =
      _kernel32.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');

  static final int Function(Pointer<Void>, int, Pointer<Void>) _heapFree =
      _kernel32.lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');

  static final int Function(Pointer<Void>, int) _coInitializeEx = _ole32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('CoInitializeEx');

  static final void Function() _coUninitialize = _ole32
      .lookupFunction<Void Function(), void Function()>('CoUninitialize');

  static final int Function(
    Pointer<Uint8>,
    Pointer<Void>,
    int,
    Pointer<Uint8>,
    Pointer<Pointer<Void>>,
  )
  _coCreate = _ole32
      .lookupFunction<
        Int32 Function(
          Pointer<Uint8>,
          Pointer<Void>,
          Uint32,
          Pointer<Uint8>,
          Pointer<Pointer<Void>>,
        ),
        int Function(
          Pointer<Uint8>,
          Pointer<Void>,
          int,
          Pointer<Uint8>,
          Pointer<Pointer<Void>>,
        )
      >('CoCreateInstance');

  static const int _heapZero = 0x8;
  static const int _coinitMta = 0;
  static const int _clsctxInproc = 1;
  static const int _genericRead = 0x80000000;
  static const int _changedMode = 0x80010106;

  // CLSID_WICImagingFactory1, so the vtable is the original factory.
  static final Pointer<Uint8> _factoryClsid = _guid(
    0xcacaf262,
    0x9370,
    0x4615,
    const [0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a],
  );

  static final Pointer<Uint8> _factoryIid = _guid(
    0xec5ec8a9,
    0xc395,
    0x4314,
    const [0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70],
  );

  // GUID_WICPixelFormat32bppBGRA.
  static final Pointer<Uint8> _bgra = _guid(0x6fddc324, 0x4e03, 0x4bfe, const [
    0xb1,
    0x85,
    0x3d,
    0x77,
    0x76,
    0x8d,
    0xc9,
    0x0f,
  ]);

  AlbumWicImage? decode(String path) {
    final init = _coInitializeEx(nullptr, _coinitMta);
    final uninit = init != _changedMode && init >= 0;
    Pointer<Void>? factory;
    Pointer<Void>? decoder;
    Pointer<Void>? frame;
    Pointer<Void>? converter;
    Pointer<Uint8>? pixels;
    try {
      if (init < 0 && init != _changedMode) return null;
      final created = _out();
      final hr = _coCreate(
        _factoryClsid,
        nullptr,
        _clsctxInproc,
        _factoryIid,
        created,
      );
      if (hr < 0) return null;
      factory = created.value;
      _free(created);

      final wide = _utf16(path);
      final decoded = _out();
      try {
        final open =
            _slot<
                  Int32 Function(
                    Pointer<Void>,
                    Pointer<Uint16>,
                    Pointer<Uint8>,
                    Uint32,
                    Uint32,
                    Pointer<Pointer<Void>>,
                  )
                >(factory, 3)
                .asFunction<
                  int Function(
                    Pointer<Void>,
                    Pointer<Uint16>,
                    Pointer<Uint8>,
                    int,
                    int,
                    Pointer<Pointer<Void>>,
                  )
                >();
        if (open(factory, wide, nullptr, _genericRead, 0, decoded) < 0) {
          return null;
        }
      } finally {
        _free(wide);
      }
      decoder = decoded.value;
      _free(decoded);

      final framed = _out();
      final getFrame =
          _slot<Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>)>(
                decoder,
                13,
              )
              .asFunction<
                int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
              >();
      if (getFrame(decoder, 0, framed) < 0) return null;
      frame = framed.value;
      _free(framed);

      final widthPtr = _u32();
      final heightPtr = _u32();
      final getSize =
          _slot<
                Int32 Function(Pointer<Void>, Pointer<Uint32>, Pointer<Uint32>)
              >(frame, 3)
              .asFunction<
                int Function(Pointer<Void>, Pointer<Uint32>, Pointer<Uint32>)
              >();
      final sized = getSize(frame, widthPtr, heightPtr);
      final width = widthPtr.value;
      final height = heightPtr.value;
      _free(widthPtr);
      _free(heightPtr);
      if (sized < 0 || width == 0 || height == 0) return null;
      if (width > 20000 || height > 20000 || width * height > 100000000) {
        return null;
      }

      final converted = _out();
      final createConverter =
          _slot<Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>(
            factory,
            10,
          ).asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>();
      if (createConverter(factory, converted) < 0) return null;
      converter = converted.value;
      _free(converted);

      final initialize =
          _slot<
                Int32 Function(
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Uint8>,
                  Uint32,
                  Pointer<Void>,
                  Double,
                  Uint32,
                )
              >(converter, 8)
              .asFunction<
                int Function(
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Uint8>,
                  int,
                  Pointer<Void>,
                  double,
                  int,
                )
              >();
      // Dither none, no palette, straight BGRA.
      if (initialize(converter, frame, _bgra, 0, nullptr, 0, 0) < 0) {
        return null;
      }

      final stride = width * 4;
      final size = stride * height;
      pixels = _heapAlloc(_heap, _heapZero, size).cast<Uint8>();
      if (pixels == nullptr) return null;
      final copy =
          _slot<
                Int32 Function(
                  Pointer<Void>,
                  Pointer<Void>,
                  Uint32,
                  Uint32,
                  Pointer<Uint8>,
                )
              >(converter, 7)
              .asFunction<
                int Function(
                  Pointer<Void>,
                  Pointer<Void>,
                  int,
                  int,
                  Pointer<Uint8>,
                )
              >();
      if (copy(converter, nullptr, stride, size, pixels) < 0) return null;
      final bytes = Uint8List.fromList(pixels.asTypedList(size));
      return (width: width, height: height, pixels: bytes);
    } finally {
      if (pixels != null && pixels != nullptr) _free(pixels);
      _release(converter);
      _release(frame);
      _release(decoder);
      _release(factory);
      if (uninit) _coUninitialize();
    }
  }

  static void _release(Pointer<Void>? object) {
    if (object == null || object == nullptr) return;
    _slot<Uint32 Function(Pointer<Void>)>(
      object,
      2,
    ).asFunction<int Function(Pointer<Void>)>()(object);
  }

  static Pointer<NativeFunction<S>> _slot<S extends Function>(
    Pointer<Void> object,
    int index,
  ) {
    return object.cast<Pointer<Pointer<NativeFunction<S>>>>().value[index];
  }

  static Pointer<Pointer<Void>> _out() =>
      _heapAlloc(_heap, _heapZero, sizeOf<IntPtr>()).cast();

  static Pointer<Uint32> _u32() => _heapAlloc(_heap, _heapZero, 4).cast();

  static void _free(Pointer<NativeType> pointer) {
    _heapFree(_heap, 0, pointer.cast());
  }

  static Pointer<Uint16> _utf16(String value) {
    final units = value.codeUnits;
    final data = _heapAlloc(
      _heap,
      _heapZero,
      (units.length + 1) * 2,
    ).cast<Uint16>();
    final view = data.asTypedList(units.length + 1);
    for (var i = 0; i < units.length; i++) {
      view[i] = units[i];
    }
    return data;
  }

  static Pointer<Uint8> _guid(int d1, int d2, int d3, List<int> d4) {
    final data = ByteData(16);
    data.setUint32(0, d1, Endian.little);
    data.setUint16(4, d2, Endian.little);
    data.setUint16(6, d3, Endian.little);
    for (var i = 0; i < 8; i++) {
      data.setUint8(8 + i, d4[i]);
    }
    final raw = _heapAlloc(_heap, _heapZero, 16).cast<Uint8>();
    raw.asTypedList(16).setAll(0, data.buffer.asUint8List());
    return raw;
  }
}
