import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:neural_tts/neural_tts.dart';

/// Text-to-speech service built on the on-device `neural_tts` engines.
///
/// Engines: [EngineId.system] (built-in OS voices, no download),
/// [EngineId.kitten] (~57 MB), [EngineId.kokoro] (~170 MB) and
/// [EngineId.supertonic] (~265 MB). Neural engines need their model files
/// downloaded once, either through [downloadModels] or `autoDownload: true`.
///
/// NOTE: `neural_tts` currently supports Android only (minSdkVersion 24).
class Neural_TTS {
  Neural_TTS({
    this.engineId = EngineId.system,
    String? voice,
    double speed = 1.0,
    this.pitch = 1.0,
    this.volume = 1.0,
    this.language,
    this.autoDownload = false,
    this.useEspeak = false,
  }) : _requestedVoice = voice, _speed = _clampSpeed(speed) {
    _engine = createEngine(engineId);
    _initFuture = init(); // checks installation, loads voices, picks the voice
  }

  // ------------ Setup ------------ //

  /// Prepares the engine. Returns true when it is ready to speak.
  /// Called by the constructor; await [ready] to wait for it.
  Future<bool> init() async {
    if (!isSupported) {
      print('Neural_TTS: neural_tts only supports Android, TTS is disabled on this platform');
      return false;
    }

    try {
      EngineStatus status = await _engine.checkStatus();
      if (!status.isInstalled && autoDownload) {
        await for (final double progress in downloadModels()) {
          print('Neural_TTS: downloading ${engineId.name} models ${(progress * 100).toStringAsFixed(1)}%');
        }
        status = await _engine.checkStatus();
      }
      if (!status.isInstalled) {
        print('Neural_TTS: ${engineId.name} models are not installed, call downloadModels() first');
        return false;
      }

      if (useEspeak && engineId != EngineId.system) {
        final ttsDir = await _downloader.getTtsDir();
        _engine.setPhonemizer(EspeakPhonemizer(dataPath: ttsDir.path, language: language ?? 'en-us'));
      }

      voices = await _engine.getVoices();
      print('Neural_TTS: engine ${engineId.name}\nAvailable voices:');
      for (final v in voices) print('  - ${v.id} (${v.name}${v.language != null ? ', ${v.language}' : ''})');

      if (_requestedVoice != null) selectVoice(_requestedVoice!);
      currentVoice ??= voices.isNotEmpty ? voices.first : null;

      await _engine.load();
      _isReady = currentVoice != null;
      return _isReady;
    } catch (e) {
      print('Neural_TTS: failed to initialize ${engineId.name}: $e');
      return false;
    }
  }

  /// Completes with the result of [init].
  Future<bool> get ready => _initFuture;

  /// Downloads the model files for the current engine, emitting progress from 0.0 to 1.0.
  /// When done, call [init] again (or create a new instance) to load the voices.
  Stream<double> downloadModels() async* {
    if (engineId == EngineId.system) {
      yield 1.0; // nothing to download for OS voices
      return;
    }
    await for (final FileProgress p in _downloader.downloadEngineFiles(engineId)) {
      yield p.fraction;
    }
  }

  /// Deletes this engine's downloaded model files.
  Future<void> deleteModels() => _downloader.deleteEngine(engineId);

  // ------------ Voice Selection ------------ //

  /// Returns the voices for the current engine, optionally filtered.
  List<Voice> getVoices({ String? language, String? gender }) {
    return voices.where((v) =>
      (language == null || (v.language ?? '').toLowerCase().startsWith(language.toLowerCase())) &&
      (gender == null || (v.gender ?? '').toLowerCase() == gender.toLowerCase())
    ).toList();
  }

  /// Selects a voice by id or display name (case-insensitive). Returns the selected voice, or null if not found.
  Voice? selectVoice(String idOrName) {
    final String key = idOrName.toLowerCase();
    for (final v in voices) {
      if (v.id.toLowerCase() == key || v.name.toLowerCase() == key) {
        currentVoice = v;
        return v;
      }
    }
    print('Neural_TTS: voice "$idOrName" not found for ${engineId.name}');
    return null;
  }

  /// Selects the first voice matching [language] and/or [gender]. Returns null if none match.
  Voice? selectVoiceWhere({ String? language, String? gender }) {
    final matches = getVoices(language: language, gender: gender);
    if (matches.isEmpty) return null;
    currentVoice = matches.first;
    return currentVoice;
  }

