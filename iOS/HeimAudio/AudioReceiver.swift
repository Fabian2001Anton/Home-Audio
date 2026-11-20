import Accelerate
import AVFoundation
import MediaPlayer
import Network
import Observation
import os
import UIKit

// Receives the computer's audio and plays it on the iPhone.
// Two formats, depending on the computer's X-Format header:
//   s16le     uncompressed: 16-bit integers, 48 kHz, stereo, interleaved (L R L R ...)
//   aac-adts  economical: AAC packets, each with a 7-byte ADTS header
//
// While the audio is running, the app is the "Now Playing" app: AirPods, headphone buttons,
// the lock screen, Control Center and CarPlay control the computer through it.
// Log entries, show them in Console.app with: subsystem heimaudio
private let logger = Logger(subsystem: "heimaudio", category: "audio")

@Observable
final class AudioReceiver: NSObject, URLSessionDataDelegate {
    enum State: Equatable {
        case off
        case connecting
        case playing
        case failed(String)
    }

    enum Quality: String, CaseIterable, Identifiable {
        case automatic, best, economical

        var id: String { rawValue }

        // Shown in the app
        var title: String {
            switch self {
            case .automatic: "Automatisch"
            case .best: "Beste Qualität"
            case .economical: "Sparsam"
            }
        }
    }

    private(set) var state: State = .off
    // Is the audio currently compressed?
    private(set) var isEconomical = false
    // Output paused because nothing is audible on the computer (see schedule).
    private(set) var isPaused = false

    var isActive: Bool {
        state == .connecting || state == .playing
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let aacFormat: AVAudioFormat = {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        return AVAudioFormat(streamDescription: &description)!
    }()
    private let bytesPerFrame = 4 // uncompressed: 2 channels × 2 bytes
    private let networkMonitor = NWPathMonitor()

    // Start playing once 0.2 s of audio is buffered. If more than 0.5 s is buffered,
    // new data is dropped so the delay doesn't keep growing.
    private let startBuffer: AVAudioFrameCount = 9_600
    private let maxBuffer: AVAudioFrameCount = 24_000

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var pending = Data()
    @ObservationIgnored private var buffered: AVAudioFrameCount = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var decoder: AVAudioConverter?
    @ObservationIgnored private var networkIsExpensive = false
    @ObservationIgnored private var networkKnown = false
    @ObservationIgnored private var networkChange: DispatchWorkItem?
    @ObservationIgnored private var lastAPI: ComputerAPI?
    @ObservationIgnored private var quality: Quality = .automatic
    @ObservationIgnored private var retries = 0
    private let maxRetries = 3

    // Is something audible coming from the computer? Measured on the incoming audio.
    @ObservationIgnored private var computerName = ""
    @ObservationIgnored private var lastSoundAt: Date?
    @ObservationIgnored private var ignoreSoundUntil = Date.distantPast
    @ObservationIgnored private var outputEpoch = 0 // changes when the output pauses
    private let soundThreshold: Float = 0.001 // about -60 dB
    private let silenceAfter: TimeInterval = 2

    override init() {
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // E.g. when headphones are connected, the audio output stops. Then restart it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(outputChanged),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        // Headphones removed or AirPods disconnected
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(routeChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        // Phone call or alarm: afterwards the audio output has to be restarted.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(interrupted),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        setUpRemoteCommands()
        // Detect cellular: iOS marks such connections as "expensive".
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let isExpensive = path.isExpensive
            DispatchQueue.main.async { self?.networkChanged(isExpensive: isExpensive) }
        }
        networkMonitor.start(queue: DispatchQueue(label: "heimaudio.network"))
    }

    func start(with api: ComputerAPI, computerName: String? = nil, quality: Quality, isRetry: Bool = false) {
        cleanUp()
        if !isRetry {
            retries = 0
        }
        lastAPI = api
        if let computerName {
            self.computerName = computerName
        }
        self.quality = quality
        lastSoundAt = nil
        ignoreSoundUntil = .distantPast
        setRemoteCommandsEnabled(true)
        updateNowPlaying()
        isEconomical = quality == .economical || (quality == .automatic && networkIsExpensive)
        state = .connecting

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback)
            try audioSession.setActive(true)
            try engine.start()
        } catch {
            fail("Tonausgabe konnte nicht starten: \(error.localizedDescription)")
            return
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        var request = api.audioRequest(economical: isEconomical)
        request.timeoutInterval = 15
        session.dataTask(with: request).resume()
    }

    func stop() {
        cleanUp()
        state = .off
        endNowPlaying()
    }

    private func fail(_ message: String) {
        state = .failed(message)
        endNowPlaying()
    }

