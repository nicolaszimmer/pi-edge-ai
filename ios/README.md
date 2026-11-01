# Pi Chat for iOS

A small SwiftUI chat app for the Gemma server on your Pi:

- streams answers token by token, with tokens/s shown under each reply
- renders answers properly: headings, lists, tables, quotes, code blocks, and LaTeX maths, inline (`$a^2$`, `\(…\)`) and on its own line (`$$…$$`, `\[…\]`), typeset with [SwiftMath](https://github.com/mgriebling/SwiftMath)
- keeps every chat: tap the clock icon to see them all by day, search them, open one, or swipe to rename or delete it. Tap the pencil icon for a new chat. An answer keeps arriving while you look at another chat
- model picker (every model on the server: Gemma 4 E2B / E4B, and any [other model](../README.md#more-models) you added) and an optional **Thinking** toggle
- attach a photo and ask about it (Gemma 4 is multimodal); photos are downscaled to 1024 px first to keep the Pi fast
- optional **web search**: with the Pi's web tools on, the model can search the web and read pages, and asks you first ([below](#web-search-and-other-tools))
- tap the title to switch model or turn Thinking on for the next question
- talks to the standard OpenAI-compatible `/v1/chat/completions` API, so it also works with other llama.cpp or OpenAI-style servers

The look follows the Rapid Review design system: ink for every control, electric blue only for the assistant's mark, the focused message box and the chosen model, Instrument Sans for text and JetBrains Mono for model names, in light and dark. The tokens are in `PiChat/Theme.swift`, the shared controls in `PiChat/Components.swift`, and both fonts ship in `PiChat/Fonts` (SIL Open Font License, licences beside them).

The app is about 4,100 lines of Swift. Its one dependency is SwiftMath (MIT licence), which Xcode fetches through Swift Package Manager. It needs iOS 17 and a Mac with Xcode 15 or newer.

Chats are saved on the phone, one file per chat in the app's Documents folder (`Chats/`). The single conversation older versions kept is moved there as the first chat on the first launch.

The parts that are plain Swift (the Markdown and maths reader, the chat archive, tool calls and the chat store) have tests: run `ios/Tests/run.sh` on a Mac with Xcode, or on Linux with a Swift toolchain. With `PICHAT_TEST_SERVER` (and `PICHAT_TEST_KEY`, `PICHAT_TEST_MODEL`) pointing at a Pi whose web tools are on, it also runs the app's client against it: the tool list, a search and a page read, end to end.

## Web search and other tools

If the Pi offers tools ([web search](../README.md#web-search), switched on with `./web-search.sh on`), the app can let the model use them:

1. Open **Settings > Tools** and switch on **Web search and other tools**. The panel shows which tools the Pi offers; if it says none, switch web search on at the Pi and tap **Test connection**.
2. Ask something that needs the web, such as *What's the weather in Hamburg tomorrow?* The model asks for a search; the chat shows what it wants to look up, with **Allow**, **Always allow this tool** and **Don't allow**. After the search it may read a page, then it answers.
3. Each step stays in the chat as one line ("Searched the web for …", "Read en.wikipedia.org"), with what it found folded away under it.

Good to know:

- **What leaves your network:** the search words and the addresses of the pages the model reads, through the search engine set up on the Pi. The chat itself stays on the Pi and your phone. The line under the message box says so while tools are on.
- **Every tool asks before it runs.** **Always allow this tool** stops the asking for that one tool (web search, say); **Ask again** in Settings undoes it. A tool added to the Pi later asks again.
- **Today's date** goes to the model with the tools, so a search for "the latest …" or "tomorrow" uses the right year.
- **Any MCP tool, not only search:** the app offers the model the tools of the MCP servers in the Pi's `/etc/pi-llm/mcp.json`, so a server you add there shows up here too. llama-server can't tell what an MCP tool does, so only add servers you trust. llama-server's own file and shell tools (`--tools`) are never offered, and the app refuses to run a tool it didn't offer, even if the model (or a web page it read) names one.
- **Speed:** each step means another round on the Pi: the model reads the search results or the page before it answers. Expect a search question to take several times as long as a plain one. After five rounds the model has to answer with what it has.
- **Which models:** in tests, Gemma 4 E2B, Qwen 3.5 4B, Ministral 3 3B and LFM2.5 8B-A1B used the tools well; see [More models](../README.md#more-models).

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
3. Drag the `.swift` files and the `Fonts` folder from `ios/PiChat/` into the project (check "Copy items if needed" and the PiChat target). The app registers the fonts itself, so no Info.plist entry is needed.
4. **File > Add Package Dependencies…**, enter `https://github.com/mgriebling/SwiftMath`, choose *Up to Next Minor Version* from `1.7.3`, and add the `SwiftMath` library to the PiChat target.
5. Target **PiChat > General**: set *Minimum Deployments* to iOS 17.0.
6. Target **PiChat > Info**, add two keys:
   - `App Transport Security Settings` > `Allow Arbitrary Loads` = `YES` (the Pi serves plain HTTP on your LAN)
   - `Privacy - Local Network Usage Description` = `Pi Chat talks to the model on your Raspberry Pi.`

### Then, for both options

1. **Signing & Capabilities**: pick your Team. A free Apple ID works, but apps signed with one expire after 7 days (just hit Run again). A paid developer account gives you 1 year.
2. If Xcode complains about the bundle identifier, change `com.example.pichat` to something unique.
3. Connect your iPhone, select it as the run destination, and press **Run**. On first install, enable **Settings > Privacy & Security > Developer Mode** on the phone and trust the developer certificate under **Settings > General > VPN & Device Management**.
4. In the app, open **Settings** (the sliders icon, top right), enter `http://pi-llm.local:8080` (or `http://<pi-ip>:8080`) and the API key from the installer, then tap **Test connection**. Allow local network access when iOS asks.

## No Mac?

You don't need this app. The Pi's built-in web UI works well in Safari: open `http://pi-llm.local:8080`, then **Share > Add to Home Screen** to get an app icon that opens full-screen. Any App Store chat client that lets you set a custom OpenAI-compatible base URL and API key also works. Use `http://pi-llm.local:8080/v1` as the base URL and `gemma-4-e2b` or `gemma-4-e4b` as the model name.
