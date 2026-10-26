import AVFoundation
import Observation
import XeniaCore

/// Plays one audio message at a time, as Messages does: starting another stops the first.
@Observable
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    /// The attachment loaded into the player, playing or paused partway.
    private(set) var currentID: String?
    private(set) var isPlaying = false
    /// A clip asked to play whose file is still downloading or converting. Stopping, or asking
    /// for another, cancels it, so it can't start after its conversation has closed.
    @ObservationIgnored private(set) var pendingID: String?

    @ObservationIgnored private var player: AVAudioPlayer?

    override init() {
        super.init()
        #if os(iOS)
        // A call or Siri pauses the player; so does unplugging headphones, as everywhere on iOS.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        #endif
    }

    /// Where playback is, read by the playing bubble's clock (not observed, so nothing else
    /// redraws as it moves).
    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }

    /// Plays or pauses. False when the file can't be played.
    @discardableResult
    func toggle(_ id: String, file: URL) async -> Bool {
        if currentID == id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                activateSession()
                isPlaying = player.play()
            }
            return true
        }
        stop()
        pendingID = id
        activateSession()
        let started = await Self.startedPlayer(for: file)
        guard pendingID == id else {
            // Stopped, or another clip asked to play, while this one was getting ready.
            started?.stop()
            return true
        }
        pendingID = nil
        guard let player = started else {
            deactivateSession()
            return false
        }
        player.delegate = self
        self.player = player
        currentID = id
        isPlaying = true
        return true
    }

    /// A player already playing the file. Element sends voice messages as Ogg Opus, which Core
    /// Audio decodes but the player opens and then won't play, so those are converted once to a
    /// file it can.
    private static func startedPlayer(for file: URL) async -> AVAudioPlayer? {
        if let player = try? AVAudioPlayer(contentsOf: file), player.play() { return player }
        guard let playable = await convert(file),
              let player = try? AVAudioPlayer(contentsOf: playable), player.play()
        else { return nil }
        return player
    }

    @concurrent
    private static func convert(_ file: URL) async -> URL? {
        let target = file.deletingPathExtension().appendingPathExtension("caf")
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) { return target }
        // Written beside the target and moved into place when complete, so a conversion cut
        // short (the app quit) is never taken for a finished one.
        let partial = file.deletingPathExtension().appendingPathExtension("\(UUID().uuidString).partial.caf")
        guard let source = try? AVAudioFile(forReading: file),
              let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 65_536)
        else { return nil }
        var written: AVAudioFramePosition = 0
        do {
            let output = try AVAudioFile(forWriting: partial, settings: source.processingFormat.settings,
                                         commonFormat: source.processingFormat.commonFormat, interleaved: source.processingFormat.isInterleaved)
            while true {
                do {
                    try source.read(into: buffer)
                } catch {
                    // Reading past the end throws on some formats; what was read plays.
                    break
                }
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            written = output.length
            output.close()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: partial) }
        guard written > 0 else { return nil }
        // Another conversion of the same clip may have finished first; its copy is as good.
        if (try? FileManager.default.moveItem(at: partial, to: target)) == nil,
           !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            return nil
        }
        return target
    }

    /// A clip is about to play once its file is ready.
    func prepare(_ id: String) {
        guard currentID != id else { return }
        stop()
        pendingID = id
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        player?.stop()
        player = nil
        currentID = nil
        pendingID = nil
        isPlaying = false
        deactivateSession()
    }

    /// Stops what's playing if it belongs to these rows: a conversation closing silences itself.
    func stopIfPlaying(in rows: [TimelineRow]) {
        guard let id = currentID ?? pendingID, rows.contains(where: { $0.id == id }) else { return }
        stop()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            // Another clip may have started in the meantime; leave it playing.
            guard let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.stop()
        }
    }

    #if os(iOS)
    @objc nonisolated private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor in self.pause() }
    }

    @objc nonisolated private func routeChanged(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        Task { @MainActor in self.pause() }
    }
    #endif

    private func activateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// An audio file's loudness as bars, for the waveform drawn in its bubble.
enum Waveform {
    private nonisolated(unsafe) static let cache = NSCache<NSString, NSArray>()

    static func cached(_ key: String) -> [Float]? {
        cache.object(forKey: key as NSString) as? [Float]
    }

    /// Peak levels for `count` equal slices of the file, 0 to 1, scaled so quiet speech still
    /// shows. Nil if the file can't be read as audio.
    static func levels(of url: URL, key: String, count: Int) async -> [Float]? {
        if let hit = cached(key) { return hit }
        guard let levels = await read(url, count: count) else { return nil }
        cache.setObject(levels as NSArray, forKey: key as NSString)
        return levels
    }

    @concurrent
    private static func read(_ url: URL, count: Int) async -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0, count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)
        else { return nil }
        // Read in chunks: a song decoded whole would be a hundred megabytes.
        let slice = max(1, Int(file.length) / count)
        var peaks = [Float](repeating: 0, count: count)
        var position = 0
        while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] {
            for frame in 0..<Int(buffer.frameLength) {
                let index = min(count - 1, (position + frame) / slice)
                peaks[index] = max(peaks[index], abs(channel[frame]))
            }
            position += Int(buffer.frameLength)
        }
        let loudest = peaks.max() ?? 0
        guard loudest > 0 else { return peaks }
        return peaks.map { ($0 / loudest).squareRoot() }
    }
}
