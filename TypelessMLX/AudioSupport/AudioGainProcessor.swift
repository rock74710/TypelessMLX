import AVFoundation
import Foundation

/// Summary for one processed audio buffer.
public struct AudioGainResult: Equatable {
    public let gainDB: Double
    public let clippedSamples: Int
    public let sampleCount: Int
    public let nonFiniteSamples: Int
    public let normalizedRMS: Double

    public var clippingRatio: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(clippedSamples) / Double(sampleCount)
    }

    public init(
        gainDB: Double,
        clippedSamples: Int,
        sampleCount: Int,
        nonFiniteSamples: Int,
        normalizedRMS: Double
    ) {
        self.gainDB = gainDB
        self.clippedSamples = clippedSamples
        self.sampleCount = sampleCount
        self.nonFiniteSamples = nonFiniteSamples
        self.normalizedRMS = normalizedRMS
    }
}

/// Applies one bounded gain value to every sample in an audio tap buffer.
///
/// The processor edits the tap buffer in place. This preserves its sample
/// format, channel count, and interleaving without allocating a second buffer.
public final class AudioGainProcessor {
    public static let minimumGainDB = -6.0
    public static let maximumGainDB = 12.0
    public static let gainStepDB = 3.0
    public static let defaultGainDB = 0.0
    public static let clippingWarningRatio = 0.01

    private let lock = NSLock()
    private var storedGainDB: Double

    public init(gainDB: Double = defaultGainDB) {
        storedGainDB = Self.normalizedGain(gainDB)
    }

    public var gainDB: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedGainDB
        }
        set {
            lock.lock()
            storedGainDB = Self.normalizedGain(newValue)
            lock.unlock()
        }
    }

    /// Clamps to the supported range and rounds to the nearest 3 dB step.
    public static func normalizedGain(_ gainDB: Double) -> Double {
        guard gainDB.isFinite else { return defaultGainDB }
        let bounded = min(maximumGainDB, max(minimumGainDB, gainDB))
        let steps = ((bounded - minimumGainDB) / gainStepDB).rounded()
        return min(maximumGainDB, max(minimumGainDB, minimumGainDB + steps * gainStepDB))
    }

    /// Processes Float32, Float64, Int16, and Int32 PCM buffers in their native layout.
    /// Unsupported formats are left unchanged and report zero processed samples.
    public func process(_ buffer: AVAudioPCMBuffer) -> AudioGainResult {
        lock.lock()
        let db = storedGainDB
        lock.unlock()

        let scale = pow(10.0, db / 20.0)
        var clippedSamples = 0
        var sampleCount = 0
        var nonFiniteSamples = 0
        var squareSum = 0.0
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let format = buffer.format.commonFormat

        for index in buffers.indices {
            let audioBuffer = buffers[index]
            guard let data = audioBuffer.mData else { continue }
            let channels = max(1, Int(audioBuffer.mNumberChannels))
            let elementCount = min(
                Int(buffer.frameLength) * channels,
                Int(audioBuffer.mDataByteSize) / Self.bytesPerSample(for: format)
            )
            guard elementCount > 0 else { continue }

            switch format {
            case .pcmFormatFloat32:
                let samples = data.assumingMemoryBound(to: Float.self)
                for sampleIndex in 0..<elementCount {
                    let sample = samples[sampleIndex]
                    sampleCount += 1
                    guard sample.isFinite else {
                        samples[sampleIndex] = 0
                        nonFiniteSamples += 1
                        continue
                    }
                    let scaled = Double(sample) * scale
                    if scaled > 1 || scaled < -1 { clippedSamples += 1 }
                    let output = Float(min(1, max(-1, scaled)))
                    samples[sampleIndex] = output
                    squareSum += Double(output) * Double(output)
                }

            case .pcmFormatFloat64:
                let samples = data.assumingMemoryBound(to: Double.self)
                for sampleIndex in 0..<elementCount {
                    let sample = samples[sampleIndex]
                    sampleCount += 1
                    guard sample.isFinite else {
                        samples[sampleIndex] = 0
                        nonFiniteSamples += 1
                        continue
                    }
                    let scaled = sample * scale
                    if scaled > 1 || scaled < -1 { clippedSamples += 1 }
                    let output = min(1, max(-1, scaled))
                    samples[sampleIndex] = output
                    squareSum += output * output
                }

            case .pcmFormatInt16:
                let samples = data.assumingMemoryBound(to: Int16.self)
                for sampleIndex in 0..<elementCount {
                    let scaled = Double(samples[sampleIndex]) * scale
                    sampleCount += 1
                    if scaled > Double(Int16.max) || scaled < Double(Int16.min) {
                        clippedSamples += 1
                    }
                    let output = Int16(min(Double(Int16.max), max(Double(Int16.min), scaled)).rounded())
                    samples[sampleIndex] = output
                    let normalized = Double(output) / 32_768.0
                    squareSum += normalized * normalized
                }

            case .pcmFormatInt32:
                let samples = data.assumingMemoryBound(to: Int32.self)
                for sampleIndex in 0..<elementCount {
                    let scaled = Double(samples[sampleIndex]) * scale
                    sampleCount += 1
                    if scaled > Double(Int32.max) || scaled < Double(Int32.min) {
                        clippedSamples += 1
                    }
                    let output = Int32(min(Double(Int32.max), max(Double(Int32.min), scaled)).rounded())
                    samples[sampleIndex] = output
                    let normalized = Double(output) / 2_147_483_648.0
                    squareSum += normalized * normalized
                }

            default:
                continue
            }
        }

        return AudioGainResult(
            gainDB: db,
            clippedSamples: clippedSamples,
            sampleCount: sampleCount,
            nonFiniteSamples: nonFiniteSamples,
            normalizedRMS: sampleCount > 0 ? sqrt(squareSum / Double(sampleCount)) : 0
        )
    }

    private static func bytesPerSample(for format: AVAudioCommonFormat) -> Int {
        switch format {
        case .pcmFormatFloat32, .pcmFormatInt32:
            return MemoryLayout<UInt32>.size
        case .pcmFormatFloat64:
            return MemoryLayout<UInt64>.size
        case .pcmFormatInt16:
            return MemoryLayout<UInt16>.size
        default:
            return 1
        }
    }
}
