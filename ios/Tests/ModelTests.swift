/* This file is part of HandBrake. Licensed under GPL-2.0-or-later. */

import XCTest
@testable import HandBrakeIOS

final class ModelTests: XCTestCase {
    private let title = SourceTitle(id: 1, name: "Fixture", duration: 10, width: 1920, height: 1080,
                                    frameRate: 24, audio: [AudioTrack(id: 0, name: "English", language: "eng", codec: "aac")],
                                    subtitles: [SubtitleTrack(id: 0, name: "English", language: "eng", codec: "text")], chapters: 2)
    private let capabilities = EngineCapabilities(
        videoEncoders: [EncoderCapability(id: "x264", name: "H.264", muxers: 1, qualityMin: 0,
                                          qualityMax: 51, qualityDefault: 22, qualitySupported: true, bitrateSupported: true)],
        audioEncoders: [EncoderCapability(id: "ca_aac", name: "AAC", muxers: 1, qualityMin: 0,
                                          qualityMax: 0, qualityDefault: 0, qualitySupported: false, bitrateSupported: true)],
        containers: [ContainerCapability(id: "av_mp4", name: "MP4", muxer: 1),
                     ContainerCapability(id: "av_webm", name: "WebM", muxer: 2)])

    private var settings: EncodingSettings {
        var result = EncodingSettings()
        result.videoEncoder = "x264"
        result.audioEncoder = "ca_aac"
        result.container = "av_mp4"
        result.audioTracks = [0]
        return result
    }

    func testValidSettingsWithAndWithoutAudio() throws {
        var value = settings
        XCTAssertNoThrow(try value.validate(title: title, capabilities: capabilities))
        value.audioTracks = []
        value.subtitleTrack = 0
        XCTAssertNoThrow(try value.validate(title: title, capabilities: capabilities))
    }

    func testUnavailableAndContainerIncompatibleEncodersAreRejected() {
        var value = settings
        value.videoEncoder = "missing"
        XCTAssertThrowsError(try value.validate(title: title, capabilities: capabilities))
        XCTAssertEqual(value.videoEncoder, "missing", "Validation must preserve the explicitly requested encoder")
        value.videoEncoder = "x264"
        value.container = "av_webm"
        XCTAssertThrowsError(try value.validate(title: title, capabilities: capabilities))
    }

    func testResolutionQualityAndFrameRateBoundaries() {
        for width in [0, 1, 30, 1919, 8194] {
            var value = settings; value.width = width
            XCTAssertThrowsError(try value.validate(title: title, capabilities: capabilities), "width \(width)")
        }
        for quality in [-1.0, 52.0, Double.nan, Double.infinity] {
            var value = settings; value.quality = quality
            XCTAssertThrowsError(try value.validate(title: title, capabilities: capabilities))
        }
        for rate in [-1.0, 0.5, 241.0, Double.nan, Double.infinity] {
            var value = settings; value.frameRate = rate
            XCTAssertThrowsError(try value.validate(title: title, capabilities: capabilities))
        }
        for rate in [0.0, 24.0, 120.0] {
            var value = settings; value.frameRate = rate
            XCTAssertNoThrow(try value.validate(title: title, capabilities: capabilities))
        }
    }

    func testTrackSelectionAndBitrateValidation() {
        var value = settings
        value.audioTracks = [0, 0]
        XCTAssertThrowsError(try value.validate(title: title, capabilities: capabilities))
        value.audioTracks = [9]
        XCTAssertThrowsError(try value.validate(title: title, capabilities: capabilities))
        value.audioTracks = [0]
        value.subtitleTrack = 9
        XCTAssertThrowsError(try value.validate(title: title, capabilities: capabilities))
        value.subtitleTrack = nil
        value.audioBitrate = 31
        XCTAssertThrowsError(try value.validate(title: title, capabilities: capabilities))
        value.audioBitrate = 160
        value.qualityMode = .averageBitrate
        value.bitrate = 99
        XCTAssertThrowsError(try value.validate(title: title, capabilities: capabilities))
        value.bitrate = 100
        XCTAssertNoThrow(try value.validate(title: title, capabilities: capabilities))
    }

    func testQueuePersistenceRetainsSourceSettingsAndPartialFileIsolation() throws {
        let source = URL(fileURLWithPath: "/sandbox/Sources/source.mp4")
        let output = URL(fileURLWithPath: "/sandbox/Documents/Outputs/output.mp4")
        var job = QueueJob(id: UUID(), name: "Fixture", sourceURL: source, title: title,
                           presetJSON: "{\"VideoEncoder\":\"x264\"}", settings: settings, outputURL: output)
        job.status = .paused
        job.progress = 0.4
        let recovered = try JSONDecoder().decode([QueueJob].self, from: JSONEncoder().encode([job]))
        let restored = try XCTUnwrap(recovered.first)
        XCTAssertEqual(restored.id, job.id)
        XCTAssertEqual(restored.sourceURL, source)
        XCTAssertEqual(restored.outputURL, output)
        XCTAssertEqual(restored.settings.videoEncoder, "x264")
        XCTAssertEqual(restored.settings.audioTracks, [0])
        XCTAssertEqual(restored.status, .paused)
        XCTAssertTrue(restored.status.isRunning, "Recovery must recognize paused jobs as interrupted work")
        XCTAssertNotEqual(restored.partialURL, restored.outputURL)
        XCTAssertEqual(restored.partialURL.deletingLastPathComponent(), output.deletingLastPathComponent())
        XCTAssertEqual(restored.partialURL.pathExtension, "mp4")
        XCTAssertTrue(restored.partialURL.lastPathComponent.hasPrefix("."))
    }
}
