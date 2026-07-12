import PebbleAudioCore

public struct AudioSuite: PortableSuite {
    public static let name = "audio"

    public static func run(_ h: inout SmokeHarness) {
        let empty = AudioMixer(sampleRate: 1_000, maximumVoices: 8)
        h.eq("empty mixer emits stereo frame count", empty.render(frameCount: 12).count, 24)
        h.check("empty mixer is silent", empty.render(frameCount: 12).allSatisfy { $0 == 0 })
        h.check("zero-frame render is empty", empty.render(frameCount: 0).isEmpty)

        let tone = AudioMixer(sampleRate: 1_000, maximumVoices: 8)
        tone.enqueue(AudioVoice(waveform: .sine, frequency: 125, duration: 0.02,
                                attack: 0.001, volume: 0.5))
        let toneFrames = tone.render(frameCount: 32)
        h.check("tone produces samples", toneFrames.contains { abs($0) > 0.001 })
        h.check("centered tone matches channels", stride(from: 0, to: toneFrames.count, by: 2).allSatisfy {
            abs(toneFrames[$0] - toneFrames[$0 + 1]) < 0.000_001
        })
        h.check("finished tone is removed", tone.render(frameCount: 8).allSatisfy { abs($0) < 0.000_001 })

        let delayed = AudioMixer(sampleRate: 1_000)
        delayed.enqueue(AudioVoice(waveform: .square, frequency: 100, duration: 0.02,
                                   attack: 0.001, volume: 0.5, startDelay: 0.01))
        h.check("delayed voice starts silent", delayed.render(frameCount: 10).allSatisfy { $0 == 0 })
        h.check("delayed voice eventually sounds", delayed.render(frameCount: 10).contains { abs($0) > 0.001 })

        let panned = AudioMixer(sampleRate: 1_000)
        panned.enqueue(AudioVoice(waveform: .square, frequency: 100, duration: 0.02,
                                  attack: 0.001, volume: 0.5, pan: 1))
        let pannedFrames = panned.render(frameCount: 10)
        let leftEnergy = stride(from: 0, to: pannedFrames.count, by: 2).reduce(0.0) { $0 + Double(abs(pannedFrames[$1])) }
        let rightEnergy = stride(from: 1, to: pannedFrames.count, by: 2).reduce(0.0) { $0 + Double(abs(pannedFrames[$1])) }
        h.check("hard-right pan suppresses left", leftEnergy < 0.000_001)
        h.check("hard-right pan keeps right", rightEnergy > 0.01)

        let distant = AudioMixer(sampleRate: 1_000)
        distant.setListener(AudioListener(position: .zero, yaw: 0))
        distant.enqueue(AudioVoice(waveform: .square, frequency: 100, duration: 0.02,
                                   attack: 0.001, volume: 1,
                                   spatialPosition: SIMD3<Double>(20, 0, 0), maxDistance: 10))
        h.check("out-of-range spatial voice is silent", distant.render(frameCount: 20).allSatisfy { $0 == 0 })

        let muted = AudioMixer(sampleRate: 1_000)
        muted.setVolumes(master: 1, categories: ["ui": 0])
        muted.enqueue(AudioVoice(waveform: .square, frequency: 100, duration: 0.02,
                                 attack: 0.001, volume: 1, category: "ui"))
        h.check("category volume mutes voice", muted.render(frameCount: 20).allSatisfy { $0 == 0 })

        let stopped = AudioMixer(sampleRate: 1_000)
        stopped.enqueue(AudioVoice(waveform: .square, frequency: 100, duration: 1,
                                   attack: 0.001, volume: 1))
        stopped.stopAll()
        h.check("stopAll clears queued voices", stopped.render(frameCount: 20).allSatisfy { $0 == 0 })

        let noiseA = AudioMixer(sampleRate: 1_000)
        let noiseB = AudioMixer(sampleRate: 1_000)
        let noise = AudioVoice(waveform: .noise, duration: 0.02, attack: 0.001, volume: 0.5)
        noiseA.enqueue(noise)
        noiseB.enqueue(noise)
        h.eq("noise sequence is deterministic", noiseA.render(frameCount: 20), noiseB.render(frameCount: 20))

        let null = NullAudioService()
        var subtitle: String?
        null.onSubtitle = { subtitle = $0 }
        null.start(); null.playUI("click"); null.stop()
        h.check("null audio remains side-effect free", subtitle == nil)
    }
}
