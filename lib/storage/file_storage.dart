import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persistent JSON storage inside the app's documents folder.
///
/// Two ways to use it:
///  * Documents: [writeJson] / [readJson] store any JSON value in its own file.
///  * Entries: [addEntry], [readEntries], [getEntry], [updateEntry], [removeEntry]
///    keep a list of records in one file. Each record gets an "id" and timestamps.
///
/// Writes go through a temporary file and are queued per file, so concurrent
/// calls never lose an update or leave a half-written file behind.
/// Uses dart:io, so it runs on Android, iOS, macOS, Windows and Linux (not web).
class File_Storage {
  File_Storage({ this.folderName = "communist_plant", Future<Directory> Function()? directoryProvider })
    : _directoryProvider = directoryProvider;

  // ------------ Files & Folders ------------ //

  /// The storage folder, created on first use.
  Future<Directory> getRootDir() async {
    if (_rootDir != null) return _rootDir!;
    final Directory base = (_directoryProvider != null)
        ? await _directoryProvider!()
        : await getApplicationDocumentsDirectory();
    final Directory dir = Directory('${base.path}${Platform.pathSeparator}$folderName');
    if (!await dir.exists()) await dir.create(recursive: true);
    _rootDir = dir;
    return dir;
  }

  /// Returns the file for [fileName]. ".json" is appended when no extension is given.
  Future<File> getFile(String fileName) async {
    final Directory dir = await getRootDir();
    return File('${dir.path}${Platform.pathSeparator}${_normalizeName(fileName)}');
  }

  Future<bool> exists(String fileName) async => (await getFile(fileName)).exists();

