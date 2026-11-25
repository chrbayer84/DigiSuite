# Privacy Policy — DigiSuite

**Effective date:** November 25, 2026  
**App:** DigiSuite (bundle identifier `com.github.chrbayer84.DigiSuite`)  
**Developer:** Christian Bayer, WA4YA  
**Contact:** chrbayer84@googlemail.com

This policy covers the radio modem functionality currently being developed in this iOS app. It replaces the prior ON4KST chat privacy description.

## Data handled by the app

| Data | Purpose | Processing and storage |
|---|---|---|
| Microphone audio | Receive radio modem signals, currently Robot 36 SSTV | Processed on-device while reception is active; raw audio is not saved by the app |
| Selected image | Prepare a Robot 36 transmission | Read through the iOS Photos picker and processed on-device; the app does not upload it |
| Generated transmit audio | Play encoded modem audio to the active iOS output route | Generated and played on-device; the app does not upload it |
| Received pictures | Display and provide local picture history | Stored in the app's on-device Application Support directory |
| Decoded text and metadata | Reserved for future text modem history | Intended to be stored locally on-device when text decoders are implemented |

The app does not currently use an account, backend, cloud sync, advertising, analytics, or tracking. The developer does not receive data handled by the app.

## Audio and photos

The app requests microphone access when you start reception. Audio is analyzed locally to detect and decode Robot 36 signals and to draw the waterfall. The first implementation is foreground-only. If microphone permission is denied, reception cannot start; you can change permission in iOS Settings.

For transmission, you choose an image using the system Photos picker. The app resizes and encodes it on-device, then plays the resulting audio through the active iOS output route. Radio PTT control is not implemented.

Audio routing and processing are provided by iOS and the selected hardware. Any handling by an operating-system service or connected accessory is governed by its provider's practices.

## Local history and retention

Received pictures and their metadata are stored locally in the app's Application Support directory. Future decoded text history is also planned as local-only storage. You can delete entries from the History tab; uninstalling the app removes its application data according to iOS behavior. No history is sent to the developer or a server.

## Your choices

- Grant or revoke microphone access in iOS Settings.
- Choose which image to transmit through the system Photos picker.
- Delete local history through the app when history deletion controls are available, or uninstall the app to remove its local data.
- Contact the developer with privacy questions at **chrbayer84@googlemail.com**.

## Changes and contact

This policy will be updated as modem features and data handling change. Material changes will be reflected in the app's release information.

Christian Bayer, WA4YA  
Email: chrbayer84@googlemail.com  
GitHub: https://github.com/chrbayer84/DigiSuite/issues