  // ------------ Playback ------------ //

  /// Speaks [text] and completes when playback finishes.
  /// Optional overrides apply to this call only: [voice] (id or name), [speed] (0.5 - 2.0),
  /// [pitch], [volume] and [language]. With [stripThinking], `<think>` blocks from
  /// reasoning models (such as qwen3 through Ollama_Service) are removed first.
  /// Returns false if nothing was spoken (not ready, empty text, stopped or failed).
  Future<bool> speak(String text, {
    String? voice,
    double? speed,
    double? pitch,
    double? volume,
    String? language,
    bool stripThinking = true,
  }) async {
    if (!await _initFuture && !_isReady) return false;

    final String spoken = stripThinking ? ThinkingStripper.stripFinal(text).text.trim() : text.trim();
    if (spoken.isEmpty) return false;

    final Voice? chosen = (voice != null) ? _findVoice(voice) : currentVoice;
    if (chosen == null) {
      print('Neural_TTS: no voice available to speak with');
      return false;
    }

    _stopRequested = false;
    _isSpeaking = true;
    try {
      await _engine.play(
        spoken,
        chosen,
        language: language ?? this.language,
        rate: _clampSpeed(speed ?? _speed),
        pitch: pitch ?? this.pitch,
        volume: volume ?? this.volume,
      );
      return true;
    } catch (e) {
      // play() completes with an error when stop() interrupts it
      if (!_stopRequested) print('Neural_TTS: playback failed: $e');
      return false;
    } finally {
      _isSpeaking = false;
    }
  }

  /// Starts a streaming session for text that arrives in chunks (for example, tokens from an LLM).
  /// Call `appendText` on the handle as text arrives, then `finalize()` to wait for playback to end.
  /// Not supported by the system engine.
  StreamingHandle speakStream({ String? voice, double? speed, double? pitch, double? volume, String? language }) {
    if (engineId == EngineId.system) {
      throw UnsupportedError('Neural_TTS: the system engine does not support streaming, use kitten or kokoro');
    }
    final Voice? chosen = (voice != null) ? _findVoice(voice) : currentVoice;
    if (chosen == null) throw StateError('Neural_TTS: no voice available, await ready first');

    return _engine.playStreaming(
      chosen,
      language: language ?? this.language,
      rate: _clampSpeed(speed ?? _speed),
      pitch: pitch ?? this.pitch,
      volume: volume ?? this.volume,
    );
  }

  /// Stops any current playback.
  Future<void> stop() async {
    _stopRequested = true;
    await _engine.stop();
    _isSpeaking = false;
  }

  /// Stops playback and frees the engine's native resources.
  Future<void> dispose() async {
    _stopRequested = true;
    await _engine.release();
    _isReady = false;
    _isSpeaking = false;
  }

  // ------------ Helpers ------------ //

  Voice? _findVoice(String idOrName) {
    final String key = idOrName.toLowerCase();
    for (final v in voices) {
      if (v.id.toLowerCase() == key || v.name.toLowerCase() == key) return v;
    }
    print('Neural_TTS: voice "$idOrName" not found, using ${currentVoice?.id}');
    return currentVoice;
  }

  static double _clampSpeed(double s) => s.clamp(minSpeed, maxSpeed).toDouble();

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  bool get isReady => _isReady;
  bool get isSpeaking => _isSpeaking;

  /// Playback speed multiplier, clamped to [minSpeed] - [maxSpeed] (1.0 = normal).
  double get speed => _speed;
  set speed(double value) { _speed = _clampSpeed(value); }

  static const double minSpeed = 0.5;
  static const double maxSpeed = 2.0;

  final EngineId engineId;
  double pitch;
  double volume;
  String? language; // e.g. 'en-us', used for phonemization
  bool autoDownload;
  bool useEspeak;

  List<Voice> voices = <Voice>[];
  Voice? currentVoice = null;

  late final Engine _engine;
  late final Future<bool> _initFuture;
  final ModelDownloader _downloader = ModelDownloader();
  final String? _requestedVoice;
  double _speed;
  bool _isReady = false;
  bool _isSpeaking = false;
  bool _stopRequested = false;
}
