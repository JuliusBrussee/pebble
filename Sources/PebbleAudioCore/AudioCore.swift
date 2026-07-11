import Foundation
import PebblePlatformNative

public protocol AudioService: AnyObject {
    var onSubtitle: ((String) -> Void)? { get set }
    func start()
    func stop()
    func setVolumes(_ volumes: [String: Double])
    func setEnvironment(_ underwater: Bool, _ caveFactor: Double)
    func setListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double)
    func play(_ name: String, _ x: Double, _ y: Double, _ z: Double, _ volume: Double, _ pitch: Double)
    func playUI(_ name: String)
    func playDisc(_ name: String, _ x: Double, _ y: Double, _ z: Double)
    func stopDisc()
    func tickMusic(_ mood: String, _ enabled: Bool)
}

public final class NullAudioService: AudioService {
    public var onSubtitle: ((String) -> Void)?
    public init() {}
    public func start() {}
    public func stop() {}
    public func setVolumes(_ volumes: [String: Double]) {}
    public func setEnvironment(_ underwater: Bool, _ caveFactor: Double) {}
    public func setListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {}
    public func play(_ name: String, _ x: Double, _ y: Double, _ z: Double, _ volume: Double, _ pitch: Double) {}
    public func playUI(_ name: String) {}
    public func playDisc(_ name: String, _ x: Double, _ y: Double, _ z: Double) {}
    public func stopDisc() {}
    public func tickMusic(_ mood: String, _ enabled: Bool) {}
}

public enum AudioWaveform: Sendable {
    case sine
    case square
    case sawtooth
    case triangle
    case noise
}

public struct AudioListener: Sendable {
    public var position: SIMD3<Double>
    public var yaw: Double

    public init(position: SIMD3<Double> = .zero, yaw: Double = 0) {
        self.position = position
        self.yaw = yaw
    }
}

public struct AudioVoice: Sendable {
    public var waveform: AudioWaveform
    public var frequency: Double
    public var endFrequency: Double?
    public var duration: Double
    public var attack: Double
    public var volume: Double
    public var pan: Double
    public var category: String
    public var startDelay: Double
    public var spatialPosition: SIMD3<Double>?
    public var maxDistance: Double
    public var reverbSend: Double

    public init(waveform: AudioWaveform = .sine,
                frequency: Double = 440,
                endFrequency: Double? = nil,
                duration: Double = 0.2,
                attack: Double = 0.005,
                volume: Double = 0.3,
                pan: Double = 0,
                category: String = "ambient",
                startDelay: Double = 0,
                spatialPosition: SIMD3<Double>? = nil,
                maxDistance: Double = 18,
                reverbSend: Double = 0) {
        self.waveform = waveform
        self.frequency = frequency
        self.endFrequency = endFrequency
        self.duration = max(0.001, duration)
        self.attack = max(0.0001, min(attack, duration))
        self.volume = max(0, volume)
        self.pan = max(-1, min(1, pan))
        self.category = category
        self.startDelay = max(0, startDelay)
        self.spatialPosition = spatialPosition
        self.maxDistance = max(0.001, maxDistance)
        self.reverbSend = max(0, min(1, reverbSend))
    }
}

private struct ActiveVoice {
    var definition: AudioVoice
    var startFrame: UInt64
    var endFrame: UInt64
    var phase = 0.0
    var noiseState: UInt64
}

/// Platform-neutral stereo mixer. Host audio callback pulls interleaved Float32
/// frames; game thread only mutates inbox/listener/mix state under short locks.
public final class AudioMixer: @unchecked Sendable {
    public let sampleRate: Double
    public let maximumVoices: Int

    private let lock = NSLock()
    private var listener = AudioListener()
    private var masterGain = 1.0
    private var categoryGains: [String: Double] = [:]
    private var underwater = false
    private var caveFactor = 0.0
    private var frameCursor: UInt64 = 0
    private var inbox: [ActiveVoice] = []
    private var voices: [ActiveVoice] = []
    private var stopRequested = false
    private var delayLeft: [Float]
    private var delayRight: [Float]
    private var delayCursorLeft = 0
    private var delayCursorRight = 0
    private var lowpassLeft = 0.0
    private var lowpassRight = 0.0
    private var nextNoiseSeed: UInt64 = 0x9e3779b97f4a7c15

