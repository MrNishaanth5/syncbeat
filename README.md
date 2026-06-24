# SyncBeat — Build Guide

## What You Have
A complete Flutter project. Follow these steps to build an APK you can install on Android.

---

## Step 1 — Install Flutter (one-time, ~10 minutes)

1. Go to: https://flutter.dev/docs/get-started/install/windows
   (or Linux/Mac if that's your OS)

2. Download Flutter SDK → extract to a folder, e.g. `C:\flutter`

3. Add Flutter to your PATH:
   - Windows: Search "Environment Variables" → Edit PATH → Add `C:\flutter\bin`

4. Open a new terminal and run:
   ```
   flutter doctor
   ```
   Fix any issues it shows (mainly: install Android Studio or Android SDK)

---

## Step 2 — Install Android Studio (for Android SDK)

1. Download from: https://developer.android.com/studio
2. Install it, then open it once to let it download the Android SDK
3. Run `flutter doctor` again — it should show ✓ for Android toolchain

---

## Step 3 — Build the APK

Open a terminal, navigate to the syncbeat folder, then run:

```bash
# Go into the project folder
cd syncbeat

# Get all dependencies
flutter pub get

# Build the APK
flutter build apk --release
```

Wait 2–5 minutes for the first build.

---

## Step 4 — Install on your Android phone

After build succeeds, your APK is at:
```
syncbeat/build/app/outputs/flutter-apk/app-release.apk
```

**Option A — USB cable:**
1. Enable Developer Options on your phone (Settings → About Phone → tap Build Number 7 times)
2. Enable USB Debugging
3. Connect phone to PC
4. Run: `flutter install`

**Option B — Transfer the APK file:**
1. Copy `app-release.apk` to your phone via USB / Google Drive / WhatsApp
2. Open the file on your phone
3. Allow "Install from unknown sources" when prompted
4. Install!

---

## Using the App (Demo Mode)

The app launches in **Demo Mode** by default — no server needed.

**As Host:**
1. Tap "Create Room" → you get a 6-digit code (e.g. XK7F2A)
2. Share the code with friends
3. Tap the folder icon to pick a local music file (MP3, WAV, etc.)
4. Tap Play — music starts

**As Guest:**
1. Tap "Join Room" → type the 6-digit code → Join
2. Wait for host to play something
3. Audio plays automatically in sync

---

## Connecting to a Real Server (for multi-device sync)

In Demo Mode, sync only works on one device. For real multi-device sync:

1. Deploy the backend (see `server/` folder or use Railway/Render for free hosting)
2. Open `lib/features/room/room_provider.dart`
3. Change these two lines:
   ```dart
   const String kServerBaseUrl = 'https://your-server.com';
   const String kServerWsUrl  = 'wss://your-server.com';
   const bool kDemoMode = false;
   ```
4. Rebuild: `flutter build apk --release`

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `flutter doctor` shows Android SDK missing | Open Android Studio → SDK Manager → install API 34 |
| Build fails with Gradle error | Run `flutter clean` then `flutter pub get` then build again |
| APK won't install on phone | Enable "Install unknown apps" in phone settings |
| Audio doesn't play | Make sure you picked a file with the folder icon first |
| `JAVA_HOME not set` | Install JDK 17 from https://adoptium.net |

---

## Project Structure
```
syncbeat/
├── lib/
│   ├── main.dart                    ← App entry point
│   ├── core/
│   │   ├── sync_engine.dart         ← NTP clock sync
│   │   ├── audio_controller.dart    ← Audio playback + drift fix
│   │   └── websocket_client.dart    ← WebSocket connection
│   ├── features/room/
│   │   └── room_provider.dart       ← Room state + host controls
│   └── ui/screens/
│       ├── home_screen.dart         ← Create/Join screen
│       └── room_screen.dart         ← Player UI
├── android/                         ← Android config
└── pubspec.yaml                     ← Dependencies
```
