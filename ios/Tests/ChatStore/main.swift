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
// Tool use: the model asks for a tool, the person allows it (or not), the
// result goes back, and the answer follows. Stop and the round limit too.
@MainActor func runTools() async {
    let docs = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("tools")
    let archive = ChatArchive(folder: docs.appendingPathComponent("Chats"))
    let suite = "PiChatToolTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("http://x", forKey: SettingsKey.serverURL)
    let search = ServerTool(tool: "web_search", display_name: nil, type: "mcp", permissions: ["write": false],
                            definition: .object(["type": .string("function"), "function": .object(["name": .string("web_search")])]))
    let writer = ServerTool(tool: "write_file", display_name: nil, type: "server", permissions: ["write": true], definition: .object([:]))
    LlamaClient.offered = [search, writer]
    LlamaClient.asksFor = "web_search"
    let store = ChatStore(archive: archive, defaults: defaults)

    // Tools switched off: none offered, no date in the prompt
    store.send("Wetter?", image: nil)
    await wait(10)
    check(LlamaClient.lastTools.isEmpty && LlamaClient.lastWire.map(\.role) == ["user"], "off: no tools, no system prompt")
    await wait(400)
    check(store.messages.last?.text.hasSuffix("ten") == true && LlamaClient.ran.isEmpty, "off: plain answer")

    // On: the step waits for the person
    defaults.set(true, forKey: SettingsKey.tools)
    store.newChat()
    store.send("Wie wird das Wetter morgen?", image: nil)
    await wait(80)
    check(LlamaClient.lastTools.count == 1, "only the read-only tool offered: \(LlamaClient.lastTools.count)")
    let system = LlamaClient.lastWire.first
    check(system?.role == "system" && system?.text.hasPrefix("Today is ") == true, "date in the system prompt: \(system?.text ?? "none")")
    check(store.messages.map(\.role) == [.user, .assistant, .tool], "steps: \(store.messages.map(\.role))")
    let step = store.messages.last!
    let n = LlamaClient.requests
    check(step.toolState == .waitingForApproval && store.toolStepAwaitingApproval == step.id, "waiting for approval")
    check(step.toolName == "web_search" && step.toolArguments == #"{"query":"q\#(n)"}"# && store.messages[1].toolCalls?.first?.id == step.toolCallID, "step names its call")
    check(LlamaClient.ran.isEmpty && store.isGeneratingHere, "nothing run yet")
    let chatID = store.currentChatID!
    check(archive.load(chatID)?.messages.last?.toolState == .waitingForApproval, "waiting step saved")

    // Allowed: runs, the result goes back, the answer follows
    store.answerToolRequest(.allow)
    await wait(400)
    check(LlamaClient.ran.map(\.name) == ["web_search"], "ran once")
    check(store.messages.map(\.role) == [.user, .assistant, .tool, .assistant], "answer after the step: \(store.messages.map(\.role))")
    check(store.messages[2].toolState == .done && store.messages[2].text == "result for q\(n)", "result kept: \(store.messages[2].text)")
    check(store.messages[3].text.hasSuffix("ten") && !store.isGenerating, "final answer")
    check(LlamaClient.lastWire.map(\.role) == ["system", "user", "assistant", "tool"], "wire with the step: \(LlamaClient.lastWire.map(\.role))")
    check(LlamaClient.lastWire[2].toolCalls?.first?.id == LlamaClient.lastWire[3].toolCallID, "call and result match")
    check(store.chats.first?.preview == "one two three four five six seven eight nine ten", "preview from the answer, not the tool")
    check(archive.load(chatID)?.messages == store.messages, "saved with the tool step")

    // A follow-up question sends the whole history, tool steps included
    LlamaClient.asksFor = nil
    store.send("Und übermorgen?", image: nil)
    await wait(10)
    check(LlamaClient.lastWire.map(\.role) == ["system", "user", "assistant", "tool", "assistant", "user"], "history: \(LlamaClient.lastWire.map(\.role))")
    await wait(400)
    LlamaClient.asksFor = "web_search"

    // Declined: the model hears so and answers anyway
    store.newChat()
    store.send("Suche etwas", image: nil)
    await wait(80)
    store.answerToolRequest(.deny)
    await wait(400)
    check(LlamaClient.ran.count == 1, "declined: not run")
    check(store.messages[2].toolState == .declined && store.messages[2].text.contains("did not allow"), "declined step")
    check(store.messages.last?.text.hasSuffix("ten") == true && LlamaClient.lastWire.last?.role == "tool", "answered after declining")

    // Always allow: remembered, the next step runs without asking
    store.newChat()
    store.send("Noch eine Suche", image: nil)
    await wait(80)
    store.answerToolRequest(.alwaysAllow)
    await wait(400)
    check(defaults.bool(forKey: SettingsKey.toolsAlwaysAllowed) && LlamaClient.ran.count == 2, "always allow remembered")
    store.newChat()
    store.send("Und noch eine", image: nil)
    await wait(80)
    check(store.toolStepAwaitingApproval == nil, "not asked again")
    await wait(400)
    check(LlamaClient.ran.count == 3 && store.messages.last?.text.hasSuffix("ten") == true, "ran without asking")

    // Stop while waiting: nothing hangs, the cut step stays out of the next question
    defaults.set(false, forKey: SettingsKey.toolsAlwaysAllowed)
    store.newChat()
    store.send("Erste", image: nil)
    await wait(80)
    check(store.toolStepAwaitingApproval != nil, "waiting before stop")
    store.stop()
    check(!store.isGenerating && store.toolStepAwaitingApproval == nil, "stopped")
    await wait(50)
    check(LlamaClient.ran.count == 3 && store.messages.last?.toolState == .waitingForApproval, "not run, step left as it was")
    LlamaClient.asksFor = nil
    store.send("Zweite", image: nil)
    await wait(10)
    check(LlamaClient.lastWire.map(\.role) == ["system", "user", "user"], "cut step left out: \(LlamaClient.lastWire.map(\.role))")
    await wait(400)
    LlamaClient.asksFor = "web_search"

    // While waiting, the person looks at another chat and comes back
    store.newChat()
    store.send("Hin und zurück", image: nil)
    let away = store.currentChatID!
    await wait(80)
    store.newChat()
    check(store.isBusyElsewhere && store.toolStepAwaitingApproval != nil, "still waiting while away")
    store.open(away)
    check(store.messages.last?.toolState == .waitingForApproval, "step on screen again")
    store.answerToolRequest(.allow)
    await wait(400)
    check(store.messages.last?.text.hasSuffix("ten") == true, "answered after coming back")

    // A model that never stops asking: tools go after five rounds, then it answers
    defaults.set(true, forKey: SettingsKey.toolsAlwaysAllowed)
    LlamaClient.keepCalling = true
    let before = LlamaClient.requests
    store.newChat()
    store.send("Endlos", image: nil)
    await wait(900)
    check(LlamaClient.requests - before == ChatStore.maxToolRounds + 1, "rounds: \(LlamaClient.requests - before)")
    check(LlamaClient.lastTools.isEmpty, "last request without tools")
    check(store.messages.filter { $0.role == .tool }.count == ChatStore.maxToolRounds && store.messages.last?.text.hasSuffix("ten") == true, "five steps, then the answer")
    LlamaClient.keepCalling = false

    // The Pi offers no tools: none sent, even with the switch on
    LlamaClient.offered = []
    store.newChat()
    store.send("Ohne", image: nil)
    await wait(10)
    check(LlamaClient.lastTools.isEmpty && LlamaClient.lastWire.map(\.role) == ["user"], "no tools on the Pi")
    await wait(400)
}

Task { @MainActor in
    await run()
    await runTools()
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
