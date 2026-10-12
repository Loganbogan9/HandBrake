/* This file is part of HandBrake. Licensed under GPL-2.0-or-later. */

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: HandBrakeModel

    var body: some View {
        TabView {
            NavigationStack {
                SourceView(model: model)
                    .navigationTitle("HandBrake")
            }
            .tabItem { Label("Source", systemImage: "film") }

            NavigationStack {
                QueueView(model: model)
                    .navigationTitle("Queue")
            }
            .tabItem { Label("Queue", systemImage: "list.bullet.rectangle") }
            .badge(model.jobs.filter { $0.status == .pending }.count)

            NavigationStack {
                OutputsView(model: model)
                    .navigationTitle("Outputs")
            }
            .tabItem { Label("Outputs", systemImage: "folder") }
        }
        .alert("HandBrake", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct SourceView: View {
    @ObservedObject var model: HandBrakeModel
    @State private var showsImporter = false

    private var title: SourceTitle? {
        model.titles.first { $0.id == model.selectedTitleID }
    }

    var body: some View {
        Form {
            Section("Source") {
                Button { showsImporter = true } label: {
                    Label("Import video from Files", systemImage: "doc.badge.plus")
                }
                .disabled(!model.isReady || model.isScanning || model.isActive)

                if model.isScanning {
                    HStack { ProgressView(); Text("Scanning source with HandBrake…") }
                    Button("Cancel scan", role: .destructive) { model.cancel() }
                }
                if !model.titles.isEmpty {
                    Picker("Video title", selection: Binding(
                        get: { model.selectedTitleID },
                        set: { if let id = $0 { model.selectTitle(id) } }
                    )) {
                        ForEach(model.titles) { title in
                            Text("\(title.name) — \(MediaFormatting.duration(title.duration))")
                                .tag(Optional(title.id))
                        }
                    }
                    if let title {
                        LabeledContent("Dimensions", value: "\(title.width) × \(title.height)")
                        LabeledContent("Frame rate", value: String(format: "%.3f fps", title.frameRate))
                        LabeledContent("Duration", value: MediaFormatting.duration(title.duration))
                        LabeledContent("Chapters", value: String(title.chapters))
                    }
                }
                Text(model.statusMessage)
                    .font(.footnote).foregroundStyle(.secondary)
                if let warning = model.thermalWarning {
                    Label(warning, systemImage: "thermometer.high")
                        .foregroundStyle(.orange)
                }
            }

            if let title {
                PresetSection(model: model)
                VideoSection(model: model, title: title)
                AudioSection(model: model, title: title)
                AdditionalSettingsSection(model: model, title: title)

                Section {
                    Button { model.enqueue() } label: {
                        Label("Add to queue", systemImage: "plus.circle")
                    }
                    .disabled(!canEnqueue)
                    Button {
                        let previousJobCount = model.jobs.count
                        model.enqueue()
                        if model.jobs.count > previousJobCount { model.startQueue() }
                    } label: {
                        Label("Encode now", systemImage: "play.fill")
                    }
                    .disabled(!canEnqueue || model.isActive)
                } footer: {
                    Text("Keep the app open while encoding. Entering the background interrupts the job; you can restart it from Queue when you return.")
                }
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.movie, .video, .data]) { result in
            switch result {
            case .success(let url): model.importSource(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
    }

    private var canEnqueue: Bool {
        model.isReady && !model.isScanning && title != nil && !model.settings.videoEncoder.isEmpty
            && !model.settings.audioEncoder.isEmpty
            && model.presets.contains(where: { $0.id == model.selectedPresetID })
    }
}

private struct PresetSection: View {
    @ObservedObject var model: HandBrakeModel

    var body: some View {
        Section("Preset") {
            Picker("Preset base", selection: Binding(
                get: { model.selectedPresetID },
                set: { model.applyPreset($0) }
            )) {
                ForEach(model.presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            Button("Apply selected preset") { model.applyPreset(model.selectedPresetID) }
                .disabled(model.selectedPresetID.isEmpty)
        } footer: {
            Text("The preset supplies additional HandBrake options. Review the controls below; they override the preset for each job.")
        }
    }
}

private struct VideoSection: View {
    @ObservedObject var model: HandBrakeModel
    let title: SourceTitle

    private var encoders: [EncoderCapability] {
        guard let container = model.capabilities.containers.first(where: { $0.id == model.settings.container }) else { return [] }
        return model.capabilities.videoEncoders.filter { $0.muxers & container.muxer != 0 }
    }

    private var encoder: EncoderCapability? {
        encoders.first { $0.id == model.settings.videoEncoder }
    }

    var body: some View {
        Section("Video") {
            Picker("Container", selection: Binding(
                get: { model.settings.container },
                set: { container in
                    model.settings.container = container
                    if !encoders.contains(where: { $0.id == model.settings.videoEncoder }) {
                        model.settings.videoEncoder = ""
                        model.statusMessage = "Choose a video encoder compatible with this container."
                    }
                    if let muxer = model.capabilities.containers.first(where: { $0.id == container })?.muxer {
                        let audio = model.capabilities.audioEncoders.filter { $0.muxers & muxer != 0 }
                        if !audio.contains(where: { $0.id == model.settings.audioEncoder }) {
                            model.settings.audioEncoder = ""
                            model.statusMessage = "Choose compatible video and audio encoders before adding a job."
                        }
                    }
                }
            )) {
                ForEach(model.capabilities.containers) { container in
                    Text(container.name).tag(container.id)
                }
            }
            Picker("Encoder", selection: Binding(
                get: { model.settings.videoEncoder },
                set: { selectEncoder($0) }
            )) {
                Text("Choose encoder").tag("")
                ForEach(encoders) { encoder in Text(encoder.name).tag(encoder.id) }
            }
            Picker("Rate control", selection: $model.settings.qualityMode) {
                if encoder?.qualitySupported == true || encoder == nil {
                    Text("Constant quality").tag(QualityMode.constantQuality)
                }
                if encoder?.bitrateSupported == true || encoder == nil {
                    Text("Average bitrate").tag(QualityMode.averageBitrate)
                }
            }
            .disabled(encoder == nil)
            if model.settings.qualityMode == .constantQuality, let encoder,
               encoder.qualitySupported {
                LabeledContent("Quality", value: String(format: "%.1f", model.settings.quality))
                if encoder.qualityMax != encoder.qualityMin {
                    Slider(value: $model.settings.quality,
                           in: min(encoder.qualityMin, encoder.qualityMax)...max(encoder.qualityMin, encoder.qualityMax),
                           step: 0.5)
                        .accessibilityLabel("Encoder quality")
                }
                Text("Quality uses the selected encoder's native scale.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if encoder?.bitrateSupported == true {
                IntegerSetting(title: "Video bitrate (kbps)", value: $model.settings.bitrate)
            }
            IntegerSetting(title: "Maximum width", value: $model.settings.width)
            IntegerSetting(title: "Maximum height", value: $model.settings.height)
            Text("Use even dimensions from 32 to 8192. HandBrake preserves the source aspect ratio and avoids upscaling.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Frame rate", selection: $model.settings.frameRate) {
                Text("Same as source (\(String(format: "%.3f", title.frameRate)) fps)").tag(0.0)
                ForEach([5.0, 10.0, 12.0, 15.0, 20.0, 23.976, 24.0, 25.0, 29.97, 30.0,
                         48.0, 50.0, 59.94, 60.0, 72.0, 75.0, 90.0, 100.0, 120.0], id: \.self) { rate in
                    Text("\(rate.formatted()) fps").tag(rate)
                }
            }
            Toggle("VideoToolbox decoding", isOn: $model.settings.hardwareDecode)
        }
    }

    private func selectEncoder(_ id: String) {
        if id.isEmpty { model.settings.videoEncoder = ""; return }
        guard let encoder = encoders.first(where: { $0.id == id }) else { return }
        model.settings.videoEncoder = id
        model.settings.quality = encoder.qualityDefault
        if !encoder.qualitySupported { model.settings.qualityMode = .averageBitrate }
        else if !encoder.bitrateSupported { model.settings.qualityMode = .constantQuality }
    }
}

private struct AudioSection: View {
    @ObservedObject var model: HandBrakeModel
    let title: SourceTitle

    private var encoders: [EncoderCapability] {
        guard let container = model.capabilities.containers.first(where: { $0.id == model.settings.container }) else { return [] }
        return model.capabilities.audioEncoders.filter { $0.muxers & container.muxer != 0 }
    }

    var body: some View {
        Section("Audio") {
            if title.audio.isEmpty {
                Text("No audio tracks found").foregroundStyle(.secondary)
            } else {
                ForEach(title.audio) { track in
                    Toggle(isOn: Binding(
                        get: { model.settings.audioTracks.contains(track.id) },
                        set: { selected in
                            model.settings.audioTracks.removeAll { $0 == track.id }
                            if selected { model.settings.audioTracks.append(track.id) }
                        }
                    )) {
                        VStack(alignment: .leading) {
                            Text(track.name)
                            Text("\(track.language) · \(track.codec)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Picker("Audio encoder", selection: $model.settings.audioEncoder) {
                Text("Choose encoder").tag("")
                ForEach(encoders) { encoder in Text(encoder.name).tag(encoder.id) }
            }
            IntegerSetting(title: "Audio bitrate (kbps)", value: $model.settings.audioBitrate)
                .disabled(title.audio.isEmpty || model.settings.audioTracks.isEmpty)
        }
    }
}

private struct AdditionalSettingsSection: View {
    @ObservedObject var model: HandBrakeModel
    let title: SourceTitle

    var body: some View {
        Section("Additional settings") {
            Toggle("Chapter markers", isOn: $model.settings.chapterMarkers)
            Toggle("Deinterlace (Bwdif)", isOn: $model.settings.deinterlace)
            if !title.subtitles.isEmpty {
                Picker("Subtitle track", selection: $model.settings.subtitleTrack) {
                    Text("None").tag(Optional<Int>.none)
                    ForEach(title.subtitles) { track in
                        Text("\(track.name) · \(track.language)").tag(Optional(track.id))
                    }
                }
            }
        }
    }
}

private struct IntegerSetting: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: $value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
                .accessibilityLabel(title)
        }
    }
}
