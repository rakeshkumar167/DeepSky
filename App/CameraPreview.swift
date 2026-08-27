import SwiftUI
import AVFoundation

/// The live camera feed, backed by the same `AVCaptureSession` that takes the
/// photographs.
///
/// It matters that this is the capture session rather than a second one: the
/// preview then shows the frame at the ISO, shutter, focus and white balance
/// the session will actually shoot with. A separate preview session would run
/// its own auto-exposure and show a brighter, sharper picture than any frame
/// the app is capable of producing — which for a focusing aid is worse than
/// showing nothing.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        // Fill the screen: this is a viewfinder, not a contact sheet, and
        // letterboxing a night sky reads as a bug.
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        /// Safe by construction: `layerClass` above guarantees the type.
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        /// Rotation is applied here rather than once at creation because
        /// `layoutSubviews` is the callback that actually fires when the
        /// device turns. Setting it only in `makeUIView` leaves the preview
        /// sideways the moment the phone is rotated.
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let orientation = window?.windowScene?.interfaceOrientation,
                  let connection = previewLayer.connection else { return }

            // Angles are relative to the sensor's native landscape-left
            // orientation, which is why portrait is 90 rather than 0.
            let angle: CGFloat
            switch orientation {
            case .portrait: angle = 90
            case .portraitUpsideDown: angle = 270
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }
}
