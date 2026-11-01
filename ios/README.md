# Pi Chat for iOS

A small SwiftUI chat app for the Gemma server on your Pi:

- streams answers token by token, with tokens/s shown under each reply
- model picker (every model on the server: Gemma 4 E2B / E4B, Qwen 3.5 if you added it) and an optional **Thinking** toggle
- attach a photo and ask about it (Gemma 4 is multimodal); photos are downscaled to 1024 px first to keep the Pi fast
- remembers the conversation; tap the pencil icon for a new chat
- tap the title to switch model or turn Thinking on for the next question
- talks to the standard OpenAI-compatible `/v1/chat/completions` API, so it also works with other llama.cpp or OpenAI-style servers

The look follows the Rapid Review design system: ink for every control, electric blue only for the assistant's mark, the focused message box and the chosen model, Instrument Sans for text and JetBrains Mono for model names, in light and dark. The tokens are in `PiChat/Theme.swift`, the shared controls in `PiChat/Components.swift`, and both fonts ship in `PiChat/Fonts` (SIL Open Font License, licences beside them).

The app is about 1,600 lines of Swift with no dependencies. It needs iOS 17 and a Mac with Xcode 15 or newer.

> I wrote this code without being able to compile it (no Xcode where it was written). If Xcode reports an error, paste it into a chat with Claude and it will be quick to fix.

## Build and install on your iPhone

### Option A: XcodeGen (one command)

```bash
brew install xcodegen
cd ios
xcodegen            # creates PiChat.xcodeproj from project.yml
open PiChat.xcodeproj
```

### Option B: plain Xcode

1. **File > New > Project > iOS > App.** Name it `PiChat`, Interface **SwiftUI**, Storage **None**.
2. Delete the generated `ContentView.swift` and `PiChatApp.swift`.
3. Drag the seven `.swift` files and the `Fonts` folder from `ios/PiChat/` into the project (check "Copy items if needed" and the PiChat target). The app registers the fonts itself, so no Info.plist entry is needed.
4. Target **PiChat > General**: set *Minimum Deployments* to iOS 17.0.
5. Target **PiChat > Info**, add two keys:
   - `App Transport Security Settings` > `Allow Arbitrary Loads` = `YES` (the Pi serves plain HTTP on your LAN)
   - `Privacy - Local Network Usage Description` = `Pi Chat talks to the model on your Raspberry Pi.`

### Then, for both options

1. **Signing & Capabilities**: pick your Team. A free Apple ID works, but apps signed with one expire after 7 days (just hit Run again). A paid developer account gives you 1 year.
2. If Xcode complains about the bundle identifier, change `com.example.pichat` to something unique.
3. Connect your iPhone, select it as the run destination, and press **Run**. On first install, enable **Settings > Privacy & Security > Developer Mode** on the phone and trust the developer certificate under **Settings > General > VPN & Device Management**.
4. In the app, open **Settings** (the sliders icon, top right), enter `http://pi-llm.local:8080` (or `http://<pi-ip>:8080`) and the API key from the installer, then tap **Test connection**. Allow local network access when iOS asks.

## No Mac?

You don't need this app. The Pi's built-in web UI works well in Safari: open `http://pi-llm.local:8080`, then **Share > Add to Home Screen** to get an app icon that opens full-screen. Any App Store chat client that lets you set a custom OpenAI-compatible base URL and API key also works. Use `http://pi-llm.local:8080/v1` as the base URL and `gemma-4-e2b` or `gemma-4-e4b` as the model name.
