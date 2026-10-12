/* SPDX-License-Identifier: GPL-2.0-or-later */
import AVFoundation
import SwiftUI
import UIKit
#if SWIFT_PACKAGE
import HBEngineBridge
#endif

struct EncoderCapability: Codable, Identifiable {
    let id: String
    let name: String
    let muxers: Int
    let qualityMin: Double
    let qualityMax: Double
    let qualityDefault: Double
    let qualitySupported: Bool
    let bitrateSupported: Bool
}
struct ContainerCapability: Codable, Identifiable {
    let id: String
    let name: String
    let muxer: Int
}
struct EngineCapabilities: Codable {
    var videoEncoders: [EncoderCapability] = []
    var audioEncoders: [EncoderCapability] = []
    var containers: [ContainerCapability] = []
}
struct HandBrakePreset: Codable, Identifiable {
    let id: String
    let name: String
    let presetJSON: String
}
struct AudioTrack: Codable, Identifiable {
    let id: Int
    let name: String
    let language: String
    let codec: String
}
struct SubtitleTrack: Codable, Identifiable {
    let id: Int
    let name: String
    let language: String
    let codec: String
}
struct SourceTitle: Codable, Identifiable {
    let id: Int
    let name: String
    let duration: Double
    let width: Int
    let height: Int
    let frameRate: Double
    let audio: [AudioTrack]
    let subtitles: [SubtitleTrack]
    let chapters: Int
}
enum QualityMode: String, Codable { case constantQuality, averageBitrate }
struct EncodingSettings: Codable {
    var videoEncoder = "x264"
    var container = "av_mp4"
    var qualityMode = QualityMode.constantQuality
    var quality = 22.0
    var bitrate = 6000
    var width = 1920
    var height = 1080
    var frameRate = 0.0
    var audioEncoder = "ca_aac"
    var audioBitrate = 160
    var audioTracks: [Int] = []
    var subtitleTrack: Int?
    var chapterMarkers = true
    var deinterlace = false
    var hardwareDecode = false

    func validate(title: SourceTitle, capabilities: EngineCapabilities) throws {
        guard let mux = capabilities.containers.first(where: { $0.id == container })?.muxer,
              let video = capabilities.videoEncoders.first(where: { $0.id == videoEncoder }),
              let audio = capabilities.audioEncoders.first(where: { $0.id == audioEncoder }),
              video.muxers & mux != 0, audio.muxers & mux != 0 else {
            throw PortError.invalid("Choose available video and audio encoders compatible with this container.")
        }
        guard (32...8192).contains(width), (32...8192).contains(height), width % 2 == 0, height % 2 == 0 else {
            throw PortError.invalid("Maximum dimensions must be even numbers from 32 to 8192.")
        }
        guard frameRate.isFinite, frameRate == 0 || (1...240).contains(frameRate) else {
            throw PortError.invalid("Choose the source frame rate or a supported frame rate from 1 to 240.")
        }
        if qualityMode == .constantQuality {
            guard video.qualitySupported, quality.isFinite,
                  (video.qualityMin...video.qualityMax).contains(quality) else {
                throw PortError.invalid("Constant quality is unavailable or the quality value is out of range for this encoder.")
            }
        } else if !video.bitrateSupported || !(100...200000).contains(bitrate) {
            throw PortError.invalid("This encoder must support bitrate control; video bitrate must be from 100 to 200000 kbps.")
        }
        guard (32...640).contains(audioBitrate), Set(audioTracks).count == audioTracks.count,
              audioTracks.allSatisfy({ id in title.audio.contains { $0.id == id } }),
              subtitleTrack == nil || title.subtitles.contains(where: { $0.id == subtitleTrack }) else {
            throw PortError.invalid("Check audio bitrate and selected tracks.")
        }
    }
}
enum JobStatus: String, Codable {
    case pending, scanning, encoding, paused, completed, cancelled, failed, interrupted
    var isRunning: Bool { self == .scanning || self == .encoding || self == .paused }
}
struct QueueJob: Codable, Identifiable {
    let id: UUID
    let name: String
    var sourceURL: URL
    let title: SourceTitle
    let presetJSON: String
    let settings: EncodingSettings
    var status = JobStatus.pending
    var progress = 0.0
    var fps = 0.0
    var etaSeconds: Int?
    var outputURL: URL
    var error: String?