    private func cleanUp() {
        generation += 1
        session?.invalidateAndCancel()
        session = nil
        player.stop()
        engine.stop()
        isPaused = false
        outputEpoch += 1
        pending = Data()
        buffered = 0
        decoder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Switching between Wi-Fi and cellular: with "automatic", reconnect with the matching quality.
    private func networkChanged(isExpensive: Bool) {
        // Take the first report at startup right away.
        guard networkKnown else {
            networkIsExpensive = isExpensive
            networkKnown = true
            return
        }
        networkChange?.cancel()
        guard isExpensive != networkIsExpensive else { return }

        // Only react once the new state lasts 10 seconds. iOS e.g. briefly reports cellular
        // with Wi-Fi Assist. Every reconnect would be an audible dropout.
        let change = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.networkIsExpensive = isExpensive
            if self.isActive, self.quality == .automatic, self.isEconomical != isExpensive, let api = self.lastAPI {
                // The computer name is kept from the last start.
                self.start(with: api, quality: self.quality)
            }
        }
        networkChange = change
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: change)
    }

    private static func succeeded(_ task: URLSessionTask) -> Bool {
        (task.response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Data from the computer

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === self.session else { return }
        pending.append(data)
        guard let response = dataTask.response as? HTTPURLResponse, response.statusCode == 200 else { return }
        if response.value(forHTTPHeaderField: "X-Format") == "aac-adts" {
            processAAC()
        } else {
            processPCM()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session else { return }

        // Messages for the user (German)
        let message: String
        if task.response != nil && !Self.succeeded(task) {
            message = (try? JSONDecoder().decode(ErrorResponse.self, from: pending))?.error
                ?? "Der Rechner hat den Ton abgelehnt."
        } else if let error {
            message = error.localizedDescription
        } else {
            message = "Der Rechner hat den Ton beendet."
        }

        // If the audio was already playing, this is more likely a short dropout (dead spot, service
        // restarted): reconnect by ourselves after one second, at most three times in a row.
        let wasPlaying = Self.succeeded(task)
        cleanUp()
        if wasPlaying, retries < maxRetries, let api = lastAPI {
            retries += 1
            state = .connecting
            let currentGeneration = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                // Stopped or restarted in the meantime? Then do nothing.
                guard let self, self.generation == currentGeneration, self.state == .connecting else { return }
                self.start(with: api, quality: self.quality, isRetry: true)
            }
            return
        }
        fail(message)
    }

    // MARK: - Uncompressed

    private func processPCM() {
        let frames = pending.count / bytesPerFrame
        guard frames > 0 else { return }
        defer { pending = Data(pending.dropFirst(frames * bytesPerFrame)) }

        let frameCount = AVAudioFrameCount(frames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData
        else { return }
        buffer.frameLength = frameCount

        pending.withUnsafeBytes { raw in
            for i in 0..<frames {
                let left = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * bytesPerFrame, as: Int16.self))
                let right = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * bytesPerFrame + 2, as: Int16.self))
                channels[0][i] = Float(left) / 32_768
                channels[1][i] = Float(right) / 32_768
            }
        }
        schedule(buffer)
    }

    // MARK: - Economical (AAC)

    // Splits the stream into packets at the ADTS headers and decodes them into audio.
    private func processAAC() {
        var packets: [(start: Int, length: Int)] = []
        var position = 0
        pending.withUnsafeBytes { raw in
            while position + 7 <= raw.count {
                // Every header starts with 12 set bits. Otherwise: search one byte further.
                guard raw[position] == 0xFF, raw[position + 1] & 0xF0 == 0xF0 else {
                    position += 1
                    continue
                }
                let length = (Int(raw[position + 3] & 0x03) << 11) | (Int(raw[position + 4]) << 3) | (Int(raw[position + 5]) >> 5)
                guard length > 7 else {
                    position += 1
                    continue
                }
                guard position + length <= raw.count else { break } // packet not complete yet
                packets.append((position + 7, length - 7))
                position += length
            }
        }
        defer { pending = Data(pending.dropFirst(position)) }
        guard let largest = packets.map(\.length).max() else { return }

        // Copy all complete packets into one buffer for the decoder.
        let compressed = AVAudioCompressedBuffer(
            format: aacFormat,
            packetCapacity: AVAudioPacketCount(packets.count),
            maximumPacketSize: largest
        )
        guard let descriptions = compressed.packetDescriptions else { return }
        var offset = 0
        pending.withUnsafeBytes { raw in
            for (i, packet) in packets.enumerated() {
                compressed.data.advanced(by: offset)
                    .copyMemory(from: raw.baseAddress!.advanced(by: packet.start), byteCount: packet.length)
                descriptions[i] = AudioStreamPacketDescription(
                    mStartOffset: Int64(offset),
                    mVariableFramesInPacket: 0,
                    mDataByteSize: UInt32(packet.length)
                )
                offset += packet.length
            }
        }
        compressed.packetCount = AVAudioPacketCount(packets.count)
        compressed.byteLength = UInt32(offset)

        if decoder == nil {
            decoder = AVAudioConverter(from: aacFormat, to: format)
        }
        guard let decoder else { return }

        var delivered = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(packets.count * 1024)) else { break }
            var error: NSError?
            let status = decoder.convert(to: output, error: &error) { _, inputStatus in
                if delivered {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                delivered = true
                inputStatus.pointee = .haveData
                return compressed
            }
            if output.frameLength > 0 {
                schedule(output)
            }
            if status != .haveData { break }
        }
    }

    // MARK: - Playback

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        measureSound(buffer)

        // The output follows the computer: while nothing is audible there, it pauses. Then iOS
        // shows "paused" and the next press on the AirPods sends "play" instead of another "pause".
        if isComputerAudible {
            if isPaused { resumeOutput() }
        } else if state == .playing && !isPaused {
            pauseOutput()
        }
        guard !isPaused else { return }

        // Too much buffered: skip this block so the delay stays small.
        guard buffered < maxBuffer else { return }

        // Buffer ran empty (e.g. dead spot): pause briefly and collect a new buffer.
        if player.isPlaying && buffered == 0 {
            player.pause()
        }

        let frameCount = buffer.frameLength
        buffered += frameCount
        let currentGeneration = generation
        let currentEpoch = outputEpoch
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration, self.outputEpoch == currentEpoch else { return }
                self.buffered -= min(self.buffered, frameCount)
            }
        }

        if !player.isPlaying && buffered >= startBuffer {
            player.play()
            state = .playing
            retries = 0
        }
    }

    private func pauseOutput() {
        logger.notice("Output paused: nothing audible")
        isPaused = true
        outputEpoch += 1
        player.stop() // drops the buffered silence, so the sound returns without delay
        buffered = 0
        engine.pause()
        updateNowPlaying()
    }

    // The player starts again in schedule() as soon as enough audio is buffered.
    private func resumeOutput() {
        logger.notice("Output resumed")
        isPaused = false
        try? engine.start()
        updateNowPlaying()
    }

    @objc private func outputChanged() {
        DispatchQueue.main.async { [self] in
            restartOutput()
        }
    }

    private func restartOutput() {
        guard isActive, !isPaused else { return }
        try? engine.start()
        if state == .playing {
            player.play()
        }
    }

    // MARK: - Headphones and interruptions

    @objc private func routeChanged(_ notification: Notification) {
        let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        guard value.flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable else { return }
        // AirPods or headphones are gone: don't continue over the iPhone speaker.
        DispatchQueue.main.async { [self] in
            guard isActive else { return }
            if isComputerAudible {
                sendMediaKey(.play)
            }
            stop()
        }
    }

    @objc private func interrupted(_ notification: Notification) {
        let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard value.flatMap(AVAudioSession.InterruptionType.init) == .ended else { return }
        DispatchQueue.main.async { [self] in
            try? AVAudioSession.sharedInstance().setActive(true)
            restartOutput()
        }
    }

    // MARK: - Remote control (AirPods, lock screen, CarPlay)

    // Play and pause work like the play/pause button in the app: they press the media key
    // on the computer. That key toggles. So "pause" only presses it while something is audible,
    // and "play" only while it is silent. That way, e.g. taking out an AirPod never starts playback.
    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            self.remotePause()
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            self.remotePlay()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            if self.isPaused || !self.isComputerAudible {
                self.remotePlay()
            } else {
                self.remotePause()
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            self.sendMediaKey(.next)
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            self.sendMediaKey(.previous)
            return .success
        }
        setRemoteCommandsEnabled(false)
    }

    private func remotePause() {
        if isComputerAudible {
            sendMediaKey(.play)
        }
        // Right after the key press, audio is still on its way. Don't count it as "audible".
        lastSoundAt = nil
        ignoreSoundUntil = Date().addingTimeInterval(1.5)
        if state == .playing && !isPaused {
            pauseOutput()
        }
    }

    private func remotePlay() {
        if !isComputerAudible {
            sendMediaKey(.play)
        }
        // Assume sound is coming. If it doesn't, the output pauses again after a few seconds.
        lastSoundAt = Date()
        ignoreSoundUntil = .distantPast
        // Resume right away: this also keeps the app running in the background.
        if isPaused {
            resumeOutput()
        }
    }

    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand] {
            command.isEnabled = enabled
        }
    }

    private func sendMediaKey(_ key: MediaKey) {
        guard let api = lastAPI else { return }
        Task {
            _ = try? await api.press(key)
        }
    }

    // MARK: - Is the computer playing something?

    private var isComputerAudible: Bool {
        guard let lastSoundAt else { return false }
        return Date().timeIntervalSince(lastSoundAt) < silenceAfter
    }

    private func measureSound(_ buffer: AVAudioPCMBuffer) {
        guard Date() >= ignoreSoundUntil, let channels = buffer.floatChannelData else { return }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[channel], 1, &channelPeak, vDSP_Length(buffer.frameLength))
            peak = max(peak, channelPeak)
        }
        if peak > soundThreshold {
            if !isComputerAudible {
                logger.notice("Sound detected, peak \(peak, privacy: .public)")
            }
            lastSoundAt = Date()
        }
    }

    // MARK: - Now Playing (lock screen, Control Center, CarPlay)

    private static let artwork: MPMediaItemArtwork? = UIImage(named: "NowPlaying").map { image in
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func updateNowPlaying() {
        // Shown to the user (German)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: computerName.isEmpty ? "Rechner" : computerName,
            MPMediaItemPropertyArtist: "HeimAudio · Live-Ton",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
        ]
        if let artwork = Self.artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func endNowPlaying() {
        setRemoteCommandsEnabled(false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
