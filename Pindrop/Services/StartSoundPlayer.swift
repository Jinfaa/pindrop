//
//  StartSoundPlayer.swift
//  Pindrop
//
//  Created on 2026-10-04.
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum StartSound: String, CaseIterable, Identifiable {
    case none
    case softChime
    case bubble
    case glass
    case breeze
    case marimba

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Off"
        case .softChime: return "Soft Chime"
        case .bubble: return "Bubble"
        case .glass: return "Glass"
        case .breeze: return "Breeze"
        case .marimba: return "Marimba"
        }
    }

    /// (frequency Hz, start offset s, decay time constant s, gain) per partial.
    fileprivate var partials: [(Double, Double, Double, Double)] {
        switch self {
        case .none: return []
        // Two-note rising chime, C6 → E6.
        case .softChime: return [(1046.5, 0, 0.18, 0.5), (1318.5, 0.09, 0.25, 0.5)]
        // Short low pop with a quiet octave.
        case .bubble: return [(660, 0, 0.06, 0.7), (1320, 0, 0.03, 0.15)]
        // Bell-like inharmonic partials.
        case .glass: return [(1760, 0, 0.35, 0.4), (4400, 0, 0.12, 0.08), (2637, 0, 0.2, 0.15)]
        // Slow, airy perfect fifth.
        case .breeze: return [(523.3, 0, 0.3, 0.35), (784, 0.04, 0.3, 0.3)]
        // Woody mallet with fast-decaying overtone.
        case .marimba: return [(880, 0, 0.12, 0.6), (3520, 0, 0.02, 0.2)]
        }
    }
}

@MainActor
final class StartSoundPlayer {
    private let sampleRate = 44_100.0
    private let baseGain: Float = 0.5
    private var engine: AVAudioEngine?
    /// Device state changed for the cue, restored in `finish()`.
    private var restore: (deviceID: AudioDeviceID, wasMuted: Bool, volume: Float?)?

    func play(_ sound: StartSound, outputDeviceUID: String, volume: Double) {
        guard sound != .none else { return }
        finish()

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = render(sound, format: format)
        let engine = AVAudioEngine()
        // Device must be set before the graph is built, otherwise the mixer keeps the default device's format.
        if !outputDeviceUID.isEmpty,
           var deviceID = AudioDeviceManager.outputDeviceID(for: outputDeviceUID),
           let unit = engine.outputNode.audioUnit {
            // An explicitly chosen device (e.g. built-in speakers while headphones are default) is often
            // muted or quiet; drive its own volume for the cue and restore afterwards.
            let wasMuted = AudioDeviceManager.isOutputMuted(deviceID)
            restore = (deviceID, wasMuted, AudioDeviceManager.outputVolume(deviceID))
            if wasMuted { AudioDeviceManager.setOutputMuted(deviceID, false) }
            AudioDeviceManager.setOutputVolume(deviceID, Float(volume))
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                Log.audio.error("Start sound: failed to set output device \(outputDeviceUID): \(status)")
            }
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            Log.audio.error("Start sound failed: \(error.localizedDescription)")
            finish()
            return
        }
        self.engine = engine
        player.scheduleBuffer(buffer) { [weak self, weak engine] in
            Task { @MainActor in
                guard let self, let engine, self.engine === engine else { return }
                // The completion fires when the buffer is consumed, slightly before it is heard.
                try? await Task.sleep(for: .milliseconds(300))
                guard self.engine === engine else { return }
                self.finish()
            }
        }
        // The device volume already carries the setting when a device is chosen.
        player.volume = restore == nil ? Float(volume) : 1
        player.play()
    }

    private func finish() {
        engine?.stop()
        engine = nil
        if let restore {
            if let volume = restore.volume { AudioDeviceManager.setOutputVolume(restore.deviceID, volume) }
            if restore.wasMuted { AudioDeviceManager.setOutputMuted(restore.deviceID, true) }
            self.restore = nil
        }
    }

    private func render(_ sound: StartSound, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let partials = sound.partials
        let length = partials.map { $0.1 + $0.2 * 6 }.max() ?? 0.1
        let frames = AVAudioFrameCount(length * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        let attack = 0.005
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            var sample = 0.0
            for (freq, offset, decay, gain) in partials where t >= offset {
                let local = t - offset
                let envelope = min(local / attack, 1) * exp(-local / decay)
                sample += gain * envelope * sin(2 * .pi * freq * local)
            }
            out[i] = Float(sample) * baseGain
        }
        return buffer
    }
}
