// heimaudio-helfer: small macOS helper for the HeimAudio service.
//
//   heimaudio-helfer media-key play|next|previous   presses a media key (like on the keyboard)
//   heimaudio-helfer capture [--aac BIT/S]          writes the system audio to stdout
//   heimaudio-helfer test-tone [--aac BIT/S]        writes a beeping test tone to stdout
//   heimaudio-helfer service                        starts the HeimAudio service (for autostart)
//
// Audio format without --aac: 16-bit integers (little endian), 48 kHz, stereo, interleaved (L R L R ...).
// With --aac (e.g. --aac 96000): AAC-LC, 48 kHz, stereo. Every packet starts with a
// 7-byte ADTS header that contains its length, so the stream can be split up again.
//
// Messages on stderr are shown to the user in the app and are therefore German.

import AppKit
import AVFoundation
import CoreMedia
import os
import ScreenCaptureKit

// Entries in the system log, show them with:
// log show --last 10m --predicate 'subsystem == "heimaudio"'
let logger = Logger(subsystem: "heimaudio", category: "helper")

let sampleRate = 48_000
let channels = 2

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func toInt16(_ value: Float) -> Int16 {
    Int16(max(-1, min(1, value)) * Float(Int16.max))
}

// MARK: - Output: uncompressed or AAC

// Takes audio (floats from -1 to 1, interleaved L R L R ...) and writes it to stdout.
protocol AudioOutput: AnyObject {
    func write(_ samples: UnsafeBufferPointer<Float>)
}

// Uncompressed: 16-bit integers. About 1.5 Mbit/s.
final class PCMOutput: AudioOutput {
    func write(_ samples: UnsafeBufferPointer<Float>) {
        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            let target = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                target[i] = toInt16(samples[i]).littleEndian
            }
        }
        FileHandle.standardOutput.write(data)
    }
}

// Compressed with AAC, which Mac and iPhone support out of the box.
final class AACOutput: AudioOutput {
    private let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: AVAudioChannelCount(channels),
        interleaved: true
    )!
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(bitRate: Int) {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let outputFormat = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { fail("AAC-Kodierer nicht verfügbar") }
        self.outputFormat = outputFormat
        self.converter = converter
        converter.bitRate = bitRate
    }

    func write(_ samples: UnsafeBufferPointer<Float>) {
        let frames = samples.count / channels
        guard frames > 0, let base = samples.baseAddress,
              let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let target = pcm.floatChannelData?[0] // interleaved format: all channels in one buffer
        else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        target.update(from: base, count: samples.count)

        // The encoder collects internally until 1024 frames for one packet are together.
        var delivered = false
        while true {
            let packets = AVAudioCompressedBuffer(
                format: outputFormat,
                packetCapacity: 16,
                maximumPacketSize: max(converter.maximumOutputPacketSize, 1536)
            )
            var error: NSError?
            let status = converter.convert(to: packets, error: &error) { _, inputStatus in
                if delivered {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                delivered = true
                inputStatus.pointee = .haveData
                return pcm
            }
            writePackets(packets)
            if status != .haveData { break }
        }
    }

    // Every AAC packet gets a 7-byte ADTS header containing its length.
    private func writePackets(_ packets: AVAudioCompressedBuffer) {
        guard let descriptions = packets.packetDescriptions, packets.packetCount > 0 else { return }
        var data = Data()
        for i in 0..<Int(packets.packetCount) {
            let size = Int(descriptions[i].mDataByteSize)
            let length = size + 7
            let header: [UInt8] = [
                0xFF, 0xF1,                                        // sync word, MPEG-4, no checksum
                UInt8((1 << 6) | (3 << 2) | (channels >> 2)),      // AAC-LC, 48 kHz
                UInt8(((channels & 3) << 6) | (length >> 11)),
                UInt8((length >> 3) & 0xFF),
                UInt8(((length & 7) << 5) | 0x1F),
                0xFC,
            ]
            data.append(contentsOf: header)
            let start = packets.data.advanced(by: Int(descriptions[i].mStartOffset))
            data.append(start.assumingMemoryBound(to: UInt8.self), count: size)
        }
        FileHandle.standardOutput.write(data)
    }
}

