/* This file is part of HandBrake. Licensed under GPL-2.0-or-later. */

import AVFoundation
import AudioToolbox
import CoreMedia
import XCTest
@testable import HandBrakeIOS

/// These tests run the packaged libhb engine, including its reader, filters and muxer.
/// Missing H.264/AAC or software x265 8/10/12-bit support is a test failure.
@MainActor
final class HBEngineTests: XCTestCase {
    private struct Bootstrap: Decodable {
        let capabilities: EngineCapabilities
        let presets: [HandBrakePreset]
    }

    func testScanAndTranscodeH264AAC() async throws {
        let engine = HBEngine()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("handbrake-test-\(UUID().uuidString).mp4")
        defer { stop(engine, removing: output) }

        let bootstrap = try await prepare(engine)
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp4"))
        let titles = try await scan(engine, url: source)
        let title = try XCTUnwrap(titles.first)
        XCTAssertEqual(title.width, 160)
        XCTAssertEqual(title.height, 90)
        XCTAssertEqual(title.duration, 1, accuracy: 0.1)
        XCTAssertEqual(title.frameRate, 24, accuracy: 0.1)
        XCTAssertEqual(title.audio.count, 1)

        let preset = try XCTUnwrap(bootstrap.presets.first)
        let options = try options(for: title, capabilities: bootstrap.capabilities)
        let completion = expectation(description: "Real HandBrake encode completes")
        var encodeError: Error?
        engine.encode(title: title.id, presetJSON: Data(preset.presetJSON.utf8),
                      optionsJSON: try JSONSerialization.data(withJSONObject: options), outputURL: output,
                      progress: { snapshot in
            let progress = snapshot["progress"]?.doubleValue ?? 0
            XCTAssertTrue(progress.isFinite)
            XCTAssertGreaterThanOrEqual(progress, 0)
            XCTAssertLessThanOrEqual(progress, 1)
        }, completion: { error in
            encodeError = error
            completion.fulfill()
        })
        await fulfillment(of: [completion], timeout: 90)
        if let encodeError { throw encodeError }

        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 1_024)
        let asset = AVURLAsset(url: output)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1, accuracy: 0.25)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let size = try await video.load(.naturalSize)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertLessThanOrEqual(size.width, 160)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThanOrEqual(size.height, 90)
        let descriptions = try await video.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_H264)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let audio = try XCTUnwrap(audioTracks.first)
        let audioDescriptions = try await audio.load(.formatDescriptions)
        let audioDescription = try XCTUnwrap(audioDescriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(audioDescription), kAudioFormatMPEG4AAC)
    }

    func testUnavailableEncoderIsRejectedWithoutAnOutput() async throws {
        let engine = HBEngine()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("handbrake-rejection-\(UUID().uuidString).mp4")
        defer { stop(engine, removing: output) }
        let bootstrap = try await prepare(engine)
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp4"))
        let titles = try await scan(engine, url: source)
        let title = try XCTUnwrap(titles.first)
        let preset = try XCTUnwrap(bootstrap.presets.first)
        var settings = try options(for: title, capabilities: bootstrap.capabilities)
        settings["videoEncoder"] = "unavailable_test_encoder"
        let completion = expectation(description: "Unavailable codec rejected")
        var encodeError: Error?
        engine.encode(title: title.id, presetJSON: Data(preset.presetJSON.utf8),
                      optionsJSON: try JSONSerialization.data(withJSONObject: settings), outputURL: output,
                      progress: { _ in }, completion: { error in
            encodeError = error
            completion.fulfill()
        })
        await fulfillment(of: [completion], timeout: 10)
        XCTAssertNotNil(encodeError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testVideoToolboxH264WhenAvailable() async throws {
        try await verifyVideoToolbox(encoderID: "vt_h264", expectedCodec: kCMVideoCodecType_H264)
    }

    func testSoftwareX265EightBit() async throws {
        try await verifySoftwareX265(encoderID: "x265", bitDepth: 8)
    }

    func testSoftwareX265TenBit() async throws {
        try await verifySoftwareX265(encoderID: "x265_10bit", bitDepth: 10)
    }

    func testSoftwareX265TwelveBit() async throws {
        try await verifySoftwareX265(encoderID: "x265_12bit", bitDepth: 12)
    }

    func testDisabledConcreteFDKAACDoesNotFallBack() async throws {
        let engine = HBEngine()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("handbrake-fdk-rejection-\(UUID().uuidString).mp4")
        defer { stop(engine, removing: output) }
        let bootstrap = try await prepare(engine)
        XCTAssertFalse(bootstrap.capabilities.audioEncoders.contains { $0.id == "fdk_aac" },
                       "The reproducible iOS engine profile disables FDK AAC")
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp4"))
        let titles = try await scan(engine, url: source)
        let title = try XCTUnwrap(titles.first)
        let preset = try XCTUnwrap(bootstrap.presets.first)
        var settings = try options(for: title, capabilities: bootstrap.capabilities)
        settings["audioEncoder"] = "fdk_aac"
        let completion = expectation(description: "Disabled concrete FDK AAC encoder rejected")
        var encodeError: Error?
        engine.encode(title: title.id, presetJSON: Data(preset.presetJSON.utf8),
                      optionsJSON: try JSONSerialization.data(withJSONObject: settings), outputURL: output,
                      progress: { _ in }, completion: { error in
            encodeError = error
            completion.fulfill()
        })
        await fulfillment(of: [completion], timeout: 10)
        XCTAssertNotNil(encodeError, "A known disabled encoder must not resolve to another AAC encoder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testVideoToolboxHEVCWhenAvailable() async throws {
        try await verifyVideoToolbox(encoderID: "vt_h265", expectedCodec: kCMVideoCodecType_HEVC)
    }

    func testVideoToolboxIsNotAdvertisedBeforeIOS174() async throws {
        let engine = HBEngine()
        defer { stop(engine) }
        let bootstrap = try await prepare(engine)
        if #available(iOS 17.4, *) { return }
        XCTAssertFalse(bootstrap.capabilities.videoEncoders.contains { $0.id.hasPrefix("vt_") },
                       "HandBrake's supported iOS VideoToolbox path requires iOS 17.4")
    }

    func testFastPresetUsesAvailableConcreteIdentifiers() async throws {
        let engine = HBEngine()
        defer { stop(engine) }
        let bootstrap = try await prepare(engine)
        let preset = try XCTUnwrap(bootstrap.presets.first { $0.id.hasSuffix("/Fast 1080p30") })
        let values = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(preset.presetJSON.utf8)) as? [String: Any])
        let container = try XCTUnwrap(values["FileFormat"] as? String)
        let video = try XCTUnwrap(values["VideoEncoder"] as? String)
        let audioList = try XCTUnwrap(values["AudioList"] as? [[String: Any]])
        let audio = try XCTUnwrap(audioList.first?["AudioEncoder"] as? String)
        XCTAssertTrue(bootstrap.capabilities.containers.contains { $0.id == container })
        XCTAssertTrue(bootstrap.capabilities.videoEncoders.contains { $0.id == video })
        XCTAssertTrue(bootstrap.capabilities.audioEncoders.contains { $0.id == audio },
                      "Generic AAC preset names must resolve before the Swift editor compares runtime capabilities")
    }

    func testMissingSourceReportsAnError() async throws {
        let engine = HBEngine()
        defer { stop(engine) }
        _ = try await prepare(engine)
        let completion = expectation(description: "Missing source rejected")
        var scanError: Error?
        var scanData: Data?
        engine.scan(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                    titleIndex: 0, hardwareDecode: false, progress: { _ in }, completion: { data, error in
            scanData = data
            scanError = error
            completion.fulfill()
        })
        await fulfillment(of: [completion], timeout: 10)
        XCTAssertNotNil(scanError)
        XCTAssertNil(scanData)
    }

    private func prepare(_ engine: HBEngine) async throws -> Bootstrap {
        let completion = expectation(description: "Native engine prepared")
        var response: Data?
        var operationError: Error?
        engine.prepare { data, error in
            response = data
            operationError = error
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 20)
        if let operationError { throw operationError }
        return try JSONDecoder().decode(Bootstrap.self, from: XCTUnwrap(response))
    }

    private func verifySoftwareX265(encoderID: String, bitDepth: Int) async throws {
        let engine = HBEngine()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("handbrake-\(encoderID)-\(UUID().uuidString).mp4")
        defer { stop(engine, removing: output) }
        let bootstrap = try await prepare(engine)
        let encoder = try XCTUnwrap(bootstrap.capabilities.videoEncoders.first { $0.id == encoderID },
                                   "The packaged x265 multilib must expose \(encoderID)")
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp4"))
        let titles = try await scan(engine, url: source)
        let title = try XCTUnwrap(titles.first)
        let preset = try XCTUnwrap(bootstrap.presets.first)
        var settings = try options(for: title, capabilities: bootstrap.capabilities)
        settings["videoEncoder"] = encoder.id
        settings["quality"] = encoder.qualityDefault
        let completion = expectation(description: "Actual software \(encoderID) encode completes")
        var encodeError: Error?
        engine.encode(title: title.id, presetJSON: Data(preset.presetJSON.utf8),
                      optionsJSON: try JSONSerialization.data(withJSONObject: settings), outputURL: output,
                      progress: { _ in }, completion: { error in
            encodeError = error
            completion.fulfill()
        })
        await fulfillment(of: [completion], timeout: 120)
        if let encodeError { throw encodeError }

        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 1_024)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1, accuracy: 0.25)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let descriptions = try await video.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_HEVC)
        let atoms = try XCTUnwrap(CMFormatDescriptionGetExtension(description,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Data])
        let configuration = try XCTUnwrap(atoms["hvcC"])
        // ISO/IEC 14496-15 HEVCDecoderConfigurationRecord carries the actual
        // encoded luma/chroma bit depths, so an 8-bit fallback cannot pass.
        XCTAssertGreaterThanOrEqual(configuration.count, 23)
        guard configuration.count >= 23 else { return }
        XCTAssertEqual(configuration[0], 1)
        XCTAssertEqual(Int(configuration[17] & 7) + 8, bitDepth)
        XCTAssertEqual(Int(configuration[18] & 7) + 8, bitDepth)
        // iOS playback support for 12-bit HEVC is independent of software
        // encoding. Inspect the muxed track without requiring a decoder.
    }

    private func verifyVideoToolbox(encoderID: String, expectedCodec: FourCharCode) async throws {
        let engine = HBEngine()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("handbrake-\(encoderID)-\(UUID().uuidString).mp4")
        defer { stop(engine, removing: output) }
        let bootstrap = try await prepare(engine)
        guard let encoder = bootstrap.capabilities.videoEncoders.first(where: { $0.id == encoderID }) else {
            throw XCTSkip("\(encoderID) is unavailable according to the native engine on this device or simulator")
        }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp4"))
        let titles = try await scan(engine, url: source)
        let title = try XCTUnwrap(titles.first)
        let preset = try XCTUnwrap(bootstrap.presets.first)
        var settings = try options(for: title, capabilities: bootstrap.capabilities)
        settings["videoEncoder"] = encoder.id
        settings["quality"] = encoder.qualityDefault
        let completion = expectation(description: "Actual \(encoderID) encode completes")
        var encodeError: Error?
        engine.encode(title: title.id, presetJSON: Data(preset.presetJSON.utf8),
                      optionsJSON: try JSONSerialization.data(withJSONObject: settings), outputURL: output,
                      progress: { _ in }, completion: { error in
            encodeError = error
            completion.fulfill()
        })
        await fulfillment(of: [completion], timeout: 90)
        if let encodeError { throw encodeError }
        let asset = AVURLAsset(url: output)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1, accuracy: 0.25)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let descriptions = try await video.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), expectedCodec,
                       "The engine must use the explicitly requested codec")
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let audioDescriptions = try await audio.load(.formatDescriptions)
        let audioDescription = try XCTUnwrap(audioDescriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(audioDescription), kAudioFormatMPEG4AAC)
    }

    private func scan(_ engine: HBEngine, url: URL) async throws -> [SourceTitle] {
        let completion = expectation(description: "Native source scan completes")
        var response: Data?
        var operationError: Error?
        engine.scan(url: url, titleIndex: 0, hardwareDecode: false, progress: { _ in }, completion: { data, error in
            response = data
            operationError = error
            completion.fulfill()
        })
        await fulfillment(of: [completion], timeout: 30)
        if let operationError { throw operationError }
        return try JSONDecoder().decode([SourceTitle].self, from: XCTUnwrap(response))
    }

    private func options(for title: SourceTitle, capabilities: EngineCapabilities) throws -> [String: Any] {
        let container = try XCTUnwrap(capabilities.containers.first { $0.id == "av_mp4" })
        let compatibleVideo = capabilities.videoEncoders.filter { $0.muxers & container.muxer != 0 }
        let video = try XCTUnwrap(compatibleVideo.first { $0.id == "x264" }
                                  ?? compatibleVideo.first { $0.id == "vt_h264" })
        let compatibleAudio = capabilities.audioEncoders.filter { $0.muxers & container.muxer != 0 }
        let audio = try XCTUnwrap(compatibleAudio.first { $0.id == "ca_aac" }
                                  ?? compatibleAudio.first { $0.id == "av_aac" })
        return ["videoEncoder": video.id, "container": container.id, "qualityMode": "averageBitrate",
                "quality": video.qualityDefault, "bitrate": 350, "width": 160, "height": 90,
                "frameRate": 0, "audioEncoder": audio.id, "audioBitrate": 96,
                "audioTracks": title.audio.map(\.id), "subtitleTrack": NSNull(),
                "chapterMarkers": false, "deinterlace": false, "hardwareDecode": false]
    }

    private func stop(_ engine: HBEngine, removing output: URL? = nil) {
        engine.cancel()
        engine.shutdown {
            if let output { try? FileManager.default.removeItem(at: output) }
        }
    }
}
