/* This file is part of HandBrake. Licensed under GPL-2.0-or-later. */

import Foundation

enum MediaFormatting {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Unknown" }
        let total = Int(seconds.rounded(.down))
        if total >= 3_600 {
            return String(format: "%d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Estimating remaining time…" }
        return "About \(duration(seconds)) remaining"
    }
}
