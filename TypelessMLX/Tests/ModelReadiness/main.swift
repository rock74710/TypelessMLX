import Foundation

class WhisperBridge {
    static let shared = WhisperBridge()
    static func isVenvReady() -> Bool { false }
    static func makeEnv() -> [String: String] { ProcessInfo.processInfo.environment }
    var scriptPath: String { "" }
    var pythonPath: String { "" }
}
func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let fixture = """
import sys, pathlib, hashlib
sys.path.insert(0, 'backend')
from model_validation import validate_and_mark, MODEL_MANIFEST
root=pathlib.Path(sys.argv[1])
config=root/'config.json'; weights=root/'weights.npz'
config.write_bytes(b'{}')
weights.write_bytes(b'fixture weights')
if sys.argv[2]=='symlink':
    dest=root/'actual-weights'
    weights.replace(dest)
    weights.symlink_to(dest)
files={p.name:{'size':p.stat().st_size,'algorithm':'sha256','digest':hashlib.sha256(p.read_bytes()).hexdigest()} for p in (config, weights)}
validate_and_mark(model_id='whisper-small', model_path=root, revision=MODEL_MANIFEST['models']['whisper-small']['revision'], files=files, loader=lambda _:True, loader_name='test fixture loader')
"""
func createFixture(symlink: Bool = false) throws {
    let marker = root.appendingPathComponent(".typelessmlx-model-ready.json")
    try? FileManager.default.removeItem(at: marker)
    let weights = root.appendingPathComponent("weights.npz")
    try? FileManager.default.removeItem(at: weights)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", fixture, root.path, symlink ? "symlink" : "file"]
    try process.run(); process.waitUntilExit()
    check(process.terminationStatus == 0, "Python fixture generation")
}
func editMarker(_ edit: (inout [String: Any]) -> Void) throws {
    let url = root.appendingPathComponent(".typelessmlx-model-ready.json")
    var marker = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    edit(&marker)
    try JSONSerialization.data(withJSONObject: marker).write(to: url)
}
func ready() -> Bool { ModelReadiness.isReady(directoryURL: root, modelID: "whisper-small") }
try createFixture()
if !ready() {
    let markerData = try Data(contentsOf: root.appendingPathComponent(".typelessmlx-model-ready.json"))
    let marker = try JSONSerialization.jsonObject(with: markerData) as! [String: Any]
    FileHandle.standardError.write(Data("root=\(root.resolvingSymlinksInPath().standardizedFileURL.path) marker=\(marker["model_path"]!)\n".utf8))
    for item in marker["fingerprint"] as! [[String: Any]] {
        let name = item["path"] as! String
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)
        let date = attrs[.modificationDate] as! Date
        FileHandle.standardError.write(Data("\(name) actualMS=\(Int64((date.timeIntervalSince1970*1000).rounded(.down))) expected=\(item["mtime_ms"]!)\n".utf8))
    }
}

check(ready(), "Swift must accept valid Python marker without loading MLX")
try FileManager.default.removeItem(at: root.appendingPathComponent("weights.npz"))
check(!ready(), "missing weights invalidate ready marker")
try createFixture()
try editMarker { $0["schema_version"] = 99 }
check(!ready(), "unknown marker schema")
try createFixture()
try editMarker { marker in
    let items = marker["fingerprint"] as! [[String: Any]]
    marker["fingerprint"] = [items[0], items[0]]
}
check(!ready(), "duplicate fingerprint entries cannot omit a weight file")
try createFixture(symlink: true)
check(ready(), "HF-style symlink stat parity with Python")
try Data("changed".utf8).write(to: root.appendingPathComponent("actual-weights"))
check(!ready(), "changed symlink target invalidates marker")
check(ModelReadiness.isReady(directoryURL: root, modelID: "macos-speech"), "native speech needs no model files")
print("ModelReadiness Swift/Python contract tests passed")
