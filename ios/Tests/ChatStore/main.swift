// Tests for ChatStore.swift with a fake streaming client: chats, answers that
// go on in the background, stop, rename, relaunch, delete. Run with ios/Tests/run.sh.
import Foundation
var failures = 0
func check(_ c: Bool, _ m: String, line: Int = #line) { if !c { failures += 1; print("FAIL \(line): \(m)") } }
func wait(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

@MainActor func run() async {
    // A folder and settings of its own, so a run never touches the app's chats.
    let docs = URL(fileURLWithPath: CommandLine.arguments[1])
    let archive = ChatArchive(folder: docs.appendingPathComponent("Chats"))
    let suite = "PiChatTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("http://x", forKey: SettingsKey.serverURL)
    // An old single chat to import
    try! JSONEncoder().encode([ChatMessage(role: .user, text: "Old question"), ChatMessage(role: .assistant, text: "Old answer")]).write(to: docs.appendingPathComponent("chat.json"))

    let store = ChatStore(archive: archive, defaults: defaults)
    check(store.chats.count == 1 && store.chats[0].title == "Old question", "imported old chat")
    check(store.messages.count == 2, "old chat open at launch")
    let oldID = store.currentChatID!

    // New chat, ask, leave while it answers
    store.newChat()
    check(store.messages.isEmpty && store.currentChatID == nil, "new chat empty")
    store.send("Erste Frage\nmit zweiter Zeile", image: nil)
    let firstID = store.currentChatID!
    check(store.chats.first?.id == firstID && store.chats.first?.title == "Erste Frage", "new chat at top with title")
    check(store.isGeneratingHere && !store.isBusyElsewhere, "generating here")
    await wait(10)
    check(LlamaClient.lastWire.map(\.text) == ["Erste Frage\nmit zweiter Zeile"], "wire has only this chat")
    await wait(60)
    store.open(oldID)
    check(store.isBusyElsewhere && !store.isGeneratingHere, "busy elsewhere after opening old chat")
    check(store.messages.count == 2 && store.messages[1].text == "Old answer", "old chat on screen untouched")
    store.send("blocked", image: nil)
    check(store.messages.count == 2, "cannot ask while busy elsewhere")
    await wait(60)
    store.open(firstID)
    check(store.isGeneratingHere, "back in answering chat")
    let partial = store.messages.last!.text
    check(!partial.isEmpty && partial != "one two three four five six seven eight nine ten", "partial answer carried on in background: \(partial)")
    await wait(400)
    check(!store.isGenerating, "finished")
    check(store.messages.last?.text == "one two three four five six seven eight nine ten", "full answer on screen: \(store.messages.last?.text ?? "")")
    check(store.messages.last?.stats == "10 tokens · 5.0 tokens a second", "stats")

    // Finish while away: answer saved to disk
    store.send("Zweite Frage", image: nil)
    await wait(10)
    check(LlamaClient.lastWire.count == 3, "history sent: \(LlamaClient.lastWire.count)")
    store.newChat()
    await wait(400)
    check(!store.isGenerating, "finished in background")
    let saved = archive.load(firstID)
    check(saved?.messages.count == 4 && saved?.messages.last?.text.hasSuffix("ten") == true, "background answer saved")
    check(store.chats.first(where: { $0.id == firstID })?.preview == "one two three four five six seven eight nine ten", "preview")
    store.open(firstID)
    check(store.messages.count == 4, "opened from disk after background finish")

    // Stop from another chat
    store.send("Dritte", image: nil)
    await wait(50)
    store.open(oldID)
    store.stop()
    check(!store.isGenerating && store.generatingChatID == nil, "stopped")
    store.open(firstID)
    check(store.messages.count == 6 && !(store.messages.last?.text.hasSuffix("ten") ?? true), "stopped answer kept partial: \(store.messages.last?.text ?? "")")
    await wait(100)

    // Rename, relaunch, delete
    store.rename(oldID, to: "  Renamed  ")
    let again = ChatStore(archive: archive, defaults: defaults)
    check(again.currentChatID == firstID && again.messages.count == 6, "relaunch opens last chat")
    check(again.chats.map(\.id) == [firstID, oldID], "order kept")
    check(again.chats.last?.title == "Renamed", "rename saved")
    again.delete(firstID)
    check(again.currentChatID == nil && again.messages.isEmpty && again.chats.map(\.id) == [oldID], "deleted current")
    check(archive.load(firstID) == nil, "file deleted")
    // Delete while answering
    again.open(oldID)
    again.send("x", image: nil)
    again.delete(oldID)
    check(!again.isGenerating && again.chats.isEmpty, "deleted while answering")
    await wait(100)
    check(archive.load(oldID) == nil, "not written back by the cancelled answer")
    check(ChatStore(archive: archive, defaults: defaults).chats.isEmpty, "empty after relaunch")
}
Task { @MainActor in
    await run()
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
