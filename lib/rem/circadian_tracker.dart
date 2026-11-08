import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

/// Where the sun is relative to the horizon.
enum Sun_Phase {
  day,                  // sun above the horizon
  civilTwilight,        // 0.833° to 6° below
  nauticalTwilight,     // 6° to 12° below
  astronomicalTwilight, // 12° to 18° below
  night,                // more than 18° below
}

/// Sun event times for one calendar day. Times are in device local time;
/// a time is null when that event does not happen on that day (polar day or night).
class Sun_Times {
  Sun_Times({
    required this.date,
    required this.solarNoon,
    this.sunrise,
    this.sunset,
    this.civilDawn,
    this.civilDusk,
    this.isPolarDay = false,
    this.isPolarNight = false,
  });

  final DateTime date;
  final DateTime solarNoon;
  final DateTime? sunrise;
  final DateTime? sunset;
  final DateTime? civilDawn; // sun 6° below the horizon, morning
  final DateTime? civilDusk; // sun 6° below the horizon, evening
  final bool isPolarDay;     // sun never sets
  final bool isPolarNight;   // sun never rises

  Duration get dayLength {
    if (isPolarDay) return const Duration(hours: 24);
    if (sunrise == null || sunset == null) return Duration.zero;
    return sunset!.difference(sunrise!);
  }

  @override
  String toString() => 'Sun_Times(${date.toIso8601String().substring(0, 10)}: sunrise $sunrise, sunset $sunset, '
      'noon $solarNoon${isPolarDay ? ', polar day' : ''}${isPolarNight ? ', polar night' : ''})';
}

/// A snapshot emitted by [Circadian_Tracker.states].
class Circadian_State {
  Circadian_State({ required this.time, required this.sunElevation, required this.phase, required this.isSunDown });

  final DateTime time;
  final double sunElevation; // degrees above (+) or below (-) the horizon
  final Sun_Phase phase;
  final bool isSunDown;
}

/// Tracks date/time information and the sun's position for the device's location.
///
/// The sun math follows NOAA's solar calculations (accurate to about a minute
/// between ±72° latitude) and runs offline; only the location comes from the OS.
/// Call [updateLocation] (or [setLocation] manually) before asking about the sun,
/// or use [checkSunDown], which fetches the location when needed.
///
/// Location needs ACCESS_COARSE_LOCATION (Android) / NSLocationWhenInUseUsageDescription (iOS).
class Circadian_Tracker {
  Circadian_Tracker({ this.latitude, this.longitude }) : startedAt = DateTime.now();

  // ------------ Date & Time ------------ //

  DateTime get now => DateTime.now();
  DateTime get nowUtc => DateTime.now().toUtc();
  String get timeZoneName => DateTime.now().timeZoneName;
  Duration get timeZoneOffset => DateTime.now().timeZoneOffset;

  /// How long this tracker has existed.
  Duration get uptime => DateTime.now().difference(startedAt);

