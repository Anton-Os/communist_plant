import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:communist_plant/rem/circadian_tracker.dart';
import 'package:communist_plant/storage/file_storage.dart';

void main() {
  group('Circadian_Tracker', () {
    const double chicagoLat = 41.8781, chicagoLng = -87.6298;

    void expectNear(DateTime? actual, DateTime expectedUtc, { int minutes = 3 }) {
      expect(actual, isNotNull);
      expect(actual!.toUtc().difference(expectedUtc).inMinutes.abs(), lessThanOrEqualTo(minutes),
          reason: 'got ${actual.toUtc()}, expected about $expectedUtc');
    }

    test('sunrise and sunset in Chicago on the June solstice', () {
      final t = Circadian_Tracker.computeSunTimes(DateTime(2026, 6, 21), chicagoLat, chicagoLng);
      expectNear(t.sunrise, DateTime.utc(2026, 6, 21, 10, 15)); // 5:15 AM CDT
      expectNear(t.sunset, DateTime.utc(2026, 6, 22, 1, 29));   // 8:29 PM CDT
      expect(t.dayLength.inMinutes, closeTo(15 * 60 + 14, 5));
    });

    test('sunrise and sunset in Chicago on the December solstice', () {
      final t = Circadian_Tracker.computeSunTimes(DateTime(2026, 12, 21), chicagoLat, chicagoLng);
      expectNear(t.sunrise, DateTime.utc(2026, 12, 21, 13, 15)); // 7:15 AM CST
      expectNear(t.sunset, DateTime.utc(2026, 12, 21, 22, 22));  // 4:22 PM CST
    });

    test('polar day and polar night in Svalbard', () {
      final summer = Circadian_Tracker.computeSunTimes(DateTime(2026, 6, 21), 78.22, 15.65);
      final winter = Circadian_Tracker.computeSunTimes(DateTime(2026, 12, 21), 78.22, 15.65);
      expect(summer.isPolarDay, isTrue);
      expect(summer.sunrise, isNull);
      expect(winter.isPolarNight, isTrue);
      expect(winter.sunset, isNull);
    });

    test('isSunDownAt follows the sun', () {
      final tracker = Circadian_Tracker(latitude: chicagoLat, longitude: chicagoLng);
      expect(tracker.isSunDownAt(DateTime.utc(2026, 6, 21, 17, 0)), isFalse); // noon CDT
      expect(tracker.isSunDownAt(DateTime.utc(2026, 6, 21, 5, 0)), isTrue);   // midnight CDT
      expect(tracker.sunPhase(DateTime.utc(2026, 6, 21, 5, 0)), Sun_Phase.night);
      expect(Circadian_Tracker().isSunDown, isNull); // no location yet
    });

    test('date helpers', () {
      final tracker = Circadian_Tracker();
      expect(tracker.dayOfYear(DateTime(2026, 12, 31)), 365);
      expect(tracker.dayOfYear(DateTime(2028, 12, 31)), 366);
      expect(tracker.weekOfYear(DateTime(2026, 1, 1)), 1);
      expect(tracker.weekOfYear(DateTime(2027, 1, 1)), 53); // belongs to ISO week 2026-W53
      expect(tracker.daysInMonth(DateTime(2028, 2, 10)), 29);
      expect(tracker.isWeekend(DateTime(2026, 11, 8)), isTrue); // Sunday
    });
  });

  group('File_Storage', () {
    late Directory temp;
    late File_Storage storage;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('file_storage_test');
      storage = File_Storage(folderName: 'data', directoryProvider: () async => temp);
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('writes and reads JSON documents', () async {
      await storage.writeJson('settings', {'volume': 0.8, 'voice': 'af_heart'});
      expect(await storage.readJsonMap('settings'), {'volume': 0.8, 'voice': 'af_heart'});
      expect(await storage.readJson('missing', fallback: 42), 42);
      expect(await storage.listFiles(), ['settings.json']);
    });

    test('adds, updates, queries and removes entries', () async {
      final String id = await storage.addEntry('log', {'text': 'hello'});
      await storage.addEntries('log', [{'text': 'a'}, {'text': 'b'}]);
      expect((await storage.readEntries('log')).length, 3);

      expect(await storage.updateEntry('log', id, {'text': 'changed', 'id': 'ignored'}), isTrue);
      final entry = await storage.getEntry('log', id);
      expect(entry?['text'], 'changed');
      expect(entry?['updatedAt'], isNotNull);

      final matches = await storage.queryEntries('log', (e) => e['text'] == 'b');
      expect(matches.single['text'], 'b');

      expect(await storage.removeEntry('log', id), isTrue);
      expect(await storage.getEntry('log', id), isNull);
    });

    test('concurrent adds are not lost', () async {
      await Future.wait(List.generate(25, (i) => storage.addEntry('race', {'n': i})));
      expect((await storage.readEntries('race')).length, 25);
    });
  });
}
