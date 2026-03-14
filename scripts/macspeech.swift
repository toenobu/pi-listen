#!/usr/bin/env swift
//
// macspeech.swift - macOS Speech Recognition for pi-listen
//
// Records audio using AVAudioEngine and transcribes using SFSpeechRecognizer.
// No external dependencies (no SoX required).
//
// Usage:
//   ./macspeech --record --locale en-US    # Record until stdin closes, then transcribe
//   ./macspeech --file audio.wav --locale en-US  # Transcribe existing file
//   ./macspeech --list-locales             # List supported locales
//
// Output format (JSON):
//   {"text": "transcribed text", "error": null}
//   {"text": null, "error": "error message"}
//

import Foundation
import Speech
import AVFoundation

// MARK: - JSON Output

struct Result: Codable {
    let text: String?
    let error: String?
}

func output(_ text: String? = nil, error: String? = nil) {
    let result = Result(text: text, error: error)
    if let json = try? JSONEncoder().encode(result),
       let str = String(data: json, encoding: .utf8) {
        print(str)
    }
    fflush(stdout)
}

// MARK: - List Locales

func listLocales() {
    let locales = SFSpeechRecognizer.supportedLocales()
    let ids = locales.map { $0.identifier }.sorted()
    for id in ids {
        print(id)
    }
}

// MARK: - Audio Recording

class AudioRecorder {
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private let tempURL: URL
    
    init() {
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pi-voice-\(ProcessInfo.processInfo.processIdentifier).wav")
    }
    
    func startRecording() -> Bool {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        // Create audio file for recording
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        do {
            audioFile = try AVAudioFile(forWriting: tempURL, settings: settings)
        } catch {
            output(error: "Failed to create audio file: \(error.localizedDescription)")
            return false
        }
        
        // Convert format to 16kHz mono for speech recognition
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            output(error: "Failed to create target audio format")
            return false
        }
        
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            output(error: "Failed to create audio converter")
            return false
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }
            
            // Convert to target format
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / format.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
            
            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            if error == nil && convertedBuffer.frameLength > 0 {
                do {
                    try audioFile.write(from: convertedBuffer)
                } catch {
                    // Ignore write errors during recording
                }
            }
        }
        
        do {
            try audioEngine.start()
            return true
        } catch {
            output(error: "Failed to start audio engine: \(error.localizedDescription)")
            return false
        }
    }
    
    func stopRecording() -> URL {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioFile = nil
        return tempURL
    }
    
    func cleanup() {
        try? FileManager.default.removeItem(at: tempURL)
    }
}

// MARK: - Transcribe

func transcribe(fileURL: URL, locale: String) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        output(error: "File not found: \(fileURL.path)")
        return
    }
    
    // Check file size
    do {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = attrs[.size] as? Int, size < 1000 {
            output("")  // Empty/silent recording
            return
        }
    } catch {
        output(error: "Failed to read file: \(error.localizedDescription)")
        return
    }
    
    let speechLocale = Locale(identifier: locale)
    guard let recognizer = SFSpeechRecognizer(locale: speechLocale) else {
        output(error: "Could not create speech recognizer for locale: \(locale)")
        return
    }
    
    guard recognizer.isAvailable else {
        output(error: "Speech recognizer not available for locale: \(locale)")
        return
    }
    
    // Check authorization
    let semaphore = DispatchSemaphore(value: 0)
    var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    
    SFSpeechRecognizer.requestAuthorization { status in
        authStatus = status
        semaphore.signal()
    }
    
    _ = semaphore.wait(timeout: .now() + 30)
    
    guard authStatus == .authorized else {
        let statusName: String
        switch authStatus {
        case .notDetermined: statusName = "notDetermined"
        case .denied: statusName = "denied"
        case .restricted: statusName = "restricted"
        case .authorized: statusName = "authorized"
        @unknown default: statusName = "unknown"
        }
        output(error: "Speech recognition not authorized (\(statusName)). Enable in System Settings > Privacy & Security > Speech Recognition")
        return
    }
    
    // Create recognition request
    let request = SFSpeechURLRecognitionRequest(url: fileURL)
    request.shouldReportPartialResults = false
    
    var resultText: String? = nil
    var resultError: String? = nil
    let doneSemaphore = DispatchSemaphore(value: 0)
    
    recognizer.recognitionTask(with: request) { result, error in
        if let error = error {
            resultError = error.localizedDescription
            doneSemaphore.signal()
            return
        }
        
        if let result = result, result.isFinal {
            resultText = result.bestTranscription.formattedString
            doneSemaphore.signal()
        }
    }
    
    // Wait for completion (60s timeout)
    let waitResult = doneSemaphore.wait(timeout: .now() + 60)
    
    if waitResult == .timedOut {
        output(error: "Transcription timeout (60s)")
        return
    }
    
    if let error = resultError {
        output(error: error)
        return
    }
    
    output(resultText ?? "")
}

// MARK: - Main

func main() {
    let args = CommandLine.arguments
    
    if args.contains("--list-locales") {
        listLocales()
        exit(0)
    }
    
    var file: String? = nil
    var locale = "en-US"
    var recordMode = false
    
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--file":
            i += 1
            if i < args.count {
                file = args[i]
            }
        case "--locale":
            i += 1
            if i < args.count {
                locale = args[i]
            }
        case "--record":
            recordMode = true
        default:
            break
        }
        i += 1
    }
    
    if let audioFile = file {
        // Transcribe existing file
        transcribe(fileURL: URL(fileURLWithPath: audioFile), locale: locale)
        exit(0)
    }
    
    if recordMode {
        // Record mode: record until stdin closes (newline or EOF), then transcribe
        let recorder = AudioRecorder()
        
        if !recorder.startRecording() {
            exit(1)
        }
        
        // Wait for signal to stop (read a line from stdin)
        _ = readLine()
        
        let audioURL = recorder.stopRecording()
        transcribe(fileURL: audioURL, locale: locale)
        recorder.cleanup()
        exit(0)
    }
    
    // No valid mode specified
    output(error: "Usage: macspeech --record --locale <locale> OR macspeech --file <audio.wav> --locale <locale>")
    exit(1)
}

main()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
