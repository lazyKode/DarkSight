import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/scene.dart';
import '../core/storage.dart';
import 'theme.dart';

/// Drag-and-drop 2D floor plan. Drag bodies to move, drag the round handles
/// to stretch walls or resize furniture, tap to select, bin to delete.
class FloorPlanEditor extends StatefulWidget {
  const FloorPlanEditor({
    super.key,
    required this.scene,
    required this.repaint,
    this.onPersonMoved,
    this.onPersonReleased,
  });

  final SceneController scene;
  final Listenable repaint;

  /// Called with the old and new position while a person is dragged.
  final void Function(SceneObject p, double oldX, double oldY)? onPersonMoved;
  final void Function(SceneObject p)? onPersonReleased;

  @override
  State<FloorPlanEditor> createState() => _FloorPlanEditorState();
}

enum _Grab { none, body, wallA, wallB, radar, resize }

IconData _kindIcon(ObjKind k) => switch (k) {
      ObjKind.wall => Icons.horizontal_rule,
      ObjKind.door => Icons.sensor_door_outlined,
      ObjKind.furniture => Icons.chair_outlined,
      ObjKind.person => Icons.person_outline,
      ObjKind.dog => Icons.pets,
      ObjKind.cat => Icons.cruelty_free_outlined,
      ObjKind.fan => Icons.toys_outlined,
    };

class _FloorPlanEditorState extends State<FloorPlanEditor> {
  _Grab _grab = _Grab.none;
  SceneObject? _obj;
  Size _size = Size.zero;

  SceneController get scene => widget.scene;

  double get _scale => math.min(_size.width / SceneController.worldW,
      _size.height / SceneController.worldH);
  Offset get _origin => Offset(
      (_size.width - SceneController.worldW * _scale) / 2,
      (_size.height - SceneController.worldH * _scale) / 2);

  Offset _toWorld(Offset p) => (p - _origin) / _scale;

