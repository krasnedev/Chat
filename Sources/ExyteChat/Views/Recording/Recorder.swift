//
//  Recorder.swift
//  
//
//  Created by Alisa Mylnikova on 09.03.2023.
//

import Foundation
@preconcurrency import AVFoundation

final actor Recorder {

    // duration and waveform samples (always delivered on the main actor)
    typealias ProgressHandler = @MainActor @Sendable (Double, [CGFloat]) -> Void

    private let audioSession = AVAudioSession.sharedInstance()
    private var audioRecorder: AVAudioRecorder?
    private var audioTimer: Timer?

    private var soundSamples: [CGFloat] = []
    private var recorderSettings = RecorderSettings()

    var isAllowedToRecordAudio: Bool {
        audioSession.recordPermission == .granted
    }

    var isRecording: Bool {
        audioRecorder?.isRecording ?? false
    }

    func setRecorderSettings(_ recorderSettings: RecorderSettings) {
        self.recorderSettings = recorderSettings
    }

    func startRecording(durationProgressHandler: @escaping ProgressHandler) async -> URL? {
        if !isAllowedToRecordAudio {
            let granted = await audioSession.requestRecordPermission()
            if granted {
                return startRecordingInternal(durationProgressHandler)
            }
            return nil
        } else {
            return startRecordingInternal(durationProgressHandler)
        }
    }
    
    private func startRecordingInternal(_ durationProgressHandler: @escaping ProgressHandler) -> URL? {
        var settings: [String : Any] = [
            AVFormatIDKey: Int(recorderSettings.audioFormatID),
            AVSampleRateKey: Double(recorderSettings.sampleRate),
            AVNumberOfChannelsKey: recorderSettings.numberOfChannels,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        if recorderSettings.audioFormatID == kAudioFormatLinearPCM {
            settings[AVLinearPCMBitDepthKey] = recorderSettings.linearPCMBitDepth
            settings[AVLinearPCMIsFloatKey] = recorderSettings.linearPCMIsFloatKey
            settings[AVLinearPCMIsBigEndianKey] = recorderSettings.linearPCMIsBigEndianKey
            settings[AVLinearPCMIsNonInterleaved] = recorderSettings.linearPCMIsNonInterleaved
        } else {
            settings[AVEncoderBitRateKey] = recorderSettings.encoderBitRateKey
        }

        soundSamples = []
        guard let fileExt = fileExtension(for: recorderSettings.audioFormatID) else{
            return nil
        }
        let recordingUrl = FileManager.tempDirPath.appendingPathComponent(UUID().uuidString + fileExt)

        do {
            try audioSession.setCategory(.record, mode: .default)
            try audioSession.setActive(true)
            audioRecorder = try AVAudioRecorder(url: recordingUrl, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            Task { @MainActor in
                durationProgressHandler(0.0, [])
            }

            DispatchQueue.main.async { [weak self] in
                let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task {
                        await self?.onTimer(durationProgressHandler)
                    }
                }
                RunLoop.current.add(timer, forMode: .common)
                Task { [weak self] in
                    await self?.replaceTimer(with: timer)
                }
            }

            return recordingUrl
        } catch {
            stopRecording()
            return nil
        } 
    }

    func onTimer(_ durationProgressHandler: @escaping ProgressHandler) async {
        audioRecorder?.updateMeters()
        if let power = audioRecorder?.averagePower(forChannel: 0) {
            // power from 0 db (max) to -60 db (roughly min)
            let adjustedPower = 1 - (max(power, -60) / 60 * -1)
            let clamped = min(max(adjustedPower, 0), 1)
            soundSamples.append(CGFloat(clamped))
        }
        if let time = audioRecorder?.currentTime {
            await durationProgressHandler(time, soundSamples)
        }
    }

    func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        audioTimer?.invalidate()
        audioTimer = nil
    }

    private func replaceTimer(with timer: Timer?) {
        audioTimer?.invalidate()
        audioTimer = timer
    }

    private func fileExtension(for formatID: AudioFormatID) -> String? {
        switch formatID {
        case kAudioFormatMPEG4AAC:
            return ".aac"
        case kAudioFormatLinearPCM:
            return ".wav"
        case kAudioFormatMPEGLayer3:
            return ".mp3"
        case kAudioFormatAppleLossless:
            return ".m4a"
        case kAudioFormatOpus:
            return ".opus"
        case kAudioFormatAC3:
            return ".ac3"
        case kAudioFormatFLAC:
            return ".flac"
        case kAudioFormatAMR:
            return ".amr"
        case kAudioFormatMIDIStream:
            return ".midi"
        case kAudioFormatULaw:
            return ".ulaw"
        case kAudioFormatALaw:
            return ".alaw"
        case kAudioFormatAMR_WB:
            return ".awb"
        case kAudioFormatEnhancedAC3:
            return ".eac3"
        case kAudioFormatiLBC:
            return ".ilbc"
        default:
            return nil
        }
    }
}

public struct RecorderSettings : Codable,Hashable {
    var audioFormatID: AudioFormatID
    var sampleRate: CGFloat
    var numberOfChannels: Int
    var encoderBitRateKey: Int
    // pcm
    var linearPCMBitDepth: Int
    var linearPCMIsFloatKey: Bool
    var linearPCMIsBigEndianKey: Bool
    var linearPCMIsNonInterleaved: Bool

    public init(audioFormatID: AudioFormatID = kAudioFormatMPEG4AAC,
                sampleRate: CGFloat = 12000,
                numberOfChannels: Int = 1,
                encoderBitRateKey: Int = 128_000,
                linearPCMBitDepth: Int = 16,
                linearPCMIsFloatKey: Bool = false,
                linearPCMIsBigEndianKey: Bool = false,
                linearPCMIsNonInterleaved: Bool = false) {
        self.audioFormatID = audioFormatID
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.encoderBitRateKey = encoderBitRateKey
        self.linearPCMBitDepth = linearPCMBitDepth
        self.linearPCMIsFloatKey = linearPCMIsFloatKey
        self.linearPCMIsBigEndianKey = linearPCMIsBigEndianKey
        self.linearPCMIsNonInterleaved = linearPCMIsNonInterleaved
    }
}

extension AVAudioSession {
    func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
