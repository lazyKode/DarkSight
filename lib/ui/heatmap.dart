import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Turns a small float grid (0..1) into a GPU image through a colour table,
/// optionally via a pixel->cell lookup table (-1 = transparent).
class GridImager {
  GridImager(this.width, this.height)
      : _bytes = Uint8List(width * height * 4);

  final int width, height;
  final Uint8List _bytes;
  bool busy = false;

  Future<ui.Image?> render(Float32List values, Uint32List cmap,
      {Int32List? lut}) {
    if (busy) return Future<ui.Image?>.value(null);
    final px = _bytes.buffer.asUint32List();
    final n = width * height;
    for (int p = 0; p < n; p++) {
      final idx = lut == null ? p : lut[p];
      if (idx < 0) {
        px[p] = 0;
        continue;
      }
      int ci = (values[idx] * 255).toInt();
      if (ci > 255) ci = 255;
      if (ci < 0) ci = 0;
      px[p] = cmap[ci];
    }
    busy = true;
    final done = Completer<ui.Image?>();
    ui.decodeImageFromPixels(_bytes, width, height, ui.PixelFormat.rgba8888,
        (ui.Image img) {
      busy = false;
      done.complete(img);
    });
    return done.future;
  }
}