  static double _distToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 < 1e-9) return (p - a).distance;
    double t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
    t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
    return (p - (a + ab * t)).distance;
  }

  void _hitTest(Offset w) {
    _grab = _Grab.none;
    _obj = null;
    final touch = math.max(0.35, 22 / _scale); // finger-sized, in metres

    // Handles of the selected object take priority.
    final sel = scene.byId(scene.selectedId);
    if (sel != null && sel.kind == ObjKind.wall) {
      if ((w - Offset(sel.x, sel.y)).distance < touch) {
        _grab = _Grab.wallA;
        _obj = sel;
        return;
      }
      if ((w - Offset(sel.x2, sel.y2)).distance < touch) {
        _grab = _Grab.wallB;
        _obj = sel;
        return;
      }
    }
    if (sel != null && sel.kind == ObjKind.furniture) {
      final corner = Offset(sel.x + sel.w / 2, sel.y + sel.h / 2);
      if ((w - corner).distance < touch) {
        _grab = _Grab.resize;
        _obj = sel;
        return;
      }
    }
    if ((w - Offset(scene.radarX, scene.radarY)).distance < touch) {
      _grab = _Grab.radar;
      return;
    }
    // Small things first, walls last.
    for (final kind in [
      ObjKind.person,
      ObjKind.dog,
      ObjKind.cat,
      ObjKind.fan,
      ObjKind.door,
      ObjKind.furniture,
      ObjKind.wall
    ]) {
      for (final o in scene.objects.reversed) {
        if (o.kind != kind) continue;
        bool hit = false;
        switch (kind) {
          case ObjKind.person:
          case ObjKind.dog:
          case ObjKind.cat:
          case ObjKind.fan:
            hit = (w - Offset(o.x, o.y)).distance < touch;
            break;
          case ObjKind.door:
            hit = (w - Offset(o.x, o.y)).distance < math.max(touch, o.w / 2);
            break;
          case ObjKind.furniture:
            hit = (w.dx - o.x).abs() < o.w / 2 + 0.1 &&
                (w.dy - o.y).abs() < o.h / 2 + 0.1;
            break;
          case ObjKind.wall:
            hit = _distToSegment(w, Offset(o.x, o.y), Offset(o.x2, o.y2)) <
                touch * 0.8;
            break;
        }
        if (hit) {
          _grab = _Grab.body;
          _obj = o;
          return;
        }
      }
    }
  }

  void _onPanStart(DragStartDetails d) {
    _hitTest(_toWorld(d.localPosition));
    final o = _obj;
    if (o != null) {
      if (o.kind.isBody) o.held = true;
      scene.select(o.id);
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final dw = d.delta / _scale;
    double cx(double v) =>
        v.clamp(0.0, SceneController.worldW).toDouble();
    double cy(double v) =>
        v.clamp(0.0, SceneController.worldH).toDouble();
    final o = _obj;
    switch (_grab) {
      case _Grab.none:
        return;
      case _Grab.radar:
        scene.radarX = cx(scene.radarX + dw.dx);
        scene.radarY = cy(scene.radarY + dw.dy);
        scene.touch();
        return;
      case _Grab.wallA:
        o!.x = cx(o.x + dw.dx);
        o.y = cy(o.y + dw.dy);
        scene.touch();
        return;
      case _Grab.wallB:
        o!.x2 = cx(o.x2 + dw.dx);
        o.y2 = cy(o.y2 + dw.dy);
        scene.touch();
        return;
      case _Grab.resize:
        o!.w = (o.w + dw.dx * 2).clamp(0.3, 6.0).toDouble();
        o.h = (o.h + dw.dy * 2).clamp(0.3, 6.0).toDouble();
        scene.touch();
        return;
      case _Grab.body:
        if (o == null) return;
        final ox = o.x, oy = o.y;
        o.x = cx(o.x + dw.dx);
        o.y = cy(o.y + dw.dy);
        if (o.kind == ObjKind.wall) {
          o.x2 += o.x - ox;
          o.y2 += o.y - oy;
        }
        if (o.kind.isBody) {
          widget.onPersonMoved?.call(o, ox, oy);
          scene.touch(staticChanged: false);
        } else {
          scene.touch();
        }
        return;
    }
  }

  void _onPanEnd(DragEndDetails d) {
    final o = _obj;
    if (o != null && o.kind.isBody) {
      o.held = false;
      widget.onPersonReleased?.call(o);
    }
    _grab = _Grab.none;
    _obj = null;
  }

  void _onTapUp(TapUpDetails d) {
    _hitTest(_toWorld(d.localPosition));
    scene.select(_obj?.id);
    _grab = _Grab.none;
    _obj = null;
  }

  Future<void> _save() async {
    final ctl = TextEditingController(text: 'Scene');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('Save scene'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('CANCEL')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctl.text.trim()),
              child: const Text('SAVE')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final ok = await Storage.saveScene(name, scene.toJsonString());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? 'Saved "$name"' : 'Could not save scene')));
  }

  Future<void> _load() async {
    final scenes = await Storage.listScenes();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: kSurface,
        title: const Text('Load scene'),
        children: [
          SimpleDialogOption(
            onPressed: () {
              scene.loadDefault();
              Navigator.of(ctx).pop();
            },
            child: const Text('Default floor plan'),
          ),
          for (final s in scenes)
            SimpleDialogOption(
              onPressed: () {
                scene.loadJsonString(s.json);
                Navigator.of(ctx).pop();
              },
              child: Text(s.name),
            ),
        ],
      ),
    );
  }

  Widget _tool(IconData icon, String tip, VoidCallback onTap) => IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tip,
        color: kPhosphor,
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: Row(
            children: [
              const SizedBox(width: 8),
              const Expanded(
                child: Text('FLOOR PLAN',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: kDim, fontSize: 11)),
              ),
              PopupMenuButton<ObjKind>(
                tooltip: 'Add to the floor plan',
                color: kSurface,
                icon: const Icon(Icons.add_box_outlined, color: kPhosphor, size: 20),
                onSelected: scene.addObject,
                itemBuilder: (_) => [
                  for (final k in ObjKind.values)
                    PopupMenuItem(
                      value: k,
                      child: Row(children: [
                        Icon(_kindIcon(k), size: 18, color: kPhosphor),
                        const SizedBox(width: 10),
                        Text(k.label, style: const TextStyle(fontSize: 13)),
                      ]),
                    ),
                ],
              ),
              _tool(Icons.delete_outline, 'Delete selected',
                  scene.removeSelected),
              _tool(Icons.save_outlined, 'Save scene', _save),
              _tool(Icons.folder_open, 'Load scene', _load),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              _size = Size(box.maxWidth, box.maxHeight);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                onTapUp: _onTapUp,
                child: CustomPaint(
                  size: _size,
                  painter: _PlanPainter(scene, widget.repaint),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PlanPainter extends CustomPainter {
  _PlanPainter(this.scene, Listenable repaint)
      : super(repaint: Listenable.merge([scene, repaint]));
  final SceneController scene;

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width / SceneController.worldW,
        size.height / SceneController.worldH);
    final org = Offset((size.width - SceneController.worldW * s) / 2,
        (size.height - SceneController.worldH * s) / 2);
    Offset p(double x, double y) => org + Offset(x * s, y * s);

    final area = Rect.fromLTWH(org.dx, org.dy, SceneController.worldW * s,
        SceneController.worldH * s);
    canvas.drawRect(area, Paint()..color = const Color(0xFF060C06));
    final grid = Paint()
      ..color = const Color(0xFF0F1F0F)
      ..strokeWidth = 1;
    for (int i = 0; i <= SceneController.worldW; i++) {
      canvas.drawLine(p(i.toDouble(), 0),
          p(i.toDouble(), SceneController.worldH), grid);
    }
    for (int i = 0; i <= SceneController.worldH; i++) {
      canvas.drawLine(p(0, i.toDouble()),
          p(SceneController.worldW, i.toDouble()), grid);
    }

    final handle = Paint()..color = kAmber;
    for (final o in scene.objects) {
      final sel = o.id == scene.selectedId;
      switch (o.kind) {
        case ObjKind.wall:
          canvas.drawLine(
              p(o.x, o.y),
              p(o.x2, o.y2),
              Paint()
                ..color = sel ? kAmber : kPhosphor
                ..strokeWidth = 4
                ..strokeCap = StrokeCap.round);
          if (sel) {
            canvas.drawCircle(p(o.x, o.y), 7, handle);
            canvas.drawCircle(p(o.x2, o.y2), 7, handle);
          }
          break;
        case ObjKind.door:
          canvas.drawCircle(p(o.x, o.y), o.w / 2 * s,
              Paint()..color = const Color(0xFF060C06));
          canvas.drawCircle(
              p(o.x, o.y),
              o.w / 2 * s,
              Paint()
                ..color = sel ? kAmber : kDim
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5);
          break;
        case ObjKind.furniture:
          final r = Rect.fromCenter(
              center: p(o.x, o.y), width: o.w * s, height: o.h * s);
          canvas.drawRect(r, Paint()..color = const Color(0xFF14301A));
          canvas.drawRect(
              r,
              Paint()
                ..color = sel ? kAmber : kDim
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5);
          if (sel) canvas.drawCircle(r.bottomRight, 7, handle);
          break;
        case ObjKind.person:
          final c = p(o.x, o.y);
          final col = sel ? kAmber : kAlert;
          // Top-down humanoid: shoulders and head.
          canvas.save();
          canvas.translate(c.dx, c.dy);
          canvas.rotate(o.heading + math.pi / 2);
          canvas.drawOval(
              Rect.fromCenter(
                  center: Offset.zero, width: 0.62 * s, height: 0.3 * s),
              Paint()..color = col.withOpacity(0.55));
          canvas.drawCircle(Offset.zero, 0.13 * s, Paint()..color = col);
          canvas.restore();
          break;
        case ObjKind.dog:
        case ObjKind.cat:
          final c = p(o.x, o.y);
          final big = o.kind == ObjKind.dog;
          final col = sel ? kAmber : const Color(0xFFE6A8FF);
          final len = (big ? 0.7 : 0.4) * s, wid = (big ? 0.26 : 0.16) * s;
          canvas.save();
          canvas.translate(c.dx, c.dy);
          canvas.rotate(o.heading);
          canvas.drawOval(
              Rect.fromCenter(center: Offset.zero, width: len, height: wid),
              Paint()..color = col.withOpacity(0.55));
          canvas.drawCircle(Offset(len * 0.55, 0), wid * 0.45,
              Paint()..color = col);
          canvas.restore();
          if (o.resting) {
            paintLabel(canvas, 'z', c + Offset(len * 0.4, -wid), col, size: 9);
          }
          break;
        case ObjKind.fan:
          final c = p(o.x, o.y);
          final col = sel ? kAmber : const Color(0xFF4FC3F7);
          canvas.drawCircle(
              c,
              0.22 * s,
              Paint()
                ..color = col
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.2);
          for (int k = 0; k < 3; k++) {
            final a = k * 2 * math.pi / 3;
            canvas.drawLine(c, c + Offset(math.cos(a), math.sin(a)) * 0.2 * s,
                Paint()
                  ..color = col
                  ..strokeWidth = 2);
          }
          break;
      }
    }

    // Radar marker.
    final rc = p(scene.radarX, scene.radarY);
    canvas.drawCircle(rc, 9, Paint()..color = kPhosphor.withOpacity(0.25));
    canvas.drawCircle(rc, 4, Paint()..color = kPhosphor);
    paintLabel(canvas, 'RADAR', rc + const Offset(10, -5), kPhosphor, size: 9);
  }

  @override
  bool shouldRepaint(covariant _PlanPainter oldDelegate) => false;
}
