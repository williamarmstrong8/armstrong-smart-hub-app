# Armstrong Hub (iOS / iPad)

The native app for [Armstrong Hub](https://github.com/williamarmstrong8/armstrong-smart-hub). It signs in to the hub
(`armstrong-smart-hub.vercel.app`) and uses its `/api/mobile` API; every secret stays on the hub.

- **iPhone:** tabs for the agent, home, finance, calendar and habits.
- **iPad:** an always-on dashboard with "Hey Jarvis", a hands-free voice agent.

## Hey Jarvis

- Wake word runs on-device with [openWakeWord](https://github.com/dscripka/openWakeWord) (ONNX Runtime). The models in
  `Features/Voice/WakeWordModels` are from its v0.5.1 release; the pretrained models are licensed CC BY-NC-SA 4.0
  (non-commercial).
- After the wake word, the app opens a realtime WebSocket to the AI Gateway with a short-lived secret minted by the hub
  (`/api/mobile/voice/session`), streams mic audio, and plays the reply as it streams back.
- Tool calls run on the hub (`/api/mobile/voice/tool`), which returns the card to show. Jev
  (`/api/mobile/voice/intent`) guesses the screen early so the UI can morph before the tool finishes.

## Build

Open `Armstrong-Smart-Hub-App.xcodeproj` in Xcode and run. ONNX Runtime comes in through Swift Package Manager.