    public init(sampleRate: Double = 48_000, maximumVoices: Int = 512) {
        precondition(sampleRate > 0 && maximumVoices > 0)
        self.sampleRate = sampleRate
        self.maximumVoices = maximumVoices
        delayLeft = [Float](repeating: 0, count: max(1, Int(sampleRate * 0.31)))
        delayRight = [Float](repeating: 0, count: max(1, Int(sampleRate * 0.37)))
    }

    public func setListener(_ listener: AudioListener) {
        lock.lock(); self.listener = listener; lock.unlock()
    }

    public func setEnvironment(underwater: Bool, caveFactor: Double) {
        lock.lock()
        self.underwater = underwater
        self.caveFactor = max(0, min(1, caveFactor))
        lock.unlock()
    }

    public func setVolumes(master: Double, categories: [String: Double]) {
        lock.lock()
        masterGain = max(0, master)
        categoryGains = categories.mapValues { max(0, $0) }
        lock.unlock()
    }

    public func enqueue(_ voice: AudioVoice) {
        lock.lock()
        let start = frameCursor + UInt64((voice.startDelay * sampleRate).rounded())
        let durationFrames = UInt64((voice.duration * sampleRate).rounded(.up))
        nextNoiseSeed &+= 0x9e3779b97f4a7c15
        inbox.append(ActiveVoice(definition: voice, startFrame: start,
                                 endFrame: start + durationFrames, noiseState: nextNoiseSeed))
        if inbox.count > maximumVoices { inbox.removeFirst(inbox.count - maximumVoices) }
        lock.unlock()
    }

    public func stopAll() {
        lock.lock()
        inbox.removeAll(keepingCapacity: true)
        stopRequested = true
        lock.unlock()
    }

    public func render(frameCount: Int) -> [Float] {
        precondition(frameCount >= 0)
        var output = [Float](repeating: 0, count: frameCount * 2)
        output.withUnsafeMutableBufferPointer { render(into: $0, frameCount: frameCount) }
        return output
    }

    public func render(into output: UnsafeMutableBufferPointer<Float>, frameCount: Int) {
        precondition(frameCount >= 0 && output.count >= frameCount * 2)
        if frameCount == 0 { return }
        for index in 0..<(frameCount * 2) { output[index] = 0 }

        lock.lock()
        if stopRequested {
            voices.removeAll(keepingCapacity: true)
            stopRequested = false
        }
        if !inbox.isEmpty {
            voices.append(contentsOf: inbox)
            inbox.removeAll(keepingCapacity: true)
            if voices.count > maximumVoices { voices.removeFirst(voices.count - maximumVoices) }
        }
        let blockStart = frameCursor
        let listener = self.listener
        let master = masterGain
        let gains = categoryGains
        let underwater = self.underwater
        let cave = caveFactor
        lock.unlock()

        for voiceIndex in voices.indices {
            var voice = voices[voiceIndex]
            if voice.endFrame <= blockStart { continue }
            let definition = voice.definition
            let spatial = spatialMix(for: definition, listener: listener)
            if spatial.gain <= 0 { continue }
            let categoryGain = gains[definition.category] ?? 1
            let gain = definition.volume * categoryGain * spatial.gain
            let pan = max(-1, min(1, definition.pan + spatial.pan))
            let leftGain = gain * sqrt(0.5 * (1 - pan))
            let rightGain = gain * sqrt(0.5 * (1 + pan))

            for localFrame in 0..<frameCount {
                let absoluteFrame = blockStart + UInt64(localFrame)
                if absoluteFrame < voice.startFrame || absoluteFrame >= voice.endFrame { continue }
                let elapsed = Double(absoluteFrame - voice.startFrame) / sampleRate
                let progress = min(1, elapsed / definition.duration)
                let frequency: Double
                if let end = definition.endFrequency, definition.frequency > 0, end > 0 {
                    frequency = definition.frequency * pow(end / definition.frequency, progress)
                } else {
                    frequency = definition.frequency
                }
                let sample = waveformSample(&voice, frequency: frequency)
                let envelope: Double
                if elapsed < definition.attack {
                    envelope = elapsed / definition.attack
                } else {
                    let decay = (elapsed - definition.attack) / max(0.0001, definition.duration - definition.attack)
                    envelope = pow(0.001, min(1, decay))
                }
                output[localFrame * 2] += Float(sample * envelope * leftGain)
                output[localFrame * 2 + 1] += Float(sample * envelope * rightGain)
            }
            voices[voiceIndex] = voice
        }
        voices.removeAll { $0.endFrame <= blockStart + UInt64(frameCount) }

        let cutoff = underwater ? 700.0 : 20_000.0
        let coefficient = 1 - exp(-2 * Double.pi * cutoff / sampleRate)
        for frame in 0..<frameCount {
            let leftIndex = frame * 2
            let rightIndex = leftIndex + 1
            lowpassLeft += coefficient * (Double(output[leftIndex]) - lowpassLeft)
            lowpassRight += coefficient * (Double(output[rightIndex]) - lowpassRight)
            let dryLeft = Float(lowpassLeft)
            let dryRight = Float(lowpassRight)
            let wetLeft = delayLeft[delayCursorLeft]
            let wetRight = delayRight[delayCursorRight]
            let feedback = Float(cave * 0.32)
            delayLeft[delayCursorLeft] = dryLeft + wetRight * feedback
            delayRight[delayCursorRight] = dryRight + wetLeft * feedback
            delayCursorLeft = (delayCursorLeft + 1) % delayLeft.count
            delayCursorRight = (delayCursorRight + 1) % delayRight.count
            output[leftIndex] = softClip((dryLeft + wetLeft * Float(cave * 0.24)) * Float(master))
            output[rightIndex] = softClip((dryRight + wetRight * Float(cave * 0.24)) * Float(master))
        }

        lock.lock(); frameCursor += UInt64(frameCount); lock.unlock()
    }

