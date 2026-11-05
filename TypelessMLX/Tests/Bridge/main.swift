import Foundation

// 僅提供傳輸測試所需的 App 介面，不啟動 UI 或使用者後端。
struct TestModel { var modelType = "whisper" }
class AppState {
    static let shared = AppState()
    var selectedModel = TestModel()
    var initialPrompt = ""
    var removeFillers = false
    var hasPythonBackend = false
}
class DictionaryService {
    static let shared = DictionaryService()
    func buildPrompt(basePrompt: String) -> String { basePrompt }
}
func logInfo(_ component: String, _ message: String) {}
func logWarn(_ component: String, _ message: String) {}
func logError(_ component: String, _ message: String) {}
func logDebug(_ component: String, _ message: String) {}
func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
func wait(_ predicate: () -> Bool, seconds: TimeInterval = 5) {
    let end = Date().addingTimeInterval(seconds)
    while !predicate() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(predicate(), "timed out waiting for expected callback")
}
extension Result where Success == String, Failure == Error {
    var failureCode: Int? {
        if case .failure(let error) = self { return (error as NSError).code }
        return nil
    }
}
let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fake_server.py").path
let bridge = WhisperBridge(python: "/usr/bin/python3", script: script, timeout: 0.15)
var ready = false
bridge.start { ready = $0 }
wait { ready }
var callbacks = 0
bridge.transcribe(audioURL: URL(fileURLWithPath: "/unused.wav"), model: "duplicate", language: nil) { result in
    callbacks += 1
    check((try? result.get()) == "raw 12.5 text", "transport must preserve original")
}
wait { callbacks == 1 }
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
check(callbacks == 1, "duplicate result must settle once")
var cancelled = 0
bridge.transcribe(audioURL: URL(fileURLWithPath: "/unused.wav"), model: "delayed", language: nil) { result in
    cancelled += 1
    if case .success = result { fatalError("cancelled inference delivered success") }
}
bridge.stopProcess()
wait { cancelled == 1 }
ready = false
bridge.start { ready = $0 }
wait { ready }
var afterRestart = false
bridge.transcribe(audioURL: URL(fileURLWithPath: "/unused.wav"), model: "ok", language: nil) { result in
    afterRestart = (try? result.get()) == "raw 12.5 text"
}
wait { afterRestart }
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
check(cancelled == 1, "old process cannot complete cancelled task twice")
var timedOut = 0
bridge.transcribe(audioURL: URL(fileURLWithPath: "/unused.wav"), model: "delayed", language: nil) { result in
    timedOut += 1
    check((result.failureCode) == -4, "timeout error")
}
wait { timedOut == 1 }
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
check(timedOut == 1, "late timeout result must be ignored")
var crashed = 0
bridge.transcribe(audioURL: URL(fileURLWithPath: "/unused.wav"), model: "crash", language: nil) { result in
    crashed += 1
    if case .success = result { fatalError("crash reported success") }
}
wait { crashed == 1 }
bridge.stopProcess()
print("WhisperBridge integration tests passed")
