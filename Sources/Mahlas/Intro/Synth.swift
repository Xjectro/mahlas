import AVFoundation

/// Tiny procedural synth — every sound is generated in code, nothing is shipped
/// as an audio file. Port of the web intro's Web Audio synth to AVAudioEngine.
final class Synth {
    static let shared = Synth()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    private var started = false

    var muted: Bool {
        get { UserDefaults.standard.bool(forKey: "mahlas.muted") }
        set { UserDefaults.standard.set(newValue, forKey: "mahlas.muted") }
    }

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.85
    }

    private func ensureRunning() -> Bool {
        if muted { return false }
        if !started {
            do { try engine.start(); player.play(); started = true } catch { return false }
        }
        return true
    }

    // MARK: Building blocks

    private enum Wave { case sine, triangle, square }


    /// Renders a set of voices into one buffer and plays it.
    private func play(duration: Double, _ build: (inout [Float]) -> Void) {
        guard ensureRunning() else { return }
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        build(&samples)
        // gentle compressor-ish soft clip
        for i in 0..<count { samples[i] = tanhf(samples[i] * 1.2) * 0.9 }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buf.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: count)
        }
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
    }

    private func tone(_ out: inout [Float], freq: Double, wave: Wave = .sine, start: Double = 0,
                      dur: Double = 0.15, gain: Double = 0.2, to: Double? = nil, attack: Double = 0.005) {
        let s0 = Int(start * sampleRate)
        let n = Int(dur * sampleRate)
        var phase = 0.0
        for i in 0..<n {
            let idx = s0 + i
            guard idx < out.count else { break }
            let t = Double(i) / sampleRate
            let f = to.map { freq * pow($0 / freq, t / dur) } ?? freq
            phase += f / sampleRate
            let p = phase.truncatingRemainder(dividingBy: 1)
            let v: Double
            switch wave {
            case .sine: v = sin(2 * .pi * p)
            case .triangle: v = 1 - 4 * abs(p - 0.5)
            case .square: v = p < 0.5 ? 1 : -1
            }
            // exponential attack / decay envelope
            let env: Double = t < attack
                ? 0.0001 * pow(gain / 0.0001, t / attack)
                : gain * pow(0.0001 / gain, (t - attack) / max(dur - attack, 0.001))
            out[idx] += Float(v * env)
        }
    }

    private func noise(_ out: inout [Float], start: Double = 0, dur: Double = 0.4, gain: Double = 0.2,
                       from: Double = 400, to: Double = 4000, q: Double = 1.2) {
        let s0 = Int(start * sampleRate)
        let n = Int(dur * sampleRate)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<n {
            let idx = s0 + i
            guard idx < out.count else { break }
            let t = Double(i) / sampleRate
            let fc = from * pow(to / from, t / dur)
            // RBJ band-pass biquad, coefficients updated per sample for the sweep
            let w0 = 2 * .pi * min(fc, sampleRate * 0.45) / sampleRate
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            let b0 = alpha / a0, b2 = -alpha / a0
            let a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
            let x0 = Double.random(in: -1...1)
            let y0 = b0 * x0 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
            let peak = dur * 0.6
            let env: Double = t < peak
                ? 0.0001 * pow(gain / 0.0001, t / peak)
                : gain * pow(0.0001 / gain, (t - peak) / max(dur - peak, 0.001))
            out[idx] += Float(y0 * env * 2.2)
        }
    }

    // MARK: Sounds

    /// Heavy hit for each logo letter in the intro.
    func hit(_ i: Int) {
        play(duration: 0.7) { b in
            tone(&b, freq: 72 - Double(i) * 4, dur: 0.6, gain: 0.6, to: 32)
            noise(&b, dur: 0.12, gain: 0.1, from: 2000, to: 9000, q: 0.6)
        }
    }

    /// Rising swell + dark minor chord that closes the intro.
    func swell() {
        play(duration: 4.0) { b in
            noise(&b, dur: 1.4, gain: 0.18, from: 200, to: 9000, q: 0.8)
            // A minor-ish, darker than the original major voicing
            for (i, f) in [110.0, 130.8, 164.8, 220, 261.6].enumerated() {
                tone(&b, freq: f, wave: .triangle, start: 1.15, dur: 2.6, gain: 0.09, attack: 0.08 + Double(i) * 0.02)
            }
            tone(&b, freq: 55, start: 1.15, dur: 2.4, gain: 0.6, to: 40)
        }
    }

    func hover() {
        play(duration: 0.1) { b in
            tone(&b, freq: 2200, dur: 0.06, gain: 0.05, to: 1700)
            tone(&b, freq: 4400, dur: 0.04, gain: 0.015)
        }
    }

    func select() {
        play(duration: 0.3) { b in
            tone(&b, freq: 660, wave: .triangle, dur: 0.12, gain: 0.12)
            tone(&b, freq: 990, wave: .triangle, start: 0.06, dur: 0.18, gain: 0.12)
        }
    }

    /// Whoosh + impact used when a session spins up.
    func open() {
        play(duration: 0.9) { b in
            noise(&b, dur: 0.45, gain: 0.25, from: 300, to: 6000)
            tone(&b, freq: 140, start: 0.32, dur: 0.5, gain: 0.5, to: 38)
            tone(&b, freq: 523, wave: .square, start: 0.34, dur: 0.12, gain: 0.04)
            tone(&b, freq: 784, wave: .square, start: 0.40, dur: 0.12, gain: 0.04)
            tone(&b, freq: 1046, wave: .square, start: 0.46, dur: 0.22, gain: 0.04)
        }
    }

    func back() {
        play(duration: 0.35) { b in
            noise(&b, dur: 0.25, gain: 0.12, from: 5000, to: 400)
            tone(&b, freq: 700, wave: .triangle, dur: 0.18, gain: 0.1, to: 280)
        }
    }
}