  /// Day of the year, 1 - 366.
  int dayOfYear([ DateTime? t ]) {
    final DateTime d = t ?? DateTime.now();
    return DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(d.year, 1, 1)).inDays + 1;
  }

  /// ISO-8601 week number, 1 - 53.
  int weekOfYear([ DateTime? t ]) {
    final DateTime d = t ?? DateTime.now();
    final DateTime day = DateTime.utc(d.year, d.month, d.day);
    final DateTime thursday = day.add(Duration(days: 4 - day.weekday)); // the week belongs to the year of its Thursday
    return (thursday.difference(DateTime.utc(thursday.year, 1, 1)).inDays ~/ 7) + 1;
  }

  bool isLeapYear([ int? year ]) {
    final int y = year ?? DateTime.now().year;
    return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
  }

  int daysInMonth([ DateTime? t ]) {
    final DateTime d = t ?? DateTime.now();
    return DateTime.utc(d.year, d.month + 1, 0).day;
  }

  bool isWeekend([ DateTime? t ]) => (t ?? DateTime.now()).weekday >= DateTime.saturday;

  /// Time of day as hours, for example 13.5 at 1:30 PM.
  double hourOfDay([ DateTime? t ]) {
    final DateTime d = t ?? DateTime.now();
    return d.hour + d.minute / 60.0 + d.second / 3600.0;
  }

  // ------------ Location ------------ //

  bool get hasLocation => latitude != null && longitude != null;

  void setLocation(double lat, double lng) {
    latitude = lat;
    longitude = lng;
    locationUpdatedAt = DateTime.now();
  }

  /// Gets the device location (city-level accuracy is enough for sun times).
  /// Asks for permission when [requestPermission] is true. Returns true on success.
  Future<bool> updateLocation({ bool requestPermission = true, Duration timeout = const Duration(seconds: 10) }) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        print('Circadian_Tracker: location services are turned off');
        return false;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && requestPermission) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        print('Circadian_Tracker: location permission ${permission.name}');
        return false;
      }

      Position? position;
      try {
        // geolocator 9.x API: accuracy and timeout are passed directly
        position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.low, timeLimit: timeout);
      } catch (e) {
        print('Circadian_Tracker: current position unavailable ($e), trying last known position');
        try { position = await Geolocator.getLastKnownPosition(); } catch (_) {} // not available on web
      }
      if (position == null) return false;

      setLocation(position.latitude, position.longitude);
      print('Circadian_Tracker: location set to ${latitude!.toStringAsFixed(3)}, ${longitude!.toStringAsFixed(3)}');
      return true;
    } catch (e) {
      print('Circadian_Tracker: failed to get location: $e');
      return false;
    }
  }

  // ------------ Sun ------------ //

  /// Sun angle above (+) or below (-) the horizon in degrees, or null without a location.
  double? sunElevation([ DateTime? at ]) {
    if (!hasLocation) return null;
    return solarElevation(at ?? DateTime.now(), latitude!, longitude!);
  }

  Sun_Phase? sunPhase([ DateTime? at ]) {
    final double? e = sunElevation(at);
    return (e == null) ? null : phaseForElevation(e);
  }

  /// Whether the sun is down at the stored location right now. Null without a location.
  bool? get isSunDown => isSunDownAt(DateTime.now());

  /// Whether the sun is down at [at]. Null without a location.
  bool? isSunDownAt(DateTime at) {
    final double? e = sunElevation(at);
    return (e == null) ? null : e < horizonDegrees;
  }

  /// Like [isSunDown], but fetches the location first if there isn't one yet.
  /// Returns null only when no location can be obtained.
  Future<bool?> checkSunDown({ bool requestPermission = true }) async {
    if (!hasLocation) await updateLocation(requestPermission: requestPermission);
    return isSunDown;
  }

  /// Sunrise, sunset, civil twilight and solar noon for [date] (default today). Null without a location.
  Sun_Times? getSunTimes([ DateTime? date ]) {
    if (!hasLocation) return null;
    return computeSunTimes(date ?? DateTime.now(), latitude!, longitude!);
  }

  /// The next sunrise after now (looks up to a year ahead for polar regions). Null without a location.
  DateTime? nextSunrise() => _nextEvent((t) => t.sunrise);

  /// The next sunset after now (looks up to a year ahead for polar regions). Null without a location.
  DateTime? nextSunset() => _nextEvent((t) => t.sunset);

  Duration? timeUntilSunrise() => nextSunrise()?.difference(DateTime.now());
  Duration? timeUntilSunset() => nextSunset()?.difference(DateTime.now());

  DateTime? _nextEvent(DateTime? Function(Sun_Times t) pick) {
    if (!hasLocation) return null;
    final DateTime current = DateTime.now();
    final DateTime today = DateTime(current.year, current.month, current.day);
    for (int i = 0; i <= 366; i++) {
      final DateTime? event = pick(computeSunTimes(DateTime(today.year, today.month, today.day + i), latitude!, longitude!));
      if (event != null && event.isAfter(current)) return event;
    }
    return null;
  }

  // ------------ Tracking ------------ //

  /// Emits a [Circadian_State] on every tick while tracking.
  Stream<Circadian_State> get states => _states.stream;

  /// Checks the sun every [interval], emitting on [states] and calling
  /// [onSunDownChanged] / [onPhaseChanged] when they change.
  /// The location is refreshed every [locationRefresh] (null = never).
  Future<void> startTracking({
    Duration interval = const Duration(minutes: 1),
    Duration? locationRefresh = const Duration(hours: 1),
    bool requestPermission = true,
  }) async {
    stopTracking();
    if (!hasLocation) await updateLocation(requestPermission: requestPermission);
    _locationRefresh = locationRefresh;
    _tick();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stopTracking() {
    _timer?.cancel();
    _timer = null;
  }

  bool get isTracking => _timer != null;

  void _tick() {
    final DateTime t = DateTime.now();
    final DateTime? updated = locationUpdatedAt;
    if (_locationRefresh != null && updated != null && t.difference(updated) >= _locationRefresh!) {
      locationUpdatedAt = t; // avoid stacking requests while one is in flight
      updateLocation(requestPermission: false);
    }

    final double? elevation = sunElevation(t);
    if (elevation == null) return;

    final Sun_Phase phase = phaseForElevation(elevation);
    final bool down = elevation < horizonDegrees;

    if (_lastSunDown != null && _lastSunDown != down) onSunDownChanged?.call(down);
    if (_lastPhase != null && _lastPhase != phase) onPhaseChanged?.call(phase);
    _lastSunDown = down;
    _lastPhase = phase;

    if (!_states.isClosed) {
      _states.add(Circadian_State(time: t, sunElevation: elevation, phase: phase, isSunDown: down));
    }
  }

  void dispose() {
    stopTracking();
    _states.close();
  }

  // ------------ Solar Math (NOAA) ------------ //

  /// The sun's center sits 0.833° below the horizon at sunrise/sunset (refraction + solar radius).
  static const double horizonDegrees = -0.833;

  static Sun_Phase phaseForElevation(double elevation) {
    if (elevation >= horizonDegrees) return Sun_Phase.day;
    if (elevation >= -6.0) return Sun_Phase.civilTwilight;
    if (elevation >= -12.0) return Sun_Phase.nauticalTwilight;
    if (elevation >= -18.0) return Sun_Phase.astronomicalTwilight;
    return Sun_Phase.night;
  }

  /// Sun elevation in degrees at [time] for the given coordinates (longitude east-positive).
  static double solarElevation(DateTime time, double lat, double lng) {
    final DateTime utc = time.toUtc();
    final double hour = utc.hour + utc.minute / 60.0 + utc.second / 3600.0;
    final _SolarParams p = _solarParams(utc.year, utc.month, utc.day, hour);

    final double trueSolarMinutes = hour * 60.0 + p.equationOfTime + 4.0 * lng;
    final double hourAngle = _rad(trueSolarMinutes / 4.0 - 180.0);
    final double phi = _rad(lat);
    final double cosZenith = math.sin(phi) * math.sin(p.declination) +
        math.cos(phi) * math.cos(p.declination) * math.cos(hourAngle);
    return 90.0 - _deg(math.acos(cosZenith.clamp(-1.0, 1.0)));
  }

  /// Sun times for the calendar day of [date] at the given coordinates.
  static Sun_Times computeSunTimes(DateTime date, double lat, double lng) {
    final DateTime midnightUtc = DateTime.utc(date.year, date.month, date.day);
    DateTime toLocal(double minutes) => midnightUtc.add(Duration(microseconds: (minutes * 60000000).round())).toLocal();

    final _SolarParams noonParams = _solarParams(date.year, date.month, date.day, 12.0 - lng / 15.0);
    final double noonMinutes = 720.0 - 4.0 * lng - noonParams.equationOfTime;

    final _Event rise = _eventMinutes(date.year, date.month, date.day, lat, lng, 90.833, true);
    final _Event fall = _eventMinutes(date.year, date.month, date.day, lat, lng, 90.833, false);
    final _Event dawn = _eventMinutes(date.year, date.month, date.day, lat, lng, 96.0, true);
    final _Event dusk = _eventMinutes(date.year, date.month, date.day, lat, lng, 96.0, false);

    return Sun_Times(
      date: DateTime(date.year, date.month, date.day),
      solarNoon: toLocal(noonMinutes),
      sunrise: rise.minutes == null ? null : toLocal(rise.minutes!),
      sunset: fall.minutes == null ? null : toLocal(fall.minutes!),
      civilDawn: dawn.minutes == null ? null : toLocal(dawn.minutes!),
      civilDusk: dusk.minutes == null ? null : toLocal(dusk.minutes!),
      isPolarDay: rise.alwaysUp,
      isPolarNight: rise.alwaysDown,
    );
  }

  /// Minutes after UTC midnight of the given date when the sun crosses [zenith] degrees.
  static _Event _eventMinutes(int y, int m, int d, double lat, double lng, double zenith, bool rising) {
    double minutes = 720.0 - 4.0 * lng; // start from solar noon and refine
    for (int i = 0; i < 3; i++) {
      final _SolarParams p = _solarParams(y, m, d, minutes / 60.0);
      final double phi = _rad(lat);
      final double cosHa = math.cos(_rad(zenith)) / (math.cos(phi) * math.cos(p.declination)) -
          math.tan(phi) * math.tan(p.declination);
      if (cosHa > 1.0) return _Event(alwaysDown: true);
      if (cosHa < -1.0) return _Event(alwaysUp: true);
      final double ha = _deg(math.acos(cosHa));
      minutes = 720.0 - 4.0 * (lng + (rising ? ha : -ha)) - p.equationOfTime;
    }
    return _Event(minutes: minutes);
  }

  static _SolarParams _solarParams(int y, int m, int d, double hourUtc) {
    final int daysInYear = ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 366 : 365;
    final int doy = DateTime.utc(y, m, d).difference(DateTime.utc(y, 1, 1)).inDays + 1;
    final double g = 2.0 * math.pi / daysInYear * (doy - 1 + (hourUtc - 12.0) / 24.0); // fractional year
    final double eqTime = 229.18 * (0.000075 + 0.001868 * math.cos(g) - 0.032077 * math.sin(g) -
        0.014615 * math.cos(2 * g) - 0.040849 * math.sin(2 * g));
    final double decl = 0.006918 - 0.399912 * math.cos(g) + 0.070257 * math.sin(g) -
        0.006758 * math.cos(2 * g) + 0.000907 * math.sin(2 * g) -
        0.002697 * math.cos(3 * g) + 0.00148 * math.sin(3 * g);
    return _SolarParams(eqTime, decl);
  }

  static double _rad(double deg) => deg * math.pi / 180.0;
  static double _deg(double rad) => rad * 180.0 / math.pi;

  double? latitude;
  double? longitude;
  DateTime? locationUpdatedAt = null;
  final DateTime startedAt;

  void Function(bool isSunDown)? onSunDownChanged;
  void Function(Sun_Phase phase)? onPhaseChanged;

  final StreamController<Circadian_State> _states = StreamController<Circadian_State>.broadcast();
  Timer? _timer = null;
  Duration? _locationRefresh;
  bool? _lastSunDown = null;
  Sun_Phase? _lastPhase = null;
}

class _SolarParams {
  _SolarParams(this.equationOfTime, this.declination);
  final double equationOfTime; // minutes
  final double declination;    // radians
}

class _Event {
  _Event({ this.minutes, this.alwaysUp = false, this.alwaysDown = false });
  final double? minutes;
  final bool alwaysUp;
  final bool alwaysDown;
}
