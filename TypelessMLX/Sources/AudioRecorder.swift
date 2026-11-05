import AVFoundation
import CoreAudio
import Foundation
import TypelessMLXAudioInputSupport
import TypelessMLXAudioTapSupport

/// Records audio using a persistent AVAudioEngine for the entire app lifetime.
/// Records in native mic format — mlx-whisper handles any conversion needed.
class AudioRecorder: NSObject {
    static let shared = AudioRecorder()

    private let engine = AVAudioEngine()
    private let gainProcessor = AudioGainProcessor()
    private var tapFileWriter: AudioTapFileWriter?
    private var currentURL: URL?
    private var pendingStopURLs: Set<URL> = []
    private var isCurrentlyRecording = false
    private let lock = NSLock()
    private var recordingStartedAt: Date?  // for config-change grace period
    private var gainChangesStorage: [Double] = []

    /// Called on the audio tap thread with a normalised 0–1 level each buffer (~23ms).
    var audioLevelHandler: ((Float) -> Void)?

    /// Called on the audio tap thread with each raw PCM buffer — used by SpeechStreamer for live preview.
    var audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?

    /// Called on the tap thread when a buffer clips at least 1% of its samples.
    var clippingHandler: ((Double) -> Void)?

    /// Gain changes made during the current or most recent recording.
    var gainChanges: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return gainChangesStorage
    }

    /// Sets App input gain. The processor clamps the value to −6…+12 dB in 3 dB steps.
    func setInputGainDB(_ value: Double) {
        let oldValue = gainProcessor.gainDB
        gainProcessor.gainDB = value
        let newValue = gainProcessor.gainDB
        guard oldValue != newValue else { return }

        lock.lock()
        if isCurrentlyRecording {
            gainChangesStorage.append(newValue)
        }
        lock.unlock()
        logInfo("AudioRecorder", "Input gain changed: \(oldValue) → \(newValue) dB")
    }

    private override init() {
        super.init()
        logInfo("AudioRecorder", "Initialized (persistent AVAudioEngine)")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    @objc private func handleEngineConfigChange(_ notification: Notification) {
        lock.lock()
        let recording = isCurrentlyRecording
        let startedAt = recordingStartedAt
        lock.unlock()
        // Ignore config changes within 2s of recording start — caused by our own setInputDevice() call
        if let startedAt = startedAt, Date().timeIntervalSince(startedAt) < 2.0 {
            logDebug("AudioRecorder", "Ignoring config change during startup grace period")
            return
        }
        logWarn("AudioRecorder", "Audio engine configuration changed (recording=\(recording))")
        guard recording else { return }
        do {
            engine.stop()
            try engine.start()
            logInfo("AudioRecorder", "Engine restarted after config change")
        } catch {
            logError("AudioRecorder", "Failed to restart engine after config change: \(error)")
            lock.lock()
            isCurrentlyRecording = false
            tapFileWriter = nil
            lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .audioDeviceLost, object: nil)
            }
        }
    }

    private func tempAudioURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "typelessmlx_\(UUID().uuidString).wav"
        return tempDir.appendingPathComponent(fileName)
    }

    @discardableResult
    func startRecording() -> Bool {
        lock.lock()
        guard !isCurrentlyRecording else {
            logWarn("AudioRecorder", "Already recording, ignoring startRecording")
            lock.unlock()
            return false
        }
        lock.unlock()

        removeTapSafely()
        if engine.isRunning { engine.stop() }
        engine.reset()

        lock.lock()
        gainChangesStorage = []
        lock.unlock()

        let url = tempAudioURL()
        logInfo("AudioRecorder", "Starting recording to: \(url.lastPathComponent)")

        do {
            guard Self.hasAvailableInputDevice() else {
                logError("AudioRecorder", "No available audio input device")
                return false
            }

            let inputNode = engine.inputNode
            // Apply user-selected input device before reading formats or installing the tap.
            setInputDevice(uid: AppState.shared.inputDeviceUID)

            let recordingFormat = inputNode.outputFormat(forBus: 0)

            logInfo("AudioRecorder", "Input format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")

            guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
                logError("AudioRecorder", "Invalid input format — no audio input device?")
                return false
            }

            lock.lock()
            self.tapFileWriter = AudioTapFileWriter(url: url)
            self.currentURL = url
            lock.unlock()

            // Let AVAudioEngine choose the tap format, then create the file lazily
            // from the first real buffer. This avoids stale hardware-format crashes.
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.lock.lock()
                let recording = self.isCurrentlyRecording
                let writer = self.tapFileWriter
                self.lock.unlock()
                guard recording, let writer = writer else { return }
                // The same processed tap buffer feeds the file, level meter, and live preview.
                let gainResult = self.gainProcessor.process(buffer)
                do {
                    let openedFile = try writer.write(buffer)
                    if openedFile {
                        logInfo("AudioRecorder", "Audio file opened with tap format: \(buffer.format.sampleRate)Hz, \(buffer.format.channelCount)ch")
                    }
                } catch {
                    logError("AudioRecorder", "Write error: \(error)")
                }
                // RMS audio level for overlay visualisation
                if let handler = self.audioLevelHandler {
                    handler(min(1.0, Float(gainResult.normalizedRMS) * 8.0))
                }
                if gainResult.clippingRatio >= AudioGainProcessor.clippingWarningRatio {
                    self.clippingHandler?(gainResult.clippingRatio)
                }
                // Forward buffer to SpeechStreamer for live preview
                self.audioBufferHandler?(buffer)
            }

            engine.prepare()
            try engine.start()

            lock.lock()
            isCurrentlyRecording = true
            recordingStartedAt = Date()
            lock.unlock()

            logInfo("AudioRecorder", "Recording started successfully")
            return true

        } catch {
            logError("AudioRecorder", "Failed to start recording: \(error)")
            removeTapSafely()
            if engine.isRunning { engine.stop() }
            lock.lock()
            tapFileWriter = nil
            currentURL = nil
            lock.unlock()
            return false
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        lock.lock()
        guard isCurrentlyRecording else {
            logWarn("AudioRecorder", "stopRecording called but not recording")
            lock.unlock()
            completion(nil)
            return
        }

        isCurrentlyRecording = false
        recordingStartedAt = nil
        let url = currentURL
        if let url { pendingStopURLs.insert(url) }
        tapFileWriter = nil
        currentURL = nil
        lock.unlock()

        logInfo("AudioRecorder", "Stopping recording")
        removeTapSafely()
        if engine.isRunning { engine.stop() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.lock.lock()
            let isPending = url.map { self.pendingStopURLs.remove($0) != nil } ?? false
            self.lock.unlock()
            guard isPending else {
                completion(nil)
                return
            }

            guard let url = url else {
                logError("AudioRecorder", "No URL after stop")
                completion(nil)
                return
            }

            let exists = FileManager.default.fileExists(atPath: url.path)
            var fileSize: UInt64 = 0
            if exists, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64 {
                fileSize = size
            }

            logInfo("AudioRecorder", "Audio file exists: \(exists), size: \(fileSize) bytes")

            if exists && fileSize > 100 {
                completion(url)
            } else {
                logError("AudioRecorder", "Audio file missing or empty")
                try? FileManager.default.removeItem(at: url)
                completion(nil)
            }
        }
    }

    private func removeTapSafely() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func forceReset() {
        logWarn("AudioRecorder", "Force reset")
        lock.lock()
        var discardedURLs = pendingStopURLs
        if let currentURL { discardedURLs.insert(currentURL) }
        isCurrentlyRecording = false
        tapFileWriter = nil
        currentURL = nil
        pendingStopURLs.removeAll()
        lock.unlock()
        removeTapSafely()
        if engine.isRunning { engine.stop() }
        engine.reset()
        for discardedURL in discardedURLs {
            try? FileManager.default.removeItem(at: discardedURL)
            logInfo("AudioRecorder", "Removed cancelled audio file: \(discardedURL.lastPathComponent)")
        }
        logInfo("AudioRecorder", "Engine reset complete")
    }

    /// Returns all available audio input devices as (name, uid) pairs.
    /// uid is stable across reboots and safe to store in AppStorage.
    static func availableInputDevices() -> [(name: String, uid: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(1)  // kAudioObjectSystemObject (C macro, not bridged)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [(name: String, uid: String)] = []
        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize) == noErr, inputSize > 0 else { continue }
            let bufPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(inputSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufPtr.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputSize, bufPtr) == noErr else { continue }
            let bufList = UnsafeMutableAudioBufferListPointer(bufPtr.assumingMemoryBound(to: AudioBufferList.self))
            let channelCounts = bufList.map { $0.mNumberChannels }
            guard AudioInputDeviceAvailability.hasInputChannels(bufferChannelCounts: channelCounts) else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr else { continue }

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr else { continue }

            result.append((name: nameRef as String, uid: uidRef as String))
        }
        return result
    }

    private static func hasAvailableInputDevice() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(1)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else { return false }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return false }

        let inputChannelCounts = deviceIDs.map { inputChannelCount(for: $0) }
        return AudioInputDeviceAvailability.hasAvailableInputDevice(inputChannelCounts: inputChannelCounts)
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, buffer) == noErr else {
            return 0
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return AudioInputDeviceAvailability.inputChannelCount(bufferChannelCounts: bufferList.map { $0.mNumberChannels })
    }

    /// Sets the engine's input device by UID. Call before engine.prepare()/start().
    private func setInputDevice(uid: String) {
        guard !uid.isEmpty else { return }
        // Translate UID → AudioDeviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: CFString = uid as CFString
        var deviceID: AudioDeviceID = kAudioDeviceUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let systemObject = AudioObjectID(1)  // kAudioObjectSystemObject
        let status = AudioObjectGetPropertyData(
            systemObject, &address,
            UInt32(MemoryLayout<CFString>.size), &uidRef,
            &dataSize, &deviceID
        )
        guard status == noErr, deviceID != kAudioDeviceUnknown else {
            logWarn("AudioRecorder", "Could not find device for UID: \(uid)")
            return
        }
        // Set on the engine's input node AudioUnit
        guard let inputUnit = engine.inputNode.audioUnit else {
            logWarn("AudioRecorder", "No audioUnit on inputNode")
            return
        }
        var id = deviceID
        let setStatus = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if setStatus == noErr {
            logInfo("AudioRecorder", "Input device set to UID: \(uid)")
        } else {
            logWarn("AudioRecorder", "Failed to set input device (status: \(setStatus))")
        }
    }
}

extension Notification.Name {
    static let audioDeviceLost = Notification.Name("TypelessMLX.audioDeviceLost")
}
