import 'dart:async';

import 'package:circular_buffer/circular_buffer.dart';
// import 'package:exif/exif.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:gal/gal.dart';
// import 'package:image/image.dart' as imglib;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'dart:isolate';

// Different modes for the camera
enum CameraMode {
  photo, // Single photo mode
  video, // Video recording mode
  motion, // Motion photo mode
}

// Message data for isolate
class VideoProcessMessage {
  final List<CameraImage> frames;
  final String outputPath;
  final RootIsolateToken token;
  VideoProcessMessage(this.frames, this.outputPath, this.token);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock UI to portrait only
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  final cameras = await availableCameras();
  runApp(MyApp(cameras: cameras));
}

class MyApp extends StatefulWidget {
  final List<CameraDescription> cameras;
  const MyApp({super.key, required this.cameras});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const int framesPerSegment = 30; // 1 second per segment = 30 fps
  static const int maxSegments = 5; // total 5s
  static const int recordTimeAfterClick = 2; // 2s after click

  static const int frameWidth = 1280;
  static const int frameHeight = 720;
  static const int frameRate = 30;
  static const int sampleRate = 44100;

  late CameraController _controller;
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  late Future<void> _initializeControllerFuture;
  StreamSubscription? _mRecordingDataSubscription;
  StreamController<Uint8List> _recordingDataController =
      StreamController<Uint8List>();

  int _selectedCameraIndex = 0;
  bool _isTakingPicture = false;
  bool _isTakingVideo = false;
  bool _isTakingMotionPhoto = false;
  Timer? _recordingTimeoutTimer;

  // Orientation? _currentOrientation;
  // Current camera mode
  CameraMode _currentMode = CameraMode.photo;

  late CircularBuffer<CameraImage> _frameBuffer;
  late CircularBuffer<String> _videoSegments;
  late CircularBuffer<int> _audioBuffer;

  bool _isStreaming = false;

  // Get the display text for current mode
  String get _modeText {
    switch (_currentMode) {
      case CameraMode.photo:
        return 'Photo';
      case CameraMode.video:
        return 'Video';
      case CameraMode.motion:
        return 'Motion';
    }
  }

  Future<void> initAudioStream() async {
    await _recorder.openRecorder();

    _mRecordingDataSubscription =
        _recordingDataController.stream.listen((Uint8List buffer) {
      // Add each byte from the buffer to the circular buffer
      for (int byte in buffer) {
        _audioBuffer.add(byte);
      }
    });

    await _recorder.startRecorder(
        toStream: _recordingDataController.sink,
        codec: Codec.pcm16,
        sampleRate: sampleRate,
        numChannels: 1);

    await _recorder.pauseRecorder();
  }

