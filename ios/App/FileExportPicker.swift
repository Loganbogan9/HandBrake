/* This file is part of HandBrake. Licensed under GPL-2.0-or-later. */

import SwiftUI
import UIKit

/// Let Files copy an encoded video without loading its contents into Swift memory.
struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onCompletion: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompletion: () -> Void

        init(onCompletion: @escaping () -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onCompletion()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCompletion()
        }
    }
}

struct ExportSelection: Identifiable {
    let id = UUID()
    let url: URL
}