    var partialURL: URL {
        outputURL.deletingLastPathComponent().appendingPathComponent(".\(id.uuidString).partial.\(outputURL.pathExtension)")
    }
}
enum PortError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
private struct Bootstrap: Decodable { let capabilities: EngineCapabilities; let presets: [HandBrakePreset] }

@MainActor
final class HandBrakeModel: ObservableObject {
    @Published var capabilities = EngineCapabilities()
    @Published var presets: [HandBrakePreset] = []
    @Published var titles: [SourceTitle] = []
    @Published var selectedTitleID: Int?
    @Published var selectedPresetID = ""
    @Published var settings = EncodingSettings()
    @Published var jobs: [QueueJob] = []
    @Published var isScanning = false
    @Published var isReady = false
    @Published var errorMessage: String?
    @Published var statusMessage = "Initializing HandBrake…"
    @Published var thermalWarning: String?
    @Published private var activeJobID: UUID?

    var isActive: Bool { activeJobID != nil }
    private let engine = HBEngine()
    private let storage: URL
    private let sources: URL
    private let outputs: URL
    private let queueFile: URL
    private var sourceURL: URL?
    private var sourceName = ""
    private var queueRunning = false
    private var sceneActive = true
    private var importGeneration = UUID()
    private var interruptionReason: String?
    private var cancelRequested = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var observations: [NSObjectProtocol] = []

