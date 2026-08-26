import SwiftUI

struct RootView: View {
    /// Night mode is app-wide state, not a per-screen toggle: once dark
    /// adaptation is lost anywhere it is lost everywhere.
    @AppStorage("nightMode") private var nightMode = true

    var body: some View {
        TabView {
            Tab("Camera", systemImage: "camera.aperture") {
                CameraScreen(nightMode: $nightMode)
            }
            Tab("Sessions", systemImage: "square.stack.3d.down.right") {
                SessionsScreen(nightMode: nightMode)
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsScreen(nightMode: $nightMode)
            }
        }
        .tint(DS.accent(nightMode))
        .preferredColorScheme(.dark)
    }
}
