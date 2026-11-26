import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

/// Deterministic offline [TileProvider] for widget tests and golden screenshots.
///
/// Generates a clean pale-sage cartographic grid tile PNG in memory once (zero
/// network access, zero retry timers, deterministic across platforms).
class FakeTileProvider extends TileProvider {
  FakeTileProvider({super.headers});

  static final Uint8List _gridTilePng = _encodeGridTilePng(size: 64);

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return MemoryImage(_gridTilePng);
  }
}

Uint8List _encodeGridTilePng({required int size}) {
  // Raw RGBA scanlines: 1 filter byte (0 = None) + size * 4 RGBA bytes per row.
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < size; y++) {
    raw.addByte(0);
    final isMajorY = y == 0;
    final isMinorY = y == size ~/ 2;
    for (var x = 0; x < size; x++) {
      final isMajorX = x == 0;
      final isMinorX = x == size ~/ 2;
      if (isMajorX || isMajorY) {
        // Subtle outer tile grid line (#CFDCD0).
        raw.add(const [0xCF, 0xDC, 0xD0, 0xFF]);
      } else if (isMinorX || isMinorY) {
        // Very faint inner subdivision line (#DFEAE0).
        raw.add(const [0xDF, 0xEA, 0xE0, 0xFF]);
      } else {
        // Soft aviation-chart land tint (#EDF3EA).
        raw.add(const [0xED, 0xF3, 0xEA, 0xFF]);
      }
    }
  }

  final compressed = Uint8List.fromList(zlib.encode(raw.takeBytes()));
  final out = BytesBuilder(copy: false);
  // PNG signature
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  // IHDR chunk (width, height, 8-bit, RGBA=6, compression=0, filter=0, interlace=0)
  final ihdr = ByteData(13)
    ..setUint32(0, size)
    ..setUint32(4, size)
    ..setUint8(8, 8)
    ..setUint8(9, 6)
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  _writeChunk(out, 'IHDR', ihdr.buffer.asUint8List());
  _writeChunk(out, 'IDAT', compressed);
  _writeChunk(out, 'IEND', Uint8List(0));
  return out.takeBytes();
}

void _writeChunk(BytesBuilder out, String type, Uint8List data) {
  final len = ByteData(4)..setUint32(0, data.length);
  out.add(len.buffer.asUint8List());
  final typeBytes = Uint8List.fromList(type.codeUnits);
  out.add(typeBytes);
  out.add(data);
  final crc = _crc32(typeBytes, data);
  final crcBytes = ByteData(4)..setUint32(0, crc);
  out.add(crcBytes.buffer.asUint8List());
}

int _crc32(Uint8List a, Uint8List b) {
  var crc = 0xFFFFFFFF;
  void update(Uint8List bytes) {
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        if ((crc & 1) != 0) {
          crc = (crc >>> 1) ^ 0xEDB88320;
        } else {
          crc = crc >>> 1;
        }
      }
    }
  }

  update(a);
  update(b);
  return (~crc) & 0xFFFFFFFF;
}
