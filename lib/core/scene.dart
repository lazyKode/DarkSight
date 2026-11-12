import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ObjKind { wall, door, furniture, person }

/// One object on the floor plan. Units are metres, x right, y down.
///
/// wall:      (x, y) -> (x2, y2)
/// door:      centre (x, y), opening width w. Cuts a gap in any wall it sits on.
/// furniture: centre (x, y), size w x h
/// person:    current position (x, y); (ax, ay) is the animation anchor
class SceneObject {
  SceneObject({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    this.x2 = 0,
    this.y2 = 0,
    this.w = 1,
    this.h = 1,
  })  : ax = x,
        ay = y;

  final int id;
  final ObjKind kind;
  double x, y, x2, y2, w, h;

  // Person animation state.
  double ax, ay;
  double phase = 0;
  double heading = 0;
  double gait = 0;
  bool held = false;
  bool moving = false;

  Map<String, dynamic> toJson() => {
        'kind': kind.index,
        'x': kind == ObjKind.person ? ax : x,
        'y': kind == ObjKind.person ? ay : y,
        'x2': x2,
        'y2': y2,
        'w': w,
        'h': h,
      };
}

class SceneController extends ChangeNotifier {
  SceneController() {
    loadDefault();
  }

  static const double worldW = 14;
  static const double worldH = 14;

  final List<SceneObject> objects = [];
  double radarX = 5;
  double radarY = 9.5;
  int? selectedId;

  /// Bumped on any change.
  int revision = 0;

  /// Bumped only when walls, doors, furniture or the radar move, i.e. when
  /// the static scatterer set has to be rebuilt.
  int staticRevision = 0;

  int _nextId = 1;

  SceneObject _add(ObjKind kind, double x, double y,
      {double x2 = 0, double y2 = 0, double w = 1, double h = 1}) {
    final o = SceneObject(
        id: _nextId++, kind: kind, x: x, y: y, x2: x2, y2: y2, w: w, h: h);
    objects.add(o);
    return o;
  }

  void loadDefault() {
    objects.clear();
    selectedId = null;
    radarX = 5;
    radarY = 9.5;
    // Outer shell.
    _add(ObjKind.wall, 1.5, 1.5, x2: 12.5, y2: 1.5);
    _add(ObjKind.wall, 12.5, 1.5, x2: 12.5, y2: 12.5);
    _add(ObjKind.wall, 12.5, 12.5, x2: 1.5, y2: 12.5);
    _add(ObjKind.wall, 1.5, 12.5, x2: 1.5, y2: 1.5);
    // Interior partitions with door gaps.
    _add(ObjKind.wall, 8, 1.5, x2: 8, y2: 12.5);
    _add(ObjKind.wall, 1.5, 6, x2: 8, y2: 6);
    _add(ObjKind.door, 8, 9.5, w: 1.0);
    _add(ObjKind.door, 4, 6, w: 1.0);
    // Furniture.
    _add(ObjKind.furniture, 3.2, 3.4, w: 1.6, h: 0.9);
    _add(ObjKind.furniture, 10.6, 11.4, w: 2.0, h: 0.8);
    // A person in the next room, seen through the partition.
    _add(ObjKind.person, 10.3, 5.2);
    touch();
  }

  SceneObject addObject(ObjKind kind) {
    const cx = worldW / 2, cy = worldH / 2;
    late SceneObject o;
    switch (kind) {
      case ObjKind.wall:
        o = _add(kind, cx - 1.5, cy, x2: cx + 1.5, y2: cy);
        break;
      case ObjKind.door:
        o = _add(kind, cx, cy, w: 1.0);
        break;
      case ObjKind.furniture:
        o = _add(kind, cx, cy, w: 1.2, h: 0.8);
        break;
      case ObjKind.person:
        o = _add(kind, cx, cy);
        break;
    }
    selectedId = o.id;
    touch(staticChanged: kind != ObjKind.person);
    return o;
  }

  SceneObject? byId(int? id) {
    if (id == null) return null;
    for (final o in objects) {
      if (o.id == id) return o;
    }
    return null;
  }

  void removeSelected() {
    final o = byId(selectedId);
    if (o == null) return;
    objects.remove(o);
    selectedId = null;
    touch();
  }

  void select(int? id) {
    if (selectedId == id) return;
    selectedId = id;
    touch(staticChanged: false);
  }

  void touch({bool staticChanged = true}) {
    revision++;
    if (staticChanged) staticRevision++;
    notifyListeners();
  }

  String toJsonString() => jsonEncode({
        'radar': [radarX, radarY],
        'objects': objects.map((o) => o.toJson()).toList(),
      });

  bool loadJsonString(String s) {
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      final r = (m['radar'] as List).cast<num>();
      final list = (m['objects'] as List).cast<Map<String, dynamic>>();
      objects.clear();
      selectedId = null;
      radarX = r[0].toDouble();
      radarY = r[1].toDouble();
      for (final j in list) {
        final k = ObjKind.values[(j['kind'] as num).toInt()];
        _add(k, (j['x'] as num).toDouble(), (j['y'] as num).toDouble(),
            x2: (j['x2'] as num).toDouble(),
            y2: (j['y2'] as num).toDouble(),
            w: (j['w'] as num).toDouble(),
            h: (j['h'] as num).toDouble());
      }
      touch();
      return true;
    } catch (_) {
      return false;
    }
  }
}

final sceneProvider =
    ChangeNotifierProvider<SceneController>((ref) => SceneController());
