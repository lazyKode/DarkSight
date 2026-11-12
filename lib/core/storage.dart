import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class SavedScene {
  const SavedScene(this.id, this.name, this.json);
  final int id;
  final String name;
  final String json;
}

/// SQLite persistence for scene configs and the list of exported frames.
/// Every call fails soft: storage problems never take the radar view down.
class Storage {
  static Database? _db;

  static Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'darksight.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE scenes('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'name TEXT NOT NULL, json TEXT NOT NULL, created INTEGER NOT NULL)');
        await db.execute('CREATE TABLE frames('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'path TEXT NOT NULL, created INTEGER NOT NULL)');
      },
    );
    _db = db;
    return db;
  }

  static Future<bool> saveScene(String name, String json) async {
    try {
      final db = await _open();
      await db.insert('scenes', {
        'name': name,
        'json': json,
        'created': DateTime.now().millisecondsSinceEpoch,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<List<SavedScene>> listScenes() async {
    try {
      final db = await _open();
      final rows = await db.query('scenes', orderBy: 'created DESC');
      return rows
          .map((r) => SavedScene(
              r['id'] as int, r['name'] as String, r['json'] as String))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> deleteScene(int id) async {
    try {
      final db = await _open();
      await db.delete('scenes', where: 'id = ?', whereArgs: [id]);
    } catch (_) {}
  }

  static Future<void> recordFrame(String path) async {
    try {
      final db = await _open();
      await db.insert('frames', {
        'path': path,
        'created': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {}
  }
}
