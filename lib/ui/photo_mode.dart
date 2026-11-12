import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/radar_source.dart';
import '../core/storage.dart';
import 'theme.dart';

/// "Photo mode": turn the current polar frame into a night-vision style still.
///
/// Pipeline: bilinear polar->Cartesian resample of the square inscribed in
/// the range circle, percentile histogram stretch, unsharp mask, gamma,
/// green image-intensifier palette, vignette, film grain, scan lines, HUD.
class PhotoMode {
  static Future<Uint8List> capture(PolarFrame f,
      {int size = 640, String tag = 'SIM'}) async {
    final n = size * size;
    final img = Float32List(n);
    final beams = f.beams, bins = f.bins;
    final vals = f.values;
    final half = f.maxRange / math.sqrt2; // inscribed square half-side, m
    final c = (size - 1) / 2.0;

    // 1. Resample.
    for (int y = 0; y < size; y++) {
      final wy = (y - c) / c * half;
      for (int x = 0; x < size; x++) {
        final wx = (x - c) / c * half;
        final r = math.sqrt(wx * wx + wy * wy) / f.maxRange * bins - 0.5;
        double a = math.atan2(wy, wx) / (2 * math.pi) * beams;
        if (a < 0) a += beams;
        final b0 = a.floor(), k0 = r.floor();
        final fb = a - b0, fk = r - k0;
        final b1 = (b0 + 1) % beams;
        final ka = k0 < 0 ? 0 : (k0 >= bins ? bins - 1 : k0);
        final kb = k0 + 1 >= bins ? bins - 1 : (k0 + 1 < 0 ? 0 : k0 + 1);
        final bb = b0 % beams;
        final v00 = vals[bb * bins + ka], v01 = vals[bb * bins + kb];
        final v10 = vals[b1 * bins + ka], v11 = vals[b1 * bins + kb];
        img[y * size + x] = (v00 * (1 - fk) + v01 * fk) * (1 - fb) +
            (v10 * (1 - fk) + v11 * fk) * fb;
      }
    }

    // 2. Histogram stretch between the 10th and 99.7th percentiles.
    final hist = Int32List(256);
    for (int i = 0; i < n; i++) {
      int h = (img[i] * 255).toInt();
      if (h < 0) h = 0;
      if (h > 255) h = 255;
      hist[h]++;
    }
    int lo = 0, hi = 255, acc = 0;
    for (int i = 0; i < 256; i++) {
      acc += hist[i];
      if (acc < n * 0.10) lo = i;
      if (acc < n * 0.997) hi = i;
    }
    final lof = lo / 255.0;
    final span = math.max(0.05, (hi - lo) / 255.0);
    for (int i = 0; i < n; i++) {
      final v = (img[i] - lof) / span;
      img[i] = v < 0 ? 0.0 : (v > 1 ? 1.0 : v);
    }

    // 3. Unsharp mask (separable box blur, radius 3).
    final tmp = Float32List(n), blur = Float32List(n);
    const rad = 3;
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        double s = 0;
        for (int k = -rad; k <= rad; k++) {
          final xx = x + k;
          s += img[y * size + (xx < 0 ? 0 : (xx >= size ? size - 1 : xx))];
        }
        tmp[y * size + x] = s / (2 * rad + 1);
      }
    }
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        double s = 0;
        for (int k = -rad; k <= rad; k++) {
          final yy = y + k;
          s += tmp[(yy < 0 ? 0 : (yy >= size ? size - 1 : yy)) * size + x];
        }
        blur[y * size + x] = s / (2 * rad + 1);
      }
    }

    // 4. Tone, palette, vignette, grain, scan lines.
    final bytes = Uint8List(n * 4);
    final rng = math.Random(f.time.toInt() + 11);
    for (int y = 0; y < size; y++) {
      final ny = (y - c) / c;
      final line = (y % 3 == 0) ? 0.88 : 1.0;
      for (int x = 0; x < size; x++) {
        final i = y * size + x;
        final nx = (x - c) / c;
        double v = img[i] + 0.9 * (img[i] - blur[i]) + 0.35 * blur[i];
        v = v < 0 ? 0.0 : (v > 1 ? 1.0 : v);
        v = math.pow(v, 0.8).toDouble();
        final vig = 1 - 0.55 * math.min(1.0, (nx * nx + ny * ny) * 0.75);
        v = (v * vig + (rng.nextDouble() - 0.5) * 0.07 + 0.04) * line;
        v = v < 0 ? 0.0 : (v > 1 ? 1.0 : v);
        final hot = v * v * v;
        bytes[i * 4] = (hot * 200 + 6).toInt();
        bytes[i * 4 + 1] = (20 + v * 235).toInt();
        bytes[i * 4 + 2] = (hot * 150 + 8).toInt();
        bytes[i * 4 + 3] = 255;
      }
    }

    // 5. HUD and PNG encode.
    final base = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        bytes, size, size, ui.PixelFormat.rgba8888, base.complete);
    final baseImg = await base.future;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final s = size.toDouble();
    canvas.drawImage(baseImg, Offset.zero, Paint());
    final hud = Paint()
      ..color = const Color(0xB3C8FFC0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    const m = 18.0, l = 34.0;
    for (final corner in [
      [m, m, 1.0, 1.0],
      [s - m, m, -1.0, 1.0],
      [m, s - m, 1.0, -1.0],
      [s - m, s - m, -1.0, -1.0],
    ]) {
      final p = Offset(corner[0], corner[1]);
      canvas.drawLine(p, p + Offset(l * corner[2], 0), hud);
      canvas.drawLine(p, p + Offset(0, l * corner[3]), hud);
    }
    canvas.drawLine(Offset(s / 2 - 10, s / 2), Offset(s / 2 + 10, s / 2), hud);
    canvas.drawLine(Offset(s / 2, s / 2 - 10), Offset(s / 2, s / 2 + 10), hud);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    paintLabel(canvas, 'DARKSIGHT  $tag', const Offset(28, 26),
        const Color(0xE6D8FFD0),
        size: 15);
    paintLabel(
        canvas,
        '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}   '
        'FOV ${(2 * half).toStringAsFixed(1)} m',
        Offset(28, s - 44),
        const Color(0xE6D8FFD0),
        size: 13);
    final out = await rec.endRecording().toImage(size, size);
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    baseImg.dispose();
    out.dispose();
    return png!.buffer.asUint8List();
  }

  /// Capture, preview, and offer to share.
  static Future<void> show(BuildContext context, PolarFrame frame,
      {String tag = 'SIM'}) async {
    final png = await capture(frame, tag: tag);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        contentPadding: const EdgeInsets.all(12),
        content: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.memory(png, gaplessPlayback: true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('CLOSE'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.ios_share, size: 18),
            label: const Text('SHARE PNG'),
            onPressed: () async {
              try {
                final name =
                    'darksight_${DateTime.now().millisecondsSinceEpoch}.png';
                if (kIsWeb) {
                  // No file system in the browser: share or download bytes.
                  await Share.shareXFiles(
                      [XFile.fromData(png, mimeType: 'image/png', name: name)],
                      text: 'DarkSight capture');
                  return;
                }
                final dir = await getTemporaryDirectory();
                final path = '${dir.path}/$name';
                await File(path).writeAsBytes(png, flush: true);
                await Storage.recordFrame(path);
                await Share.shareXFiles([XFile(path, mimeType: 'image/png')],
                    text: 'DarkSight capture');
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Share failed: $e')));
                }
              }
            },
          ),
        ],
      ),
    );
  }
}
