import SwiftUI
import UIKit

/// Thin SwiftUI wrapper around `UIActivityViewController`, for sharing a file
/// (e.g. an exported ride) through the system share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