    private func spatialMix(for voice: AudioVoice, listener: AudioListener) -> (gain: Double, pan: Double) {
        guard let position = voice.spatialPosition else { return (1, 0) }
        let delta = position - listener.position
        let distance = sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
        if distance >= voice.maxDistance { return (0, 0) }
        let normalized = max(0, 1 - distance / voice.maxDistance)
        let angle = atan2(-delta.x, delta.z) - listener.yaw
        let pan = -sin(angle) * min(1, distance / 4)
        return (normalized * normalized, pan)
    }

    private func waveformSample(_ voice: inout ActiveVoice, frequency: Double) -> Double {
        if case .noise = voice.definition.waveform {
            voice.noiseState ^= voice.noiseState << 13
            voice.noiseState ^= voice.noiseState >> 7
            voice.noiseState ^= voice.noiseState << 17
            return Double(Int64(bitPattern: voice.noiseState)) / Double(Int64.max)
        }
        voice.phase += frequency / sampleRate
        voice.phase -= floor(voice.phase)
        switch voice.definition.waveform {
        case .sine: return sin(voice.phase * 2 * .pi)
        case .square: return voice.phase < 0.5 ? 1 : -1
        case .sawtooth: return voice.phase * 2 - 1
        case .triangle: return 1 - 4 * abs(voice.phase - 0.5)
        case .noise: return 0
        }
    }

    private func softClip(_ value: Float) -> Float {
        value / (1 + abs(value))
    }
}

public final class NativeMixerOutput: @unchecked Sendable {
    public let mixer: AudioMixer
    private let device: NativeAudioDevice

    public init(mixer: AudioMixer, periodFrames: UInt32 = 512) throws {
        self.mixer = mixer
        device = try NativeAudioDevice(sampleRate: UInt32(mixer.sampleRate),
                                       channels: 2, periodFrames: periodFrames) { [mixer] buffer, frames, channels in
            guard channels == 2 else {
                for index in buffer.indices { buffer[index] = 0 }
                return
            }
            mixer.render(into: buffer, frameCount: frames)
        }
    }

    public func start() throws { try device.start() }
    public func stop() { device.stop() }
    public var underrunCount: UInt64 { device.underrunCount }
}
