import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:native_camera_view/native_camera_view.dart';

/// One frame grabbed from the camera, as encoded JPEG bytes.
class Camera_Frame {
  Camera_Frame({ required this.bytes, required this.path, required this.capturedAt, required this.isFrontCamera });

  final Uint8List bytes;      // JPEG data
  final String path;          // where the native side wrote the file (deleted when deleteAfterRead is true)
  final DateTime capturedAt;
  final bool isFrontCamera;

  int get sizeInBytes => bytes.lengthInBytes;
}

/// Camera access through the platform's own camera APIs
/// (CameraX on Android, AVFoundation on iOS) via `native_camera_view`.
///
/// Usage:
///  1. Put [buildPreview] in the widget tree (the native camera only runs while it is on screen).
///  2. `await waitUntilReady()`.
///  3. Call [fetchFrame] for a single frame, or listen to [frameStream] for frames at an interval.
///
/// Frames are JPEG stills. While paused, [fetchFrame] returns the last frame shown.
/// Needs the CAMERA permission (Android) / NSCameraUsageDescription (iOS) in the host app.
class Camera_Sensor {
  Camera_Sensor({
    this.useFrontCamera = false,
    this.deleteAfterRead = true,
    this.fit = CameraPreviewFit.cover,
    this.previewPreset = CameraResolutionPreset.high,
    this.capturePreset = CameraResolutionPreset.medium,
    this.captureMode = CameraCaptureMode.minimizeLatency,
  });

  // ------------ Preview ------------ //

  /// The native camera preview. The camera starts when this widget is first built.
  Widget buildPreview({ Key? key, Widget? loadingWidget }) {
    if (!isSupported) return const Center(child: Text('Camera is only supported on Android and iOS'));
    return NativeCameraView(
      key: key,
      onControllerCreated: _onControllerCreated,
      isFrontCamera: useFrontCamera,
      cameraPreviewFit: fit,
      previewPreset: previewPreset,
      capturePreset: capturePreset,
      captureMode: captureMode,
      loadingWidget: loadingWidget,
    );
  }

  void _onControllerCreated(CameraController newController) {
    controller = newController; // replaced whenever the preview widget is recreated
    print('Camera_Sensor: native camera controller created (front: $useFrontCamera)');
  }

  /// Waits until the native camera reports it is ready.
  /// Returns false on timeout or when the camera reports an error (see [error]).
  Future<bool> waitUntilReady({ Duration timeout = const Duration(seconds: 10) }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (error != null) return false;
      if (isReady) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    print('Camera_Sensor: camera was not ready after ${timeout.inMilliseconds} ms');
    return false;
  }

  // ------------ Frames ------------ //

  /// Captures one frame. Returns null if the camera is not ready, a capture is
  /// already running, or the capture failed.
  Future<Camera_Frame?> fetchFrame() async {
    final CameraController? cam = controller;
    if (cam == null || !isReady || _isCapturing) return null;

    _isCapturing = true;
    try {
      final String? path = await cam.captureImage();
      if (path == null) return null;

      final File file = File(path);
      final Uint8List bytes = await file.readAsBytes();
      if (deleteAfterRead) {
        try { await file.delete(); } catch (_) {} // the native cache can also be cleared with clearCapturedFrames()
      }
      return Camera_Frame(bytes: bytes, path: path, capturedAt: DateTime.now(), isFrontCamera: useFrontCamera);
    } catch (e) {
      print('Camera_Sensor: frame capture failed: $e');
      return null;
    } finally {
      _isCapturing = false;
    }
  }

  /// Emits frames every [interval] while listened to. A tick is skipped
  /// when the previous capture has not finished yet.
  /// Each capture is a full still capture, so intervals below ~200 ms are rarely reached.
  Stream<Camera_Frame> frameStream({ Duration interval = const Duration(milliseconds: 500) }) {
    late final StreamController<Camera_Frame> streamCtrl;
    Timer? timer;

    Future<void> tick() async {
      if (_isCapturing || streamCtrl.isPaused) return;
      final Camera_Frame? frame = await fetchFrame();
      if (frame != null && !streamCtrl.isClosed) streamCtrl.add(frame);
    }

    streamCtrl = StreamController<Camera_Frame>(
      onListen: () { timer = Timer.periodic(interval, (_) => tick()); },
      onCancel: () { timer?.cancel(); timer = null; },
    );
    return streamCtrl.stream;
  }

  // ------------ Controls ------------ //

  /// Switches cameras. Pass true/false to choose, or nothing to toggle.
  Future<void> switchCamera([ bool? front ]) async {
    final bool target = front ?? !useFrontCamera;
    await controller?.switchCamera(target);
    useFrontCamera = target;
  }

  /// Freezes the preview. [fetchFrame] then returns the frozen frame.
  Future<void> pause() async { await controller?.pauseCamera(); }

  Future<void> resume() async { await controller?.resumeCamera(); }

  /// Deletes every image the native side has written to its cache folder.
  Future<bool> clearCapturedFrames() async => await controller?.deleteAllCapturedPhotos() ?? false;

  /// Drops the controller reference. The preview widget disposes the native camera itself when it leaves the tree.
  void dispose() {
    controller = null;
  }

  // ------------ State ------------ //

  static bool get isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  bool get isReady {
    final CameraController? cam = controller;
    if (cam == null) return false;
    try {
      return !cam.isLoading.value && cam.errorMessage.value == null;
    } catch (_) {
      return false; // notifiers are disposed once the preview widget is gone
    }
  }

  bool get isPaused {
    try { return controller?.isPaused.value ?? false; } catch (_) { return false; }
  }

  String? get error {
    try { return controller?.errorMessage.value; } catch (_) { return null; }
  }

  bool useFrontCamera;
  bool deleteAfterRead;
  CameraPreviewFit fit;
  CameraResolutionPreset previewPreset;
  CameraResolutionPreset capturePreset;
  CameraCaptureMode captureMode;

  CameraController? controller = null;
  bool _isCapturing = false;
}
