import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Plays a short, distinctive double-beep whenever a *new* vehicle is detected.
///
/// The tone is synthesised into an in-memory WAV so there are no asset files to
/// manage, and the audio session uses the `.playback` category so the beep is
/// heard even when the ringer/silent switch is off and ducks any music playing.
final class AudioAlerts: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {

    static let shared = AudioAlerts()

    private var player: AVAudioPlayer?
    private var configured = false

    /// Spoken vehicle call-outs (for riders using bone-conduction headphones who
    /// want a voice instead of, or alongside, the beep).
    private let synthesizer = AVSpeechSynthesizer()

    // Hidden system-volume control used to force the output to maximum so the
    // car-behind alert is always loud, regardless of the current volume.
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))

    private override init() {
        super.init()
        prepare()
        synthesizer.delegate = self
    }

    private func prepare() {
        let data = AudioAlerts.makeDoubleBeepWAV()
        player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
        player?.delegate = self
        player?.prepareToPlay()
    }

    private func configureSessionIfNeeded() {
        guard !configured else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers, .duckOthers])
        configured = true
    }

    /// Fire the new-vehicle alert. Safe to call from any thread.
    func playNewCar() {
        DispatchQueue.main.async {
            self.configureSessionIfNeeded()
            self.forceMaxVolume()
            try? AVAudioSession.sharedInstance().setActive(true)
            self.player?.volume = 1.0
            self.player?.currentTime = 0
            self.player?.play()
        }
    }

    /// Speak a short vehicle call-out. Skips if a call-out is already in progress
    /// so heavy traffic can't make the voice pile up and lag behind the road.
    /// `language` is a BCP-47 code (e.g. "de-DE") to match the app's language.
    func speak(_ text: String, language: String?) {
        DispatchQueue.main.async {
            guard !self.synthesizer.isSpeaking else { return }
            self.configureSessionIfNeeded()
            self.forceMaxVolume()
            try? AVAudioSession.sharedInstance().setActive(true)
            let utterance = AVSpeechUtterance(string: text)
            if let language, let voice = AVSpeechSynthesisVoice(language: language) {
                utterance.voice = voice
            }
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            self.synthesizer.speak(utterance)
        }
    }

    /// Drive the system output volume to maximum via a hidden MPVolumeView.
    /// Must run on the main thread.
    private func forceMaxVolume() {
        if volumeView.superview == nil {
            attachVolumeView()
        }
        if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
            slider.value = 1.0
            slider.sendActions(for: .valueChanged)
        }
    }

    private func attachVolumeView() {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ??
            (UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }.first)
        guard let window else { return }
        volumeView.alpha = 0.001
        volumeView.isUserInteractionEnabled = false
        window.addSubview(volumeView)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        releaseSessionIfQuiet()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        releaseSessionIfQuiet()
    }

    /// Release the audio session so other audio (music/podcasts) un-ducks
    /// promptly — but only once neither the beep nor the voice is still playing,
    /// so they don't cut each other off when both alerts are enabled.
    private func releaseSessionIfQuiet() {
        guard !(player?.isPlaying ?? false), !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Tone synthesis

    /// Two quick ascending beeps — easy to recognise as "car behind".
    private static func makeDoubleBeepWAV() -> Data {
        let sampleRate = 44_100.0
        var samples: [Int16] = []
        samples += tone(frequency: 1480, duration: 0.10, sampleRate: sampleRate)
        samples += silence(duration: 0.04, sampleRate: sampleRate)
        samples += tone(frequency: 1860, duration: 0.12, sampleRate: sampleRate)
        return wav(from: samples, sampleRate: Int(sampleRate))
    }

    private static func tone(frequency: Double, duration: Double, sampleRate: Double) -> [Int16] {
        let count = Int(duration * sampleRate)
        let amplitude = 0.8 * Double(Int16.max)
        let fade = max(1, Int(0.006 * sampleRate))   // short fade in/out kills clicks
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            var env = 1.0
            if i < fade { env = Double(i) / Double(fade) }
            else if i > count - fade { env = Double(count - i) / Double(fade) }
            let value = sin(2.0 * Double.pi * frequency * Double(i) / sampleRate) * amplitude * env
            out[i] = Int16(max(-Double(Int16.max), min(Double(Int16.max), value)))
        }
        return out
    }

    private static func silence(duration: Double, sampleRate: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(duration * sampleRate))
    }

    /// Wrap mono 16-bit PCM samples in a minimal WAV container.
    private static func wav(from samples: [Int16], sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * bitsPerSample / 8

        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        func append32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func append16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }

        append("RIFF")
        append32(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append32(16)                       // PCM fmt chunk size
        append16(1)                        // PCM format
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(byteRate))
        append16(UInt16(blockAlign))
        append16(UInt16(bitsPerSample))
        append("data")
        append32(UInt32(dataSize))
        for sample in samples {
            var x = sample.littleEndian
            data.append(Data(bytes: &x, count: 2))
        }
        return data
    }
}