// Reads "--aac BITRATE" from the arguments. Without it: uncompressed.
func chooseOutput(_ arguments: [String]) -> AudioOutput {
    guard let index = arguments.firstIndex(of: "--aac") else { return PCMOutput() }
    guard index + 1 < arguments.count, let bitRate = Int(arguments[index + 1]),
          (32_000...320_000).contains(bitRate)
    else { fail("--aac braucht eine Bitrate zwischen 32000 und 320000") }
    return AACOutput(bitRate: bitRate)
}

// MARK: - Media keys

func pressMediaKey(_ name: String) {
    logger.notice("Key requested: \(name, privacy: .public)")
    // Key codes from IOKit, as sent by the media keys of the Apple keyboard:
    // ⏯ = NX_KEYTYPE_PLAY (16), ⏭ = NX_KEYTYPE_FAST (19), ⏮ = NX_KEYTYPE_REWIND (20).
    // (NX_KEYTYPE_NEXT/PREVIOUS = 17/18 have no effect on playback.)
    let codes = ["play": 16, "next": 19, "previous": 20]
    guard let code = codes[name] else { fail("Unbekannte Taste: \(name)") }

    // Only programs allowed under
    // System Settings > Privacy & Security > Accessibility may simulate key presses.
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)
    logger.notice("Accessibility allowed: \(trusted, privacy: .public)")
    guard trusted else {
        fail("Freigabe fehlt: Systemeinstellungen > Datenschutz & Sicherheit > Bedienungshilfen", code: 2)
    }
    defer { logger.notice("Key sent: \(name, privacy: .public)") }

    for isDown in [true, false] {
        let state = isDown ? 0xA : 0xB
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (code << 16) | (state << 8),
            data2: -1
        ) else { fail("Tastendruck konnte nicht erzeugt werden") }
        event.cgEvent?.post(tap: .cghidEventTap)
        // Wait briefly, like a real key press.
        Thread.sleep(forTimeInterval: 0.03)
    }
    // Don't exit right away: otherwise the key presses may get lost.
    Thread.sleep(forTimeInterval: 0.2)
}

// MARK: - Test tone

// Beeps at 440 Hz for half a second every second. This also makes the delay audible.
func playTestTone(_ output: AudioOutput) -> Never {
    let blockFrames = sampleRate / 50 // 20 ms per block
    let step = 2 * Double.pi * 440 / Double(sampleRate)
    var phase = 0.0
    var framesWritten = 0
    var block = [Float](repeating: 0, count: blockFrames * channels)
    let start = Date()

    while true {
        for i in 0..<blockFrames {
            let positionInSecond = (framesWritten + i) % sampleRate
            let isLoud = positionInSecond < sampleRate / 2
            let value = isLoud ? Float(sin(phase) * 0.3) : 0
            phase += step
            if phase > 2 * .pi { phase -= 2 * .pi }
            for channel in 0..<channels {
                block[i * channels + channel] = value
            }
        }
        block.withUnsafeBufferPointer { output.write($0) }
        framesWritten += blockFrames

        // Don't deliver faster than real time.
        let lead = Double(framesWritten) / Double(sampleRate) - Date().timeIntervalSince(start)
        if lead > 0 { Thread.sleep(forTimeInterval: lead) }
    }
}

