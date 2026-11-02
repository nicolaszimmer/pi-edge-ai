// Tests for ChatArchive.swift: files on disk, the old chat.json, titles and previews.
// Run with ios/Tests/run.sh.
import Foundation
var failures = 0
func check(_ c: Bool, _ m: String, line: Int = #line) { if !c { failures += 1; print("FAIL \(line): \(m)") } }

let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("archtest-\(UUID().uuidString)")
let archive = ChatArchive(folder: root.appendingPathComponent("Chats"))
check(archive.loadIndex().isEmpty, "empty at first")

// Import of the old single chat
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let legacy = root.appendingPathComponent("chat.json")
let old = [ChatMessage(role: .user, text: "Erkläre mir bitte den Satz des Pythagoras, mit einem Beispiel und allem was dazugehört"),
           ChatMessage(role: .assistant, text: "Gerne erkläre ich dir den **Satz des Pythagoras**!\n\n$$\\Huge a^2 + b^2 = c^2$$")]
try! JSONEncoder().encode(old).write(to: legacy)
let imported = archive.importSingleChat(from: legacy)
check(imported != nil, "imported")
check(!FileManager.default.fileExists(atPath: legacy.path), "old file removed")
check(imported?.title == "Erkläre mir bitte den Satz des Pythagoras, mit einem…", "title: \(imported?.title ?? "nil")")
check(imported?.preview == "Gerne erkläre ich dir den Satz des Pythagoras! a^2 + b^2 = c^2", "preview: \(imported?.preview ?? "nil")")
archive.saveIndex([imported!])
check(archive.load(imported!.id)?.messages == old, "messages kept")

// A broken old file stays where it is
try! Data("not json".utf8).write(to: legacy)
check(archive.importSingleChat(from: legacy) == nil, "broken not imported")
check(FileManager.default.fileExists(atPath: legacy.path), "broken file kept")

// Second chat, index order, rebuild
var second = SavedChat(summary: ChatSummary(id: UUID(), title: "Photo", preview: "", created: Date(), updated: Date().addingTimeInterval(10)), messages: [ChatMessage(role: .user, text: "", imageJPEG: Data([1,2,3]))])
archive.save(second)
archive.saveIndex([imported!, second.summary])
check(archive.loadIndex().map(\.id) == [second.summary.id, imported!.id], "newest first")
try! FileManager.default.removeItem(at: root.appendingPathComponent("Chats/index.json"))
check(archive.loadIndex().map(\.id) == [second.summary.id, imported!.id], "rebuilt index")
check(FileManager.default.fileExists(atPath: root.appendingPathComponent("Chats/index.json").path), "rebuilt index saved")
archive.delete(second.summary.id)
check(archive.load(second.summary.id) == nil, "deleted")
check(archive.rebuildIndex().map(\.id) == [imported!.id], "rebuild after delete")

// Titles
check(ChatSummary.title(question: "", hasPhoto: true) == "Photo", "photo title")
check(ChatSummary.title(question: "\n\n  Hallo  Welt \nzweite Zeile", hasPhoto: false) == "Hallo Welt", "first line")
check(ChatSummary.title(question: "Is C# faster than my_var_name? $5 > $10", hasPhoto: false) == "Is C# faster than my_var_name? $5 > $10", "title keeps the question's characters")
func answer(_ t: String) -> [ChatMessage] { [ChatMessage(role: .user, text: "q"), ChatMessage(role: .assistant, text: t)] }
let p1 = ChatSummary.preview(for: answer("## Title\n\nText with **bold**, `code` and C# or my_var.\n\n---\n\n* item one\n1. step\n> quoted 5 > 3\n\n| a | b |\n|---|:-:|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\nCosts $5 and $10, and $a^2$ is $$\\Huge c$$ in \\text{cm}."))
check(p1 == "Title Text with bold, code and C# or my_var. item one step quoted 5 > 3 a b 1 2 let x = 1 Costs $5 and $10, and a^2 is c in cm.", "preview: \(p1)")
check(ChatSummary.title(question: String(repeating: "a", count: 80), hasPhoto: false) == String(repeating: "a", count: 60) + "…", "long word cut")
check(ChatSummary.title(for: []) == "New chat", "no messages")
let p2 = ChatSummary.preview(for: answer("Also 5 * 3 = 15, $2*3$, $|x|$ and ***both*** with __init__ and a | b."))
check(p2 == "Also 5 * 3 = 15, 2*3, |x| and both with __init__ and a | b.", "stars and pipes kept: \(p2)")
check(ChatSummary.shortened("(Frage) " + String(repeating: "wort ", count: 10) + "C# und mehr Text danach", to: 61) == "(Frage) wort wort wort wort wort wort wort wort wort wort C#…", "cut keeps ( and #: \(ChatSummary.shortened("(Frage) " + String(repeating: "wort ", count: 10) + "C# und mehr Text danach", to: 61))")
check(ChatSummary.shortened(String(repeating: "abc ", count: 14) + "x, y z", to: 59) == String(repeating: "abc ", count: 14).trimmingCharacters(in: .whitespaces) + " x…", "dangling comma dropped: \(ChatSummary.shortened(String(repeating: "abc ", count: 14) + "x, y z", to: 59))")
let p3 = ChatSummary.preview(for: answer("So 2*x and 3*y, but **Kurz gesagt:** ok, *kursiv*, and **fett**, here."))
check(p3 == "So 2*x and 3*y, but Kurz gesagt: ok, kursiv, and fett, here.", "stars inside words kept: \(p3)")
let p4 = ChatSummary.preview(for: answer("See [the docs](https://example.com/docs) and ![a cat](cat.png), or [x] alone."))
check(p4 == "See the docs and a cat, or [x] alone.", "links: \(p4)")
// Tool steps: what the chat says about them, and chats saved before them still load
func step(_ name: String, _ arguments: String, _ state: ChatMessage.ToolState?) -> ChatMessage {
    var m = ChatMessage(role: .tool, text: "")
    m.toolName = name
    m.toolArguments = arguments
    m.toolState = state
    return m
}
let q = #"{"query":"Wetter Berlin"}"#
check(step("web_search", q, .done).toolSummary == "Searched the web for “Wetter Berlin”", "done")
check(step("web_search", q, .failed).toolSummary == "Could not search the web for “Wetter Berlin”", "failed")
check(step("web_search", q, .declined).toolSummary == "You did not allow it to search the web for “Wetter Berlin”", "declined")
check(step("web_fetch", #"{"url":"https://example.com/a"}"#, .running).toolSummary == "Stopped before it could read a page on example.com", "stopped")
check(step("web_search", q, nil).toolSummary.hasPrefix("Stopped"), "no state counts as stopped")
check(step("web_search", q, .done).isFinishedToolStep && !step("web_search", q, .waitingForApproval).isFinishedToolStep, "finished steps")
var request = ChatMessage(role: .assistant, text: "")
request.toolCalls = [ToolCall(id: "a", name: "web_search", arguments: q)]
check(request.isToolRequestOnly, "answer that only asked for a tool")
request.text = "Let me look."
check(!request.isToolRequestOnly, "with words it shows")
let toolChat = answer("x") + [request, step("web_search", q, .done)]
check(ChatSummary.preview(for: toolChat) == "Let me look.", "preview skips tool steps")
let roundTrip = try! JSONDecoder().decode([ChatMessage].self, from: JSONEncoder().encode(toolChat))
check(roundTrip == toolChat, "tool steps saved and loaded")
let saved = #"[{"id":"2E7E4B1C-1D29-4E43-9C8B-2F0A1C3B9E11","role":"assistant","text":"Hi","reasoning":"","isError":false,"date":800000000}]"#
let loaded = try? JSONDecoder().decode([ChatMessage].self, from: Data(saved.utf8))
check(loaded?.first?.text == "Hi" && loaded?.first?.toolCalls == nil, "a chat saved before tools loads")

try? FileManager.default.removeItem(at: root)
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