  /// Names of the JSON files in the storage folder.
  Future<List<String>> listFiles() async {
    final Directory dir = await getRootDir();
    final List<String> names = <String>[];
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) names.add(entity.uri.pathSegments.last);
    }
    names.sort();
    return names;
  }

  Future<bool> deleteFile(String fileName) => _synchronized(fileName, () async {
    final File file = await getFile(fileName);
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  });

  // ------------ JSON Documents ------------ //

  /// Writes any JSON-encodable value (Map, List, String, num, bool or null) to [fileName].
  Future<void> writeJson(String fileName, Object? data, { bool pretty = true }) =>
    _synchronized(fileName, () => _writeJsonUnlocked(fileName, data, pretty: pretty));

  /// Reads and decodes [fileName]. Returns [fallback] if the file is missing or not valid JSON.
  Future<dynamic> readJson(String fileName, { dynamic fallback }) async {
    final File file = await getFile(fileName);
    if (!await file.exists()) return fallback;
    try {
      final String text = await file.readAsString();
      if (text.trim().isEmpty) return fallback;
      return jsonDecode(text);
    } on FormatException catch (e) {
      print('File_Storage: ${file.path} is not valid JSON: ${e.message}');
      return fallback;
    }
  }

  /// Reads [fileName] as a JSON object. Returns null if missing, invalid, or not an object.
  Future<Map<String, dynamic>?> readJsonMap(String fileName) async {
    final dynamic data = await readJson(fileName);
    return (data is Map) ? Map<String, dynamic>.from(data) : null;
  }

  // ------------ JSON Entries ------------ //

  /// All entries stored in [fileName], oldest first.
  Future<List<Map<String, dynamic>>> readEntries(String fileName) async {
    final dynamic data = await readJson(fileName, fallback: <dynamic>[]);
    if (data is! List) {
      print('File_Storage: $fileName does not hold a list of entries');
      return <Map<String, dynamic>>[];
    }
    return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Adds [entry] to [fileName] and returns its id.
  /// "id" and "createdAt" (ISO-8601 UTC) are filled in when missing.
  Future<String> addEntry(String fileName, Map<String, dynamic> entry) => _synchronized(fileName, () async {
    final List<Map<String, dynamic>> entries = await readEntries(fileName);
    final Map<String, dynamic> record = Map<String, dynamic>.from(entry);
    record[idKey] ??= _newId();
    record[createdKey] ??= DateTime.now().toUtc().toIso8601String();
    entries.add(record);
    await _writeJsonUnlocked(fileName, entries);
    return record[idKey].toString();
  });

  /// Adds several entries in one write. Returns their ids in order.
  Future<List<String>> addEntries(String fileName, List<Map<String, dynamic>> newEntries) => _synchronized(fileName, () async {
    final List<Map<String, dynamic>> entries = await readEntries(fileName);
    final String now = DateTime.now().toUtc().toIso8601String();
    final List<String> ids = <String>[];
    for (final Map<String, dynamic> entry in newEntries) {
      final Map<String, dynamic> record = Map<String, dynamic>.from(entry);
      record[idKey] ??= _newId();
      record[createdKey] ??= now;
      entries.add(record);
      ids.add(record[idKey].toString());
    }
    await _writeJsonUnlocked(fileName, entries);
    return ids;
  });

  /// The entry with [id], or null if there is none.
  Future<Map<String, dynamic>?> getEntry(String fileName, String id) async {
    for (final Map<String, dynamic> e in await readEntries(fileName)) {
      if (e[idKey]?.toString() == id) return e;
    }
    return null;
  }

  /// Entries matching [where], optionally sorted by [compare] and capped at [limit].
  Future<List<Map<String, dynamic>>> queryEntries(
    String fileName,
    bool Function(Map<String, dynamic> entry) where, {
    int Function(Map<String, dynamic> a, Map<String, dynamic> b)? compare,
    int? limit,
  }) async {
    final List<Map<String, dynamic>> results = (await readEntries(fileName)).where(where).toList();
    if (compare != null) results.sort(compare);
    return (limit != null && results.length > limit) ? results.sublist(0, limit) : results;
  }

  /// Merges [changes] into the entry with [id] and sets "updatedAt". Returns false if not found.
  /// The id and createdAt fields cannot be changed.
  Future<bool> updateEntry(String fileName, String id, Map<String, dynamic> changes) => _synchronized(fileName, () async {
    final List<Map<String, dynamic>> entries = await readEntries(fileName);
    final int index = entries.indexWhere((e) => e[idKey]?.toString() == id);
    if (index < 0) return false;
    final Map<String, dynamic> record = entries[index];
    changes.forEach((key, value) { if (key != idKey && key != createdKey) record[key] = value; });
    record[updatedKey] = DateTime.now().toUtc().toIso8601String();
    await _writeJsonUnlocked(fileName, entries);
    return true;
  });

  /// Removes the entry with [id]. Returns false if not found.
  Future<bool> removeEntry(String fileName, String id) => _synchronized(fileName, () async {
    final List<Map<String, dynamic>> entries = await readEntries(fileName);
    final int before = entries.length;
    entries.removeWhere((e) => e[idKey]?.toString() == id);
    if (entries.length == before) return false;
    await _writeJsonUnlocked(fileName, entries);
    return true;
  });

  /// Removes every entry but keeps the file (as an empty list).
  Future<void> clearEntries(String fileName) => writeJson(fileName, <dynamic>[]);

  // ------------ Helpers ------------ //

  Future<void> _writeJsonUnlocked(String fileName, Object? data, { bool pretty = true }) async {
    final File file = await getFile(fileName);
    final String text = pretty ? const JsonEncoder.withIndent('  ').convert(data) : jsonEncode(data);
    // Write to a temp file first, then swap it in, so a crash mid-write can't corrupt the original
    final File temp = File('${file.path}.tmp');
    await temp.writeAsString(text, flush: true);
    await temp.rename(file.path);
  }

  /// Runs [action] after any earlier queued action on the same file has finished.
  Future<T> _synchronized<T>(String fileName, Future<T> Function() action) {
    final String key = _normalizeName(fileName);
    final Future<void> previous = _locks[key] ?? Future<void>.value();
    final Future<T> result = previous.then((_) => action());
    final Future<void> tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _locks[key] = tail;
    tail.then((_) { if (identical(_locks[key], tail)) _locks.remove(key); });
    return result;
  }

  String _normalizeName(String fileName) {
    // Keep names inside the storage folder: strip separators and parent references
    String name = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll('..', '_').trim();
    if (name.isEmpty) name = 'data';
    if (!name.contains('.')) name = '$name.json';
    return name;
  }

  String _newId() {
    _idCounter = (_idCounter + 1) % 1296; // two base-36 digits
    return DateTime.now().microsecondsSinceEpoch.toRadixString(36) + _idCounter.toRadixString(36).padLeft(2, '0');
  }

  static const String idKey = 'id';
  static const String createdKey = 'createdAt';
  static const String updatedKey = 'updatedAt';

  final String folderName;
  final Future<Directory> Function()? _directoryProvider;
  Directory? _rootDir = null;
  final Map<String, Future<void>> _locks = <String, Future<void>>{};
  int _idCounter = 0;
}