  // Switch to next mode
  Future<void> _switchMode() async {
    setState(() {
      _currentMode = CameraMode
          .values[(_currentMode.index + 1) % CameraMode.values.length];
    });
    if (_currentMode == CameraMode.motion) {
      await _startFrameStream();
      await _recorder.resumeRecorder();
    } else {
      if (_isStreaming) {
        await _stopFrameStream();
        _frameBuffer.clear();
        await _recorder.pauseRecorder();
        _audioBuffer.clear();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _frameBuffer = CircularBuffer(framesPerSegment);
    _videoSegments = CircularBuffer(maxSegments);
    _audioBuffer =
        CircularBuffer(44100 * 2 * maxSegments); // 44100Hz PCM 16bit Mono
    _initCamera(_selectedCameraIndex);
    _setupCamera();
    initAudioStream();
  }

  Future<void> _setupCamera() async {
    try {
      await _initializeControllerFuture;
      // Lock the camera capture orientation after initialization
      await _controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      // Restart stream if in motion mode
      if (_currentMode == CameraMode.motion) {
        await _startFrameStream();
      }
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  void _initCamera(int cameraIndex) async {
    _controller = CameraController(
      widget.cameras[cameraIndex],
      ResolutionPreset.high,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    _initializeControllerFuture = _controller.initialize();
  }

  void _switchCamera() async {
    // If in motion mode, stop and restart buffer
    if (_currentMode == CameraMode.motion) {
      if (_isStreaming) {
        _frameBuffer.clear();
        _audioBuffer.clear();
      }
    }

    // Dispose current camera
    await _controller.dispose();

    // Switch to next camera
    setState(() {
      _selectedCameraIndex = (_selectedCameraIndex + 1) % widget.cameras.length;
    });

    // Wait for new camera to initialize
    _initCamera(_selectedCameraIndex);
    _setupCamera();
  }

  Future<void> _takePhoto() async {
    if (_isTakingPicture) return;

    XFile? photo;
    File? photoFile;

    try {
      setState(() {
        _isTakingPicture = true;
      });

      // Take the picture
      photo = await _controller.takePicture();
      photoFile = File(photo.path);

      if (await photoFile.exists()) {
        // Save to gallery
        await Gal.putImage(photo.path, album: 'aaa_motion_photos');
        print('[custom]Photo saved to gallery');
      } else {
        print('[custom]Photo file not found after capture');
      }
    } catch (e) {
      print('[custom]Error taking photo: $e');
    } finally {
      // Clean up the temporary file
      try {
        if (photoFile != null && await photoFile.exists()) {
          await photoFile.delete();
        }
      } catch (e) {
        print('[custom]Error cleaning up photo file: $e');
      }

      // Always reset the taking picture state
      setState(() {
        _isTakingPicture = false;
      });
    }
  }

  Future<void> _startCurrentRecording() async {
    if (_isTakingVideo) return;

    try {
      setState(() {
        _isTakingVideo = true;
      });
      print('[custom]Starting recording at ${DateTime.now()}');
      // Start recording
      await _controller.startVideoRecording();
      print('[custom]Start completed at ${DateTime.now()}');
      _recordingTimeoutTimer?.cancel();
      _recordingTimeoutTimer = Timer(const Duration(minutes: 10), () {
        print('[custom]Recording timeout reached');
        _stopCurrentRecording();
      });
    } catch (e) {
      print('[custom]Error starting recording video: $e');
      setState(() {
        _isTakingVideo = false;
      });
    }
  }

  Future<void> _stopCurrentRecording() async {
    if (!_isTakingVideo || !_controller.value.isRecordingVideo) return;

    XFile? video;
    File? tempFile;
    File? renamedFile;

    try {
      // Stop recording
      video = await _controller.stopVideoRecording();
      tempFile = File(video.path);

      if (await tempFile.exists()) {
        final String newPath = video.path.replaceAll('.temp', '.mp4');
        renamedFile = await tempFile.rename(newPath);

        // Save to gallery
        await Gal.putVideo(newPath, album: 'aaa_motion_photos');
        print('[custom]Video saved to gallery');
      }
    } catch (e) {
      print('[custom]Error in recording video: $e');
    } finally {
      // Clean up files regardless of success or failure
      _recordingTimeoutTimer?.cancel();
      _recordingTimeoutTimer = null;
      try {
        if (renamedFile != null && await renamedFile.exists()) {
          await renamedFile.delete();
        } else if (tempFile != null && await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (e) {
        print('[custom]Error cleaning up files: $e');
      }

      // Always reset recording state
      setState(() {
        _isTakingVideo = false;
      });
    }
  }

  Future<void> _startFrameStream() async {
    if (_isStreaming) return;

    try {
      await _controller.startImageStream((CameraImage image) {
        _processFrame(image);
      });
      setState(() {
        _isStreaming = true;
      });
    } catch (e) {
      print('[custom]Error starting stream: $e');
    }
  }

  Future<void> _stopFrameStream() async {
    if (!_isStreaming) return;

    try {
      await _controller.stopImageStream();
      setState(() {
        _isStreaming = false;
      });
    } catch (e) {
      print('[custom]Error stopping stream: $e');
    }
  }

  Future<void> _takeMotionPhoto() async {
    if (_isTakingMotionPhoto) return;

    try {
      setState(() {
        _isTakingMotionPhoto = true;
      });

      setState(() {
        _isTakingVideo = true;
      });
      // Wait for recordTimeAfterClick seconds to capture frames after click
      await Future.delayed(const Duration(seconds: recordTimeAfterClick));
      // Pause streaming while saving buffer
      await _stopFrameStream();
      await _recorder.pauseRecorder();
      setState(() {
        _isTakingVideo = false;
      });
      await _saveCurrentBuffer();
      // Restart streaming
      _frameBuffer.clear();
      _videoSegments.clear();
      _audioBuffer.clear();
      await _startFrameStream();
      await _recorder.resumeRecorder();
    } catch (e) {
      print('[custom]Error taking photo: $e');
    } finally {
      setState(() {
        _isTakingMotionPhoto = false;
      });
    }
  }

  // Isolate for video processing
  static Future<void> _processYUVInIsolate(VideoProcessMessage message) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(message.token);
    final file = File(message.outputPath);
    final sink = file.openWrite();

    for (var image in message.frames) {
      final width = image.width;
      final height = image.height;
      // Extract Y plane
      final yPlane = image.planes[0].bytes;

      // Extract interleaved UV plane
      final uvPlane = image.planes[1].bytes;

      // Get last byte of V plane
      final lastByteV = image.planes[2].bytes.last;

      // Calculate chroma size
      final uvSize = (width ~/ 2) * (height ~/ 2);

      // Separate U and V components
      final uPlane = Uint8List(uvSize);
      final vPlane = Uint8List(uvSize);

      for (int i = 0; i < uvSize; i++) {
        uPlane[i] = uvPlane[i * 2]; // Extract U
        vPlane[i] =
            i == uvSize - 1 ? lastByteV : uvPlane[i * 2 + 1]; // Extract V
      }

      // Write Y, U, and V planes to file
      sink.add(yPlane); // Y data
      sink.add(uPlane); // U data
      sink.add(vPlane); // V data
    }

    await sink.close();
  }

  Future<void> _processFrame(CameraImage image) async {
    _frameBuffer.add(image);

    // Every second, create a new video segment
    if (_frameBuffer.isFilled) {
      final frames = List<CameraImage>.from(_frameBuffer);
      _frameBuffer.clear();
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${tempDir.path}/segment_$timestamp.yuv';

      final rootIsolateToken = RootIsolateToken.instance!;

      // Start video processing in isolate
      await Isolate.run(() => _processYUVInIsolate(
          VideoProcessMessage(frames, outputPath, rootIsolateToken)));

      // Store the path that will be overwritten (if buffer is full)
      String? oldPath = _videoSegments.isFilled ? _videoSegments.first : null;

      // Add new segment path to circular buffer
      // print('[custom]Adding new segment: $outputPath');
      _videoSegments.add(outputPath);

      // Clean up the overwritten segment if there was one
      if (oldPath != null) {
        try {
          // print('[custom]Deleting old segment: $oldPath');
          await File(oldPath).delete();
        } catch (e) {
          print('[custom]Error cleaning up old segment: $e');
        }
      }
    }
  }

  Future<void> _saveCurrentBuffer() async {
    if (_videoSegments.isEmpty && _frameBuffer.isEmpty) return;

    try {
      await Future.delayed(const Duration(milliseconds: 500));
      // Print timestamp when motion photo capture starts
      // print('[custom]Starting motion photo capture at ${DateTime.now()}');
      // Combine all YUV segments into one file
      final List<String> allSegments = List<String>.from(_videoSegments);
      // save audio to file
      print('[custom]Audio data: ${_audioBuffer.length}');
      final audioData = Uint8List(_audioBuffer.length);
      for (var i = 0; i < _audioBuffer.length; i++) {
        audioData[i] = _audioBuffer[i];
      }
      // print('[custom]All segments:');
      // for (int i = 0; i < allSegments.length; i++) {
      //   print('[custom]Segment $i: ${allSegments[i]}');
      // }
      // Rename segments with index for safety
      // for (int i = 0; i < allSegments.length; i++) {
      //   final segment = allSegments[i];
      //   final segmentFile = File(segment);
      //   if (await segmentFile.exists()) {
      //     final newPath =
      //         segment.replaceAll(RegExp(r'\d+\.yuv'), 'segment_${i}_safe.yuv');
      //     await segmentFile.rename(newPath);
      //     allSegments[i] = newPath;
      //   }
      // }
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outputPath =
          '${(await getTemporaryDirectory()).path}/final_$timestamp.mp4';
      final outputPathYUV =
          '${(await getTemporaryDirectory()).path}/final_$timestamp.yuv';
      final tempPathYUV = '${(await getTemporaryDirectory()).path}/temp.yuv';
      final tempPathAudio =
          '${(await getTemporaryDirectory()).path}/temp_audio.pcm';

      if (_frameBuffer.isNotEmpty) {
        print('[custom] _frameBuffer.length: ${_frameBuffer.length}');
        final rootIsolateToken = RootIsolateToken.instance!;
        final frames = List<CameraImage>.from(_frameBuffer);
        // Start video processing in isolate
        await Isolate.run(() => _processYUVInIsolate(
            VideoProcessMessage(frames, tempPathYUV, rootIsolateToken)));
      }

      allSegments.add(tempPathYUV);

      final outputFile = File(outputPathYUV);
      final sink = outputFile.openWrite();

      try {
        // Write all segments sequentially
        for (final segment in allSegments) {
          final segmentFile = File(segment);
          if (await segmentFile.exists()) {
            var bytes = await segmentFile.readAsBytes();
            if (segment == allSegments.first) {
              if (await File(tempPathYUV).exists() &&
                  allSegments.length == maxSegments + 1) {
                final tempSize = await File(tempPathYUV).length();
                bytes = bytes.sublist(tempSize);
              }
            }
            sink.add(bytes);
          }
        }
      } finally {
        await sink.close();
      }

      // Check if output file exists
      double yuvSize;
      if (!await File(outputPathYUV).exists()) {
        print('[custom]Output YUVfile not found: $outputPathYUV');
        return;
      } else {
        final yuvFile = File(outputPathYUV);
        yuvSize = await yuvFile.length() /
            (frameWidth * frameHeight * frameRate * 1.5);
        print('[custom]YUV file size: $yuvSize seconds');
      }

      // // Save YUV file to media folder
      // final galleryDir = await getExternalStorageDirectory();
      // if (galleryDir != null) {
      //   final mediaPath = '${galleryDir.path}/motion_$timestamp.yuv';
      //   await File(outputPathYUV).copy(mediaPath);
      //   print('[custom]Saved YUV file to: $mediaPath');
      // }

      await File(tempPathAudio).writeAsBytes(audioData);
      double audioSize = audioData.length / (sampleRate * 2.0);
      print('[custom]Audio file size: $audioSize seconds');
      double duration = audioSize < yuvSize ? audioSize : yuvSize;
      print('[custom]Final duration: $duration seconds');

      print(
          '[custom]sensorOrientation: ${widget.cameras[_selectedCameraIndex].sensorOrientation}');

      var rotateCommand = '';
      if (widget.cameras[_selectedCameraIndex].sensorOrientation == 90) {
        rotateCommand = "transpose=1";
      } else if (widget.cameras[_selectedCameraIndex].sensorOrientation ==
          270) {
        rotateCommand = "transpose=2";
      }

      // FFmpeg command with PCM audio
      final session = await FFmpegKit.execute(
          '-f rawvideo -pix_fmt yuv420p -s:v ${frameWidth}x$frameHeight -r $frameRate -i $outputPathYUV '
          '-f s16le -ar 44100 -ac 1 -i $tempPathAudio '
          '-af "asetpts=PTS-STARTPTS,atrim=start=-$duration" '
          '-vf "setpts=PTS-STARTPTS,trim=start=-$duration,$rotateCommand " '
          '-c:v mpeg4 -c:a aac -strict experimental '
          '$outputPath');

      final returnCode = await session.getReturnCode();
      if (ReturnCode.isSuccess(returnCode)) {
        print('[custom]FFmpeg processing completed successfully');
      } else {
        print('[custom]FFmpeg processing failed with return code: $returnCode');
        final logs = await session.getLogs();
        print('[custom]FFmpeg logs: ${logs.length}');
        final logList = logs.map((log) => log.getMessage()).toList();
        for (final log in logList) {
          print('[custom]FFmpeg log: $log');
        }
        return;
      }

      await Gal.putVideo(outputPath, album: 'aaa_motion_photos');
      await File(outputPath).delete();
      await File(outputPathYUV).delete();
    } catch (e) {
      print('[custom]Error saving buffer: $e');
    } finally {
      for (final segment in _videoSegments) {
        try {
          if (await File(segment).exists()) {
            await File(segment).delete();
          }
        } catch (e) {
          print('[custom]Error cleaning up segment: $e');
        }
      }
      _frameBuffer.clear();
      _videoSegments.clear();
    }
  }

  @override
  void dispose() {
    // Clean up any remaining segment files
    for (final segment in _videoSegments) {
      try {
        File(segment).deleteSync();
      } catch (e) {
        print('[custom]Error cleaning up in dispose: $e');
      }
    }
    _recordingTimeoutTimer?.cancel();
    _stopFrameStream();
    _recorder.closeRecorder();
    _frameBuffer.clear();
    _audioBuffer.clear();
    // _isBuffering = false;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Get the current orientation
    // _currentOrientation = MediaQuery.of(context).orientation;

    return MaterialApp(
        home: Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // 4:3 aspect ratio box
                AspectRatio(
                  aspectRatio: 3 / 4,
                  child: Container(
                    color: Colors.black,
                    child: FutureBuilder<void>(
                      future: _initializeControllerFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.done) {
                          return LayoutBuilder(
                            builder: (context, constraints) {
                              // Get the camera preview aspect ratio
                              final sensorOrientation = widget
                                  .cameras[_selectedCameraIndex]
                                  .sensorOrientation;
                              final previewAspectRatio =
                                  (sensorOrientation == 90 ||
                                          sensorOrientation == -90 ||
                                          sensorOrientation == 270 ||
                                          sensorOrientation == -270)
                                      ? 1 / _controller.value.aspectRatio
                                      : _controller.value.aspectRatio;
                              // Get the container's aspect ratio (3:4)
                              const containerAspectRatio = 3 / 4;

                              return Center(
                                child: AspectRatio(
                                  aspectRatio: previewAspectRatio,
                                  child: Container(
                                    constraints: BoxConstraints(
                                      maxWidth: previewAspectRatio >
                                              containerAspectRatio
                                          ? constraints.maxWidth
                                          : constraints.maxHeight *
                                              previewAspectRatio,
                                      maxHeight: previewAspectRatio >
                                              containerAspectRatio
                                          ? constraints.maxWidth /
                                              previewAspectRatio
                                          : constraints.maxHeight,
                                    ),
                                    child: Transform.scale(
                                      scaleX: widget
                                                  .cameras[_selectedCameraIndex]
                                                  .lensDirection ==
                                              CameraLensDirection.front
                                          ? -1.0
                                          : 1.0,
                                      child: CameraPreview(_controller),
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        } else {
                          return const Center(
                              child: CircularProgressIndicator());
                        }
                      },
                    ),
                  ),
                ),

                // Row of two buttons
                Expanded(
                  child: Container(
                    color: Colors.grey[500],
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton(
                          onPressed: (_isTakingPicture ||
                                  _isTakingVideo ||
                                  _isTakingMotionPhoto)
                              ? null
                              : () async {
                                  await _switchMode();
                                },
                          child: Text(_modeText),
                        ),
                        ElevatedButton(
                          onPressed: (_isTakingPicture ||
                                  _isTakingMotionPhoto ||
                                  (_currentMode == CameraMode.motion &&
                                      !_isStreaming))
                              ? null
                              : () {
                                  if (_currentMode == CameraMode.video) {
                                    if (!_isTakingVideo) {
                                      _startCurrentRecording();
                                    } else {
                                      _stopCurrentRecording();
                                    }
                                  } else if (_currentMode ==
                                      CameraMode.motion) {
                                    _takeMotionPhoto();
                                    //_saveCurrentBuffer();
                                  } else {
                                    _takePhoto();
                                  }
                                },
                          child: Text(_currentMode == CameraMode.video
                              ? (_isTakingVideo ? "Stop" : "Start")
                              : "Capture"),
                        ),
                        IconButton(
                          onPressed: (_isTakingPicture ||
                                  _isTakingVideo ||
                                  _isTakingMotionPhoto)
                              ? null
                              : widget.cameras.length > 1
                                  ? _switchCamera
                                  : null,
                          icon: const Icon(CupertinoIcons.switch_camera),
                          iconSize: 32,
                          color: Colors.black,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            // Add recording indicator
            if (_isTakingVideo)
              Positioned(
                top: 16,
                right: 16,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    ));
  }
}
