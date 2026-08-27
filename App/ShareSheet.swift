import SwiftUI
import UIKit

/// A file that has been written and is ready to share.
///
/// `Identifiable` so `.sheet(item:)` presents it: the share sheet has to be
/// shown *after* the encode finishes, and `ShareLink` needs its item up front,
/// which is the wrong way round for a file that does not exist until the user
/// picks a format.
struct ExportedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// `UIActivityViewController`, so the exported file can go to Photos, Files,
/// AirDrop or anywhere else the system offers.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