// MARK: - Capture system audio

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let output: AudioOutput
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "heimaudio.capture")
    private var lastOutput = DispatchTime.now()
    private var silenceTimer: DispatchSourceTimer?
    private var buffer: [Float] = []

    init(output: AudioOutput) {
        self.output = output
        super.init()
    }

    private func forward(_ samples: UnsafeBufferPointer<Float>) {
        output.write(samples)
        lastOutput = .now()
    }

    // When nothing is playing on the computer, ScreenCaptureKit may deliver no data.
    // Then we send silence so the app doesn't think the connection is dead.
    private func fillSilence() {
        let gap = DispatchTime.now().uptimeNanoseconds - lastOutput.uptimeNanoseconds
        guard gap > 150_000_000 else { return }
        let silence = [Float](repeating: 0, count: sampleRate / 20 * channels) // 50 ms
        silence.withUnsafeBufferPointer { forward($0) }
    }

    func start() async throws {
        // Only programs allowed under
        // System Settings > Privacy & Security > Screen & System Audio Recording may capture system audio.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            fail("Freigabe fehlt: Systemeinstellungen > Datenschutz & Sicherheit > Bildschirm- & Systemaudioaufnahme", code: 3)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { fail("Kein Bildschirm gefunden") }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = sampleRate
        configuration.channelCount = channels
        // We don't need the picture: as small and rare as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Screen output only so ScreenCaptureKit doesn't complain about dropped frames.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.fillSilence() }
        timer.resume()
        silenceTimer = timer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { return }

        // Rearrange into interleaved floats (L R L R ...)
        let frames = sampleBuffer.numSamples
        if buffer.count != frames * channels {
            buffer = [Float](repeating: 0, count: frames * channels)
        }

        try? sampleBuffer.withAudioBufferList { bufferList, _ in
            buffer.withUnsafeMutableBufferPointer { target in
                if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                    // One buffer per channel
                    for channel in 0..<channels {
                        let sourceBuffer = bufferList[min(channel, bufferList.count - 1)]
                        guard let source = sourceBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for i in 0..<frames {
                            target[i * channels + channel] = source[i]
                        }
                    }
                } else if let source = bufferList[0].mData?.assumingMemoryBound(to: Float.self) {
                    // All channels in one buffer
                    let sourceChannels = max(1, Int(bufferList[0].mNumberChannels))
                    for i in 0..<frames {
                        for channel in 0..<channels {
                            target[i * channels + channel] = source[i * sourceChannels + min(channel, sourceChannels - 1)]
                        }
                    }
                }
            }
        }

        buffer.withUnsafeBufferPointer { forward($0) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail("Mitschnitt beendet: \(error.localizedDescription)")
    }
}

// MARK: - Start the service (for autostart)

// macOS starts this program at login, and it starts the Python service as a child process.
// That way macOS asks for the permissions (Accessibility, audio capture) for heimaudio-helfer,
// not for Python or the Terminal.
func runService(extraArguments: [String]) -> Never {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        fail("Eigener Pfad nicht gefunden")
    }
    let script = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("heimaudio.py")

    let service = Process()
    service.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    service.arguments = ["-u", script.path] + extraArguments
    service.terminationHandler = { exit($0.terminationStatus) }

    // When stopped (e.g. by launchctl), stop the service too.
    let signalSources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { service.terminate() }
        source.resume()
        return source
    }

    do {
        try service.run()
    } catch {
        fail("Dienst konnte nicht starten: \(error.localizedDescription)")
    }
    withExtendedLifetime(signalSources) { dispatchMain() }
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "media-key":
    guard arguments.count == 2 else { fail("Aufruf: heimaudio-helfer media-key play|next|previous") }
    pressMediaKey(arguments[1])

case "test-tone":
    playTestTone(chooseOutput(arguments))

case "service":
    runService(extraArguments: Array(arguments.dropFirst()))

case "capture":
    let capture = AudioCapture(output: chooseOutput(arguments))
    Task {
        do {
            try await capture.start()
        } catch {
            fail("Mitschnitt konnte nicht starten: \(error.localizedDescription)", code: 3)
        }
    }
    dispatchMain()

default:
    fail("Aufruf: heimaudio-helfer media-key play|next|previous | capture [--aac BIT/S] | test-tone [--aac BIT/S] | service")
}
