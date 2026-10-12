/* This file is part of HandBrake. Licensed under GPL-2.0-or-later. */

import SwiftUI

struct QueueView: View {
    @ObservedObject var model: HandBrakeModel

    var body: some View {
        List {
            if model.jobs.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "list.bullet.rectangle",
                                       description: Text("Import a video and add an encoding job from Source."))
            }
            if let warning = model.thermalWarning {
                Label(warning, systemImage: "thermometer.high").foregroundStyle(.orange)
            }
            ForEach(model.jobs) { job in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(job.name).font(.headline)
                        Spacer()
                        Text(statusName(job.status)).font(.caption).foregroundStyle(.secondary)
                    }
                    if job.status == .encoding || job.status == .paused || job.status == .scanning {
                        ProgressView(value: min(max(job.progress, 0), 1))
                        HStack {
                            Text(job.progress.formatted(.percent.precision(.fractionLength(1))))
                            Spacer()
                            if job.fps > 0 { Text(String(format: "%.1f fps", job.fps)) }
                        }
                        .font(.caption).monospacedDigit()
                        if let seconds = job.etaSeconds {
                            Text(MediaFormatting.remaining(Double(seconds))).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            if job.status == .encoding {
                                Button("Pause", systemImage: "pause.fill") { model.pause() }
                            } else if job.status == .paused {
                                Button("Resume", systemImage: "play.fill") { model.resume() }
                            }
                            Spacer()
                            Button("Cancel", systemImage: "xmark", role: .destructive) { model.cancel() }
                        }
                        .buttonStyle(.bordered)
                    }
                    if let error = job.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if job.status == .failed || job.status == .cancelled || job.status == .interrupted {
                        Button("Restart from beginning", systemImage: "arrow.clockwise") {
                            model.retryJob(job.id)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isActive && job.status == .interrupted)
                    }
                }
                .padding(.vertical, 4)
                .swipeActions {
                    if job.status != .encoding && job.status != .paused && job.status != .scanning && job.status != .completed {
                        Button("Remove", role: .destructive) { model.removeJob(job.id) }
                    }
                }
            }
            if !model.jobs.isEmpty {
                Text(model.statusMessage).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Start queue", systemImage: "play.fill") { model.startQueue() }
                    .disabled(model.isActive || model.isScanning || !model.jobs.contains(where: { $0.status == .pending }))
            }
        }
    }

    private func statusName(_ status: JobStatus) -> String {
        switch status {
        case .pending: return "Waiting"
        case .scanning: return "Scanning"
        case .encoding: return "Encoding"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }
}
