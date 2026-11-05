import Cocoa
import TypelessMLXWorkflowSupport

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
let board = NSPasteboard.withUniqueName()
defer { board.releaseGlobally() }
var scheduled: [() -> Void] = []
var sent = 0
var eventSucceeds = true
var results: [DeliveryResult] = []
var eligibility = PasteEligibility.allowed
var current = true
let paster = PasteTransaction(pasteboard: board, schedule: { _, work in scheduled.append(work) }, send: { sent += 1; return eventSucceeds })
func enqueue(_ text: String) {
    paster.enqueue(text, eligibility: { eligibility }, isCurrent: { current }) { results.append($0) }
}
func advance() { check(!scheduled.isEmpty, "missing scheduled step"); scheduled.removeFirst()() }
board.setString("original", forType: .string)
enqueue("dictation")
advance()
check(sent == 1 && results == [.sent], "event result")
board.clearContents(); board.setString("new copy", forType: .string)
advance()
check(board.string(forType: .string) == "new copy", "must preserve new copy")
board.clearContents()
enqueue("first"); enqueue("second")
advance(); advance()
check(board.string(forType: .string) == "second", "second begins after first restores")
advance(); advance()
check(board.pasteboardItems?.isEmpty != false, "restore empty clipboard")
eligibility = .targetChanged
enqueue("blocked")
check(results.last == .retained && scheduled.isEmpty, "target change must retain text without write")
eligibility = .secure
enqueue("secret")
check(results.last == .blocked && scheduled.isEmpty, "secure must block")
eligibility = .allowed
enqueue("cancel")
current = false
advance()
check(results.last == .cancelled, "cancel before event")
check(board.pasteboardItems?.isEmpty != false, "cancel restores clipboard")
current = true
enqueue("changed focus")
eligibility = .targetChanged
advance()
check(results.last == .retained, "recheck focus before event")
eligibility = .allowed
enqueue("clipboard race")
board.clearContents(); board.setString("user copy before event", forType: .string)
advance()
check(board.string(forType: .string) == "user copy before event", "must not overwrite intervening copy")
check(sent == 3, "no events after cancel or focus change")
eligibility = .missingPermission
enqueue("no permission")
check(results.last == .failed && scheduled.isEmpty, "missing permission")
eligibility = .allowed
enqueue("secure during delay")
eligibility = .secure
advance()
check(results.last == .blocked, "secure check immediately before event")
check(board.string(forType: .string) == "user copy before event", "secure cancels temporary copy")
eligibility = .allowed
eventSucceeds = false
enqueue("event failed")
advance()
check(results.last == .failed, "send failure")
check(board.string(forType: .string) == "user copy before event", "failed send restores owned clipboard")
// 使用自有文字編輯器與獨立剪貼簿，不送出系統按鍵。
let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
editor.string = "before after"
editor.setSelectedRange(NSRange(location: 7, length: 0))
let editorRange = editor.selectedRange()
var editorOutcome: DeliveryResult?
let editorPaster = PasteTransaction(pasteboard: board,
    schedule: { _, work in scheduled.append(work) },
    send: {
        guard let text = board.string(forType: .string) else { return false }
        editor.insertText(text, replacementRange: editor.selectedRange())
        return true
    })
let editorEligibility: () -> PasteEligibility = { editor.selectedRange() == editorRange ? .allowed : .targetChanged }
editorPaster.enqueue("typed ", eligibility: editorEligibility, isCurrent: { true }) { editorOutcome = $0 }
advance()
check(editor.string == "before typed after" && editorOutcome == .sent, "owned editor receives text at captured range")
advance()
editor.setSelectedRange(editorRange)
editorPaster.enqueue("wrong ", eligibility: editorEligibility, isCurrent: { true }) { editorOutcome = $0 }
editor.setSelectedRange(NSRange(location: 0, length: 0))
advance()
check(editor.string == "before typed after" && editorOutcome == .retained, "changed editor selection blocks event")
let lifecycle = DictationLifecycle()
let a = lifecycle.begin()
check(lifecycle.isCurrent(a), "new task")
check(lifecycle.finish(a, phase: .cancelled), "cancel")
let b = lifecycle.begin()
check(!lifecycle.finish(a, phase: .completed), "late result")
check(lifecycle.isCurrent(b), "new task unaffected")
check(lifecycle.finish(b, phase: .completed), "complete once")
check(!lifecycle.finish(b, phase: .failed), "duplicate completion")
let oldJSON = """
[{"id":"00000000-0000-0000-0000-000000000001","text":"old","timestamp":0,"duration":1,"model":"macos-speech"}]
"""
let entries = try JSONDecoder().decode([TranscriptionRecord].self, from: Data(oldJSON.utf8))
check(entries[0].originalText == "old" && entries[0].delivery == .retained, "legacy defaults")
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let store = try RecoveryStore(directory: root, maxAge: 10, maxCount: 2, maxBytes: 20)
func audio(_ name: String, count: Int) throws -> URL {
    let p = root.deletingLastPathComponent().appendingPathComponent("test-\(UUID())-\(name)")
    try Data(repeating: 1, count: count).write(to: p)
    return p
}
let u1 = try audio("one", count: 8)
let r1 = try store.retain(u1, now: Date(timeIntervalSince1970: 100))
check(!FileManager.default.fileExists(atPath: u1.path), "retention removes temp")
let u2 = try audio("two", count: 8)
_ = try store.retain(u2, now: Date(timeIntervalSince1970: 101))
let u3 = try audio("three", count: 8)
_ = try store.retain(u3, now: Date(timeIntervalSince1970: 102))
check(store.url(for: r1) == nil, "count and size prune oldest")
let reopened = try RecoveryStore(directory: root, maxAge: 10, maxCount: 2, maxBytes: 20, now: Date(timeIntervalSince1970: 103))
check(reopened.identifiers.count == 2, "restart keeps valid data")
try reopened.cleanup(now: Date(timeIntervalSince1970: 200))
check(reopened.identifiers.isEmpty, "expiry after restart")
check(reopened.url(for: "../../outside.wav") == nil, "path confinement")
let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "private directory")
let limit = try RecoveryStore(directory: root, maxAge: 10, maxCount: 10, maxBytes: 10, now: Date(timeIntervalSince1970: 200))
let p1 = try audio("size1", count: 8)
let first = try limit.retain(p1, now: Date(timeIntervalSince1970: 200))
let p2 = try audio("size2", count: 8)
let second = try limit.retain(p2, now: Date(timeIntervalSince1970: 201))
check(limit.url(for: first) == nil && limit.url(for: second) != nil, "byte limit removes oldest")
let fileAttrs = try FileManager.default.attributesOfItem(atPath: limit.url(for: second)!.path)
check((fileAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private recording")
try limit.clear()
check(limit.identifiers.isEmpty, "clear all recovery recordings")
print("TypelessMLXWorkflowTests passed")
