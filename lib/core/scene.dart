import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bodies.dart';

enum ObjKind { wall, door, furniture, person, dog, cat, fan }

extension ObjKindX on ObjKind {
  /// True for things the radar sees as bodies (animated scatterers).
  bool get isBody =>
      this == ObjKind.person ||
      this == ObjKind.dog ||
      this == ObjKind.cat ||
      this == ObjKind.fan;

  BodyKind? get bodyKind => switch (this) {
        ObjKind.person => BodyKind.human,
        ObjKind.dog => BodyKind.dog,
        ObjKind.cat => BodyKind.cat,
        ObjKind.fan => BodyKind.fan,
        _ => null,
      };

  String get label => switch (this) {
        ObjKind.wall => 'Wall',
        ObjKind.door => 'Door gap',
        ObjKind.furniture => 'Furniture',
        ObjKind.person => 'Person',
        ObjKind.dog => 'Dog',
        ObjKind.cat => 'Cat',
        ObjKind.fan => 'Fan',
      };
}

/// One object on the floor plan. Units are metres, x right, y down.
///
/// wall:      (x, y) -> (x2, y2)
/// door:      centre (x, y), opening width w. Cuts a gap in any wall it sits on.
/// furniture: centre (x, y), size w x h
/// person / dog / cat: current position (x, y); (ax, ay) is the
///            animation anchor
/// fan:       centre (x, y)
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
        ay = y {
    final bk = kind.bodyKind;
    if (bk != null) body = BodyParams(bk, id * 7919 + kind.index * 131);
  }

  final int id;
  final ObjKind kind;
  double x, y, x2, y2, w, h;

  // Body animation state (person, dog, cat, fan). This is simulator
  // ground truth: the radar processing never reads it.
  BodyParams? body;
  double ax, ay;
  double phase = 0;
  double heading = 0;
  double gait = 0;
  double speed = 0; // current ground speed, m/s
  double behaviourTimer = 0; // animals: seconds left in walk / rest bout
  bool resting = false;
  bool held = false;

  // Natural movement: waypoints still to visit (x, y pairs), seconds left
  // standing still, and this leg's walking speed.
  final List<double> path = [];
  double pause = 0;
  double legSpeed = 1.0;

  /// Keep an animal within ~2 m of where it was placed instead of roaming
  /// the building.
  bool stayNear = false;
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
    // A person in the next room, seen through the partition, a dog in the
    // room below it, a cat at the back, and a desk fan running.
    _add(ObjKind.person, 10.3, 5.2);
    _add(ObjKind.dog, 10.2, 9.6);
    _add(ObjKind.cat, 4.6, 3.2);
    _add(ObjKind.fan, 6.9, 7.2);
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
      case ObjKind.dog:
      case ObjKind.cat:
      case ObjKind.fan:
        o = _add(kind, cx, cy);
        break;
    }
    selectedId = o.id;
    touch(staticChanged: !kind.isBody);
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
        final ki = (j['kind'] as num).toInt();
        if (ki < 0 || ki >= ObjKind.values.length) continue;
        final k = ObjKind.values[ki];
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
