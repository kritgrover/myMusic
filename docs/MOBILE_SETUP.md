# Phone setup and playback checks

The native phone app uses the existing music backend. It can play completed
device downloads without the backend. Search, streaming, and new downloads need
the backend to be reachable.

Background playback, lock-screen controls, and headset controls use
`audio_service`; the music audio session uses `audio_session`. This configuration
needs verification on real phones. A successful desktop or Android build does
not verify iPhone playback.

## Connect a phone to the backend on this Windows PC

1. Put the PC and phone on the same trusted Wi-Fi network. Avoid a guest network
   that isolates devices. The PC may use Ethernet if it is on the same network.
2. Keep the existing backend configuration, database, and download directory. If
   it is not already running, start it from the repository's backend directory:

   ```powershell
   Set-Location E:\myMusic\backend
   py -3.12 app.py
   ```

   Use the Python environment in which the backend requirements are installed.
   `app.py` listens on `0.0.0.0:8000`. Do not start a second backend on the same
   port. Backend prerequisites and `.env` setup are in the root README.
3. Run `ipconfig` on the PC and find the IPv4 address of its active Wi-Fi or
   Ethernet adapter. Use that address in `http://<PC-IP>:8000`, for example
   `http://192.168.1.20:8000`. The example is not this PC's assigned address.
   `localhost` on the phone refers to the phone, not this PC.
4. Open that address in the phone's browser. The backend should return
   `{"message":"Music Download API","status":"running"}`. If it does not,
   check that the backend is running, both devices share the same LAN, and
   Windows Firewall permits the backend's TCP port 8000 on the private network.
   Do not disable the firewall. Only expose the port to the local subnet for
   this setup; router port forwarding is unnecessary.
5. On the app's sign-in screen, tap **Change server**, enter the same address,
   and tap **Connect** to check and save it. Then sign in with your existing account. On iPhone,
   allow the Local Network prompt. If access was denied, enable myMusic under
   Settings → Privacy & Security → Local Network and retry.

The app remembers the selected server. Sign-in sessions and device downloads
are scoped to that server and account. A different server address is a different
storage scope, so keep the PC's address stable (a router DHCP reservation helps).
The PC and backend must remain awake for streaming. A connection check confirms
reachability from that device; testing the URL on the PC alone does not.

## Install the native iPhone app

Building and signing iOS apps requires macOS and Xcode. Windows cannot produce
or install a signed iPhone app from this source. Safari can open a hosted web
build, but it does not validate the native app's background playback or device
download implementation.

On a Mac with Flutter, Xcode, and CocoaPods configured:

1. Copy or check out this repository on the Mac. Keep backend secrets on the
   backend PC; the phone only needs the server URL and the user's account login.
2. Install Flutter and iOS dependencies:

   ```sh
   cd /path/to/myMusic/frontend
   flutter pub get
   cd ios
   pod install
   open Runner.xcworkspace
   ```

3. In Xcode, select the Runner target and configure Signing & Capabilities with
   your Apple development team. If Xcode requires a unique bundle identifier,
   choose one owned by your team. The repository leaves signing credentials and
   production bundle identity unset.
4. Connect and trust the iPhone, enable Developer Mode when required, and select
   it as the Xcode run destination. Complete any device preparation requested by
   Xcode.
5. From the `frontend` directory, identify the phone and install a release build
   for playback checks away from the debugger:

   ```sh
   flutter devices
   flutter run --release -d <iphone-device-id>
   ```

   Select the backend in the app after installation. To supply an initial server
   address at build time instead, append
   `--dart-define=API_BASE_URL=http://<PC-IP>:8000`.

The iOS project declares the audio background mode, a local-network purpose,
and App Transport Security exceptions for private IPv4 networks and loopback.
Public servers require HTTPS. The local exceptions support HTTP playback from
the PC without disabling transport security globally.

See [Flutter's iOS setup](https://docs.flutter.dev/platform-integration/ios/setup)
and [Apple's Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

## Install the Android test app

With Flutter and the Android SDK configured:

```powershell
Set-Location E:\myMusic\frontend
flutter pub get
flutter build apk --debug
```

Install `frontend/build/app/outputs/flutter-apk/app-debug.apk` on a phone, or use
`flutter run -d <android-device-id>` with USB debugging enabled. Choose the
server address in the app. The Android emulator uses `http://10.0.2.2:8000` to
reach the host PC; a physical Android phone uses the PC's LAN address.

Debug and profile Android builds permit HTTP for local server testing. Android
release builds require HTTPS, apart from the player's loopback proxy. Use a
proper HTTPS backend before distributing a release APK; adding an HTTP URL in
the app does not bypass the native release policy. Production signing is not
configured by this change.

## Real-device acceptance checks

Run these on each target phone and record failures with phone model, OS version,
build type, track, and whether playback used streaming or a device download.

- Start a playlist, lock the screen, and let at least two tracks finish. Confirm
  audio continues and advances, and the lock screen shows the current title,
  artist, artwork when available, and playback position.
- Use lock-screen/Control Center or notification play, pause, next, previous,
  and seek. Confirm the app's player and queue stay in sync when reopened.
- Use Bluetooth or wired headset media controls. Disconnect the headphones and
  confirm playback pauses instead of unexpectedly using the speaker.
- During playback, trigger a call or another audio interruption. Confirm audio
  pauses or ducks appropriately, and only resumes when the system permits it.
  If the user paused playback, it must not resume automatically.
- Pause, lock, and resume from system controls. Reopen the app after switching
  among other apps. Confirm there is one player and no duplicate audio.
- Save tracks on the device and wait until they show as complete. Enable
  airplane mode, reopen the app, and play them from Your Library → On this
  device. Check seeking, queue advancement, and background playback.
- While offline, listen to more than 32 tracks, leave the app after a checkpoint,
  and reopen it. Reconnect and confirm the history syncs once, with the original
  listening dates. Repeat across sign-out/sign-in and with a second account to
  confirm history remains private to the original account and server.
- With a large saved collection, cold-launch the offline library and start a
  track before background verification finishes. Confirm the selected track
  starts without waiting for the entire collection; a damaged file must be
  rejected before playback and removed from the available catalog.
- Disconnect Wi-Fi while streaming an uncached track. Confirm the error is
  clear, then reconnect and retry. The PC backend cannot be reached on cellular
  without a separately deployed reachable server.
- Test the smallest target phone screen with the keyboard open and larger text:
  sign in, search, open a playlist, use player controls, and open download
  progress without clipped actions or overflow.

Device downloads currently transfer while the app is running. Background audio
support does not make long-running downloads survive OS suspension, force-quit,
or process termination. Finish saving tracks before testing offline playback.

## Relevant native configuration

- `frontend/ios/Runner/Info.plist`: background audio, local-network privacy,
  private-network transport exceptions, and playlist-cover photo/camera purposes.
- `frontend/ios/Podfile` and `frontend/ios/Flutter/*.xcconfig`: native plugin
  dependency setup.
- `frontend/android/app/src/main/AndroidManifest.xml`: Internet access,
  foreground media service, wake lock, and media button receiver.
- `frontend/android/app/src/main/kotlin/com/example/music_downloader/MainActivity.kt`:
  activity connected to audio_service's shared Flutter engine.
- `frontend/android/app/src/{main,debug,profile}/res/xml/network_security_config.xml`:
  release HTTPS policy and local development overrides.

Native setup follows [audio_service's configuration guide](https://pub.dev/packages/audio_service)
and [Apple's local-network transport requirements](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).
