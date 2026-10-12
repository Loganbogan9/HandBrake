/* This file is part of HandBrake. Licensed under GPL-2.0-or-later. */

import AVKit
import SwiftUI

struct OutputsView: View {
    @ObservedObject var model: HandBrakeModel
    @State private var exportSelection: ExportSelection?
    @State private var deleteSelection: UUID?

    private var outputs: [QueueJob] { model.jobs.filter { $0.status == .completed } }

    var body: some View {
        List {
            if outputs.isEmpty {
                ContentUnavailableView("No encoded videos", systemImage: "folder",
                                       description: Text("Finished videos appear here and in HandBrake's folder in Files."))
            }
            ForEach(outputs) { job in
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.outputURL.lastPathComponent).font(.headline)
                    HStack {
                        NavigationLink { OutputPlayer(url: job.outputURL) } label: {
                            Label("Play", systemImage: "play.rectangle")
                        }
                        Spacer()
                        Button { exportSelection = ExportSelection(url: job.outputURL) } label: {
                            Label("Export to Files", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
                .swipeActions {
                    Button("Delete video", role: .destructive) { deleteSelection = job.id }
                }
            }
        }
        .sheet(item: $exportSelection) { selection in
            FileExportPicker(url: selection.url) { exportSelection = nil }
        }
        .confirmationDialog("Delete this encoded video from HandBrake?", isPresented: Binding(
            get: { deleteSelection != nil },
            set: { if !$0 { deleteSelection = nil } }
        ), titleVisibility: .visible) {
            Button("Delete video", role: .destructive) {
                if let id = deleteSelection { model.deleteOutput(id) }
                deleteSelection = nil
            }
        } message: {
            Text("Copies you have already exported remain in Files.")
        }
    }
}

private struct OutputPlayer: View {
    let url: URL
    @State private var player: AVPlayer
    @State private var playbackError: String?

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        Group {
            if let playbackError {
                ContentUnavailableView("Preview unavailable", systemImage: "play.slash",
                                       description: Text(playbackError))
            } else {
                VideoPlayer(player: player)
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                if try await AVURLAsset(url: url).load(.isPlayable) {
                    if !Task.isCancelled { player.play() }
                } else {
                    playbackError = "Apple's player cannot preview this video format. Export the video to Files to use a compatible player."
                }
            } catch { playbackError = error.localizedDescription }
        }
        .onDisappear { player.pause() }
    }
}
