import 'package:communist_plant/rem/circadian_tracker.dart';
import 'package:communist_plant/rem/screen_size.dart';
import 'package:communist_plant/sensors/camera_sensor.dart';
import 'package:communist_plant/services/neural_tts.dart';
import 'package:communist_plant/services/ollama_service.dart';
import 'package:communist_plant/storage/file_storage.dart';

// ------------ Services Section ------------ //

Ollama_Service? olm_service = null;
Neural_TTS? tts_service = null;

// ------------ Storage Section ------------ //

File_Storage? file_storage = null;

// ------------ Sensors Section ------------ //

Camera_Sensor? camera_sensor = null;

// ------------ Remaining Section ------------ //

Screen_Size? SS = null;
Circadian_Tracker? circadian = null;