    init() {
        let manager = FileManager.default
        let storageURL = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HandBrake", isDirectory: true)
        storage = storageURL
        sources = storageURL.appendingPathComponent("Sources", isDirectory: true)
        outputs = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Outputs", isDirectory: true)
        queueFile = storageURL.appendingPathComponent("queue.json")
        do {
            try manager.createDirectory(at: sources, withIntermediateDirectories: true)
            try manager.createDirectory(at: outputs, withIntermediateDirectories: true)
            var imported = sources
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try imported.setResourceValues(values)
            if manager.fileExists(atPath: queueFile.path) {
                jobs = try JSONDecoder().decode([QueueJob].self, from: Data(contentsOf: queueFile))
                for index in jobs.indices {
                    // Container paths may change after restore/reinstall. Only stored filenames are used.
                    jobs[index].sourceURL = sources.appendingPathComponent(jobs[index].sourceURL.lastPathComponent)
                    jobs[index].outputURL = outputs.appendingPathComponent(jobs[index].outputURL.lastPathComponent)
                    if jobs[index].status.isRunning {
                        jobs[index].status = .interrupted
                        jobs[index].error = "The app closed during encoding. Restart this job from the beginning."
                    }
                    try? manager.removeItem(at: jobs[index].partialURL)
                    if jobs[index].status == .completed && !manager.fileExists(atPath: jobs[index].outputURL.path) {
                        jobs[index].status = .failed; jobs[index].error = "The output file has been moved or removed in Files."
                    }
                }
                persist()
            }
            pruneSources()
        } catch { errorMessage = error.localizedDescription }
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange,
                     UIApplication.didReceiveMemoryWarningNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in self?.resourceStateChanged(notification.name) }
            })
        }
        engine.prepare { [weak self] data, error in
            guard let self else { return }
            do {
                if let error { throw error }
                guard let data else { throw PortError.invalid("HandBrake returned no capabilities.") }
                let bootstrap = try JSONDecoder().decode(Bootstrap.self, from: data)
                self.capabilities = bootstrap.capabilities
                self.presets = bootstrap.presets
                guard !self.capabilities.videoEncoders.isEmpty else { throw PortError.invalid("No video encoders are available in this engine build.") }
                self.isReady = true
                // An explicit initial selection; no requested encoder is silently replaced.
                self.settings.videoEncoder = self.capabilities.videoEncoders.first(where: { $0.id == "vt_h264" })?.id ?? "x264"
                self.settings.audioEncoder = self.capabilities.audioEncoders.first(where: { $0.id == "ca_aac" })?.id ?? "av_aac"
                if let encoder = self.capabilities.videoEncoders.first(where: { $0.id == self.settings.videoEncoder }) {
                    self.settings.quality = encoder.qualityDefault
                    if !encoder.qualitySupported { self.settings.qualityMode = .averageBitrate }
                }
                self.selectedPresetID = self.presets.first(where: { $0.id.hasSuffix("/Fast 1080p30") })?.id ?? self.presets.first?.id ?? ""
                self.statusMessage = "Import a video to scan it with HandBrake."
                self.resourceStateChanged(nil)
            } catch { self.statusMessage = "Engine initialization failed."; self.report(error) }
        }
    }

    func importSource(_ url: URL) {
        guard isReady, !isScanning, !isActive else { return }
        isScanning = true; titles = []; selectedTitleID = nil
        statusMessage = "Copying source into app storage…"
        let generation = UUID(); importGeneration = generation
        let destination = sources.appendingPathComponent("\(UUID().uuidString).\(url.pathExtension.isEmpty ? "video" : url.pathExtension)")
        // File-provider downloads and multi-gigabyte copies never block the UI thread.
        Task {
            do {
                try await Self.copyImportedSource(url, to: destination)
                guard importGeneration == generation, sceneActive else {
                    try? FileManager.default.removeItem(at: destination); isScanning = false; endBackgroundTask(); return
                }
                sourceURL = destination; sourceName = url.deletingPathExtension().lastPathComponent
                pruneSources()
                statusMessage = "Scanning source…"
                engine.scan(url: destination, titleIndex: 0, hardwareDecode: false, progress: { [weak self] snapshot in
                    self?.statusMessage = "Scanning: \(Int((snapshot["progress"]?.doubleValue ?? 0) * 100))%"
                }) { [weak self] data, error in
                    guard let self else { return }
                    self.isScanning = false; self.endBackgroundTask()
                    do {
                        if let error { throw error }
                        guard let data else { throw PortError.invalid("No source information returned.") }
                        self.titles = try JSONDecoder().decode([SourceTitle].self, from: data)
                        if let title = self.titles.max(by: { $0.duration < $1.duration }) { self.selectTitle(title.id) }
                        self.statusMessage = "Scanned \(self.titles.count) video title(s)."
                    } catch {
                        self.statusMessage = "Source scan did not finish."
                        if (error as NSError).code != NSUserCancelledError { self.report(error) }
                    }
                }
            } catch {
                isScanning = false; endBackgroundTask(); try? FileManager.default.removeItem(at: destination)
                report(error); statusMessage = "Import failed."
            }
        }
    }

    private nonisolated static func copyImportedSource(_ source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var copyError: Error?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readableURL in
                do {
                    let values = try readableURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true else { throw PortError.invalid("Import a regular video file from Files.") }
                    let size = Int64(values.fileSize ?? 0)
                    try checkSpace(directory: destination.deletingLastPathComponent(), required: Double(size) + 256 * 1024 * 1024)
                    try FileManager.default.copyItem(at: readableURL, to: destination)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                } catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
        }.value
    }

    func selectTitle(_ id: Int) {
        guard let title = titles.first(where: { $0.id == id }) else { return }
        selectedTitleID = id
        settings.audioTracks = title.audio.first.map { [$0.id] } ?? []
        settings.subtitleTrack = nil
        settings.width = min(8192, max(32, title.width / 2 * 2))
        settings.height = min(8192, max(32, title.height / 2 * 2))
    }

    func applyPreset(_ id: String) {
        guard let preset = presets.first(where: { $0.id == id }),
              let data = preset.presetJSON.data(using: .utf8),
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let video = values["VideoEncoder"] as? String ?? ""
        let container = values["FileFormat"] as? String ?? ""
        let presetAudio = ((values["AudioList"] as? [[String: Any]])?.first)?["AudioEncoder"] as? String
        guard capabilities.videoEncoders.contains(where: { $0.id == video }),
              let mux = capabilities.containers.first(where: { $0.id == container })?.muxer,
              presetAudio == nil || capabilities.audioEncoders.contains(where: { $0.id == presetAudio && $0.muxers & mux != 0 }) else {
            errorMessage = "This preset requests \(video), which is unavailable on this device/build. Select a compatible preset or encoder explicitly."
            return
        }
        selectedPresetID = id; settings.videoEncoder = video; settings.container = container
        settings.qualityMode = (values["VideoQualityType"] as? NSNumber)?.intValue == 2 ? .constantQuality : .averageBitrate
        settings.quality = (values["VideoQualitySlider"] as? NSNumber)?.doubleValue ?? 22
        settings.bitrate = (values["VideoAvgBitrate"] as? NSNumber)?.intValue ?? 6000
        if settings.bitrate < 100 { settings.bitrate = 6000 }
        let title = titles.first { $0.id == selectedTitleID }
        let width = (values["PictureWidth"] as? NSNumber)?.intValue ?? 0
        let height = (values["PictureHeight"] as? NSNumber)?.intValue ?? 0
        settings.width = width > 0 ? width : (title?.width ?? 1920) / 2 * 2
        settings.height = height > 0 ? height : (title?.height ?? 1080) / 2 * 2
        settings.frameRate = Double(values["VideoFramerate"] as? String ?? "") ?? 0
        settings.chapterMarkers = (values["ChapterMarkers"] as? NSNumber)?.boolValue ?? true
        settings.deinterlace = (values["PictureDeinterlaceFilter"] as? String ?? "off") != "off"
        if let audio = (values["AudioList"] as? [[String: Any]])?.first {
            settings.audioEncoder = audio["AudioEncoder"] as? String ?? settings.audioEncoder
            settings.audioBitrate = (audio["AudioBitrate"] as? NSNumber)?.intValue ?? 160
        }
        statusMessage = "Applied \(preset.name). Review settings before adding a job."
    }

    func enqueue() {
        guard isReady, !isScanning, sceneActive, let sourceURL,
              let title = titles.first(where: { $0.id == selectedTitleID }),
              let preset = presets.first(where: { $0.id == selectedPresetID }) else { return }
        do {
            try settings.validate(title: title, capabilities: capabilities)
            let id = UUID()
            let ext = settings.container.hasSuffix("mkv") ? "mkv" : settings.container.hasSuffix("webm") ? "webm" : settings.container.hasSuffix("mov") ? "mov" : "mp4"
            let stem = sourceName.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
            let name = "\(String(stem.prefix(60)))-\(id.uuidString.prefix(8)).\(ext)"
            let job = QueueJob(id: id, name: sourceName, sourceURL: sourceURL, title: title,
                               presetJSON: preset.presetJSON, settings: settings, outputURL: outputs.appendingPathComponent(name))
            try validateSpace(job)
            jobs.append(job); persist(); statusMessage = "Added \(sourceName) to the queue."
        } catch { report(error) }
    }

    func startQueue() {
        guard isReady, !isActive, !isScanning, sceneActive else { return }
        guard ProcessInfo.processInfo.thermalState != .critical else { errorMessage = "Let the device cool before encoding."; return }
        queueRunning = true; runNext()
    }
    private func runNext() {
        guard queueRunning, sceneActive, !isActive,
              let index = jobs.firstIndex(where: { $0.status == .pending }) else {
            if !isActive { queueRunning = false }; return
        }
        let job = jobs[index]
        do {
            try job.settings.validate(title: job.title, capabilities: capabilities)
            try validateSpace(job)
            guard FileManager.default.fileExists(atPath: job.sourceURL.path) else { throw PortError.invalid("The imported source is missing. Import it again.") }
            try? FileManager.default.removeItem(at: job.partialURL)
            activeJobID = job.id; interruptionReason = nil; cancelRequested = false
            jobs[index].status = .scanning; jobs[index].error = nil; jobs[index].progress = 0
            UIApplication.shared.isIdleTimerDisabled = true
            persist(); statusMessage = "Scanning queued source…"
            engine.scan(url: job.sourceURL, titleIndex: job.title.id, hardwareDecode: job.settings.hardwareDecode,
                        progress: { [weak self] snapshot in self?.updateProgress(job.id, snapshot) }) { [weak self] _, error in
                guard let self else { return }
                if let error { self.finish(job.id, error: error); return }
                if let reason = self.interruptionReason { self.finish(job.id, error: PortError.invalid(reason)); return }
                if self.cancelRequested { self.finish(job.id, error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)); return }
                self.beginEncode(job)
            }
        } catch {
            jobs[index].status = .failed; jobs[index].error = error.localizedDescription
            queueRunning = false; persist(); report(error)
        }
    }
    private func beginEncode(_ job: QueueJob) {
        do {
            guard sceneActive, !cancelRequested else { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
            guard ProcessInfo.processInfo.thermalState != .critical else { throw PortError.invalid("Let the device cool before restarting this encoding job.") }
            try validateSpace(job)
            guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
            jobs[index].status = .encoding; persist(); statusMessage = "Encoding \(job.name)…"
            engine.encode(title: job.title.id, presetJSON: Data(job.presetJSON.utf8),
                          optionsJSON: try JSONEncoder().encode(job.settings), outputURL: job.partialURL,
                          progress: { [weak self] snapshot in self?.updateProgress(job.id, snapshot) }) { [weak self] error in
                guard let self else { return }
                if let error { self.finish(job.id, error: error); return }
                Task {
                    do {
                        // AVFoundation probes MP4/MOV output; HandBrake also supports containers AVFoundation cannot read.
                        if job.settings.container.hasSuffix("mp4") || job.settings.container.hasSuffix("mov") {
                            let asset = AVURLAsset(url: job.partialURL)
                            let video = try await asset.loadTracks(withMediaType: .video)
                            let duration = try await asset.load(.duration)
                            guard !video.isEmpty, duration.seconds.isFinite, duration.seconds > 0 else {
                                throw PortError.invalid("The generated output has no playable video stream.")
                            }
                            if !job.settings.audioTracks.isEmpty {
                                let audio = try await asset.loadTracks(withMediaType: .audio)
                                guard !audio.isEmpty else { throw PortError.invalid("The generated output is missing the selected audio stream.") }
                            }
                        }
                        if let reason = self.interruptionReason { throw PortError.invalid(reason) }
                        if self.cancelRequested { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
                        try FileManager.default.moveItem(at: job.partialURL, to: job.outputURL)
                        self.finish(job.id, error: nil)
                    } catch { self.finish(job.id, error: error) }
                }
            }
        } catch { finish(job.id, error: error) }
    }
    private func updateProgress(_ id: UUID, _ snapshot: [String: NSNumber]) {
        guard interruptionReason == nil, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].progress = snapshot["progress"]?.doubleValue ?? 0
        jobs[index].fps = snapshot["fps"]?.doubleValue ?? 0
        let eta = snapshot["etaSeconds"]?.intValue ?? -1
        jobs[index].etaSeconds = eta >= 0 ? eta : nil
        if snapshot["state"]?.intValue == 16 { jobs[index].status = .paused }
        else if snapshot["state"]?.intValue == 8 { jobs[index].status = .encoding }
    }
    private func finish(_ id: UUID, error: Error?) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs[index]
        if let reason = interruptionReason {
            jobs[index].status = .interrupted; jobs[index].error = reason
        } else if cancelRequested {
            jobs[index].status = .cancelled; jobs[index].error = "Encoding was cancelled."
        } else if let error {
            jobs[index].status = (error as NSError).code == NSUserCancelledError ? .cancelled : .failed
            jobs[index].error = error.localizedDescription
        } else {
            jobs[index].status = .completed; jobs[index].progress = 1; jobs[index].error = nil
        }
        if jobs[index].status != .completed { try? FileManager.default.removeItem(at: job.partialURL) }
        jobs[index].etaSeconds = nil
        activeJobID = nil; interruptionReason = nil; cancelRequested = false
        UIApplication.shared.isIdleTimerDisabled = false
        persist(); endBackgroundTask()
        statusMessage = jobs[index].status == .completed ? "Finished \(job.outputURL.lastPathComponent)." : "Job stopped."
        if jobs[index].status == .failed { queueRunning = false; if let error { report(error) } }
        if queueRunning { runNext() }
    }

    func pause() {
        guard let id = activeJobID, let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .encoding else { return }
        engine.pause(); jobs[index].status = .paused; UIApplication.shared.isIdleTimerDisabled = false; persist()
    }
    func resume() {
        guard sceneActive, ProcessInfo.processInfo.thermalState != .critical,
              let id = activeJobID, let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .paused else { return }
        engine.resume(); jobs[index].status = .encoding; UIApplication.shared.isIdleTimerDisabled = true; persist()
    }
    func cancel() {
        queueRunning = false; cancelRequested = true; importGeneration = UUID(); engine.cancel()
        if !isActive && isScanning { statusMessage = "Cancelling source scan…" }
    }
    func retryJob(_ id: UUID) {
        guard activeJobID != id, let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].status.isRunning,
              jobs[index].status != .completed else { return }
        jobs[index].status = .pending; jobs[index].error = nil; jobs[index].progress = 0; persist()
    }
    func removeJob(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.status.isRunning, activeJobID != id else { return }
        // Completed output metadata remains until Delete video, preventing untracked output files.
        if job.status == .completed { return }
        jobs.removeAll { $0.id == id }; persist(); pruneSources()
    }
    func deleteOutput(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.status == .completed else { return }
        do {
            if FileManager.default.fileExists(atPath: job.outputURL.path) { try FileManager.default.removeItem(at: job.outputURL) }
            jobs.removeAll { $0.id == id }; persist(); pruneSources()
        } catch { report(error) }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active { sceneActive = true; resourceStateChanged(nil); return }
        if phase != .background { return }
        sceneActive = false; queueRunning = false
        guard isActive || isScanning else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Stop HandBrake safely") { [weak self] in
            Task { @MainActor in self?.engine.cancel(); self?.endBackgroundTask() }
        }
        if let id = activeJobID, let index = jobs.firstIndex(where: { $0.id == id }) {
            interruptionReason = "Encoding stopped when the app entered the background. Restart this job from the beginning."
            jobs[index].status = .interrupted; jobs[index].error = interruptionReason
        }
        persist(); cancel(); UIApplication.shared.isIdleTimerDisabled = false
        statusMessage = "Stopping work for background suspension…"
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    private func resourceStateChanged(_ notification: Notification.Name?) {
        switch ProcessInfo.processInfo.thermalState {
        case .critical:
            thermalWarning = "Device temperature is critical. Encoding is paused; resume after cooling."
            pause()
        case .serious: thermalWarning = "Device is hot. Encoding may slow down; consider pausing."
        default: thermalWarning = ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power Mode is enabled. Encoding can consume substantial battery." : nil
        }
        if notification == UIApplication.didReceiveMemoryWarningNotification {
            pause(); thermalWarning = "Memory pressure detected. Encoding paused; resume when the device has more memory."
        }
    }
    private func validateSpace(_ job: QueueJob) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: job.sourceURL.path)[.size] as? NSNumber)?.doubleValue ?? 0
        let required: Double
        if job.settings.qualityMode == .averageBitrate {
            required = job.title.duration * Double(job.settings.bitrate + job.settings.audioBitrate * job.settings.audioTracks.count) * 125 * 1.1
        } else { required = size * 2 }
        try Self.checkSpace(directory: outputs, required: required + 256 * 1024 * 1024)
    }
    private nonisolated static func checkSpace(directory: URL, required: Double) throws {
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        guard required.isFinite, required > 0, let capacity, Double(capacity) >= required else {
            throw PortError.invalid("Not enough free space. Keep room for the output plus 256 MB for the engine. Constant-quality jobs reserve twice the source size because final size is unpredictable.")
        }
    }
    private func persist() {
        do { try JSONEncoder().encode(jobs).write(to: queueFile, options: .atomic) }
        catch { report(error); queueRunning = false }
    }
    private func pruneSources() {
        let references = Set(jobs.map { $0.sourceURL.lastPathComponent } + [sourceURL?.lastPathComponent].compactMap { $0 })
        guard let files = try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) else { return }
        for file in files where !references.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
    }
    private func report(_ error: Error) {
        let ns = error as NSError
        errorMessage = [ns.localizedDescription, ns.localizedFailureReason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    deinit { for observation in observations { NotificationCenter.default.removeObserver(observation) } }
}
