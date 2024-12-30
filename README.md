# Flutter Android Motion Photo

A Flutter application that captures motion photos similar to iOS Live Photos and Google Camera's Motion Photos feature. Currently tested only on Android. The app records a short video clip (including frames and audio) before and after the user clicks the shutter button. At present, there is no separate still image capture, as capturing a still image requires pausing the video buffer, which would create an undesirable 0.5 second gap in the motion photo sequence.

## Features

- Captures "motion photos" combining video frames and audio, automatically saved to your device's gallery
- Creates seamless motion photos by buffering footage before and after the capture moment
    - Configurable duration with default settings of 3 seconds pre-capture and 2 seconds post-capture at 720p resolution
    - Efficient frame buffering using temporary files enables extended durations without memory constraints
- Includes traditional photo and video capture modes

### Limitations 

1. No seperate still image captured
2. Audio is mono, not stereo (seems like a limitation with flutter_sound on android device)

### Installation
1. Install Flutter by following the [official installation guide](https://docs.flutter.dev/get-started/install)

2. Clone this repository:
   ```bash
   git clone https://github.com/EllenGYY/flutter_android_motion_photo.git
   ```

3. Navigate to the project directory:
   ```bash
   cd android_motion_photo
   ```

4. Install dependencies:
   ```bash
   flutter pub get
   ```

5. Run the app:
   ```bash
   flutter run
   ```

Note: Make sure you have an Android device connected or an emulator running before executing `flutter run`.

### Dependencies

This project uses the following main dependencies:

- camera: ^0.11.0+2 - For camera access and control
- circular_buffer: ^0.12.0 - For managing video buffer
- gal: ^2.3.1 - For gallery integration
- ffmpeg_kit_flutter: ^6.0.3 - For video processing
- flutter_sound: ^9.17.8 - For audio handling

Requires Android version 7.0 (API level 24) or higher.

### Permissions
The app requires the following permissions on Android:

- `android.permission.CAMERA` - For accessing the device camera
- `android.permission.RECORD_AUDIO` - For recording audio during motion photo capture
- `android.permission.WRITE_EXTERNAL_STORAGE` - For saving photos/videos to gallery

### Test Device
The project is tested on Samsung Galaxy Tab S6 Lite.

### Future Enhancements
- Implement an in-app gallery with native motion photo playback capabilities (similar to live photo)
- Add user-customizable settings for capture duration and video resolution

