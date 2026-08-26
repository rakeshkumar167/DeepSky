import SwiftUI

struct SettingsScreen: View {
    @Binding var nightMode: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $nightMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Night mode").foregroundStyle(DS.primaryText(nightMode))
                            Text("Red-only interface. Preserves dark adaptation, which takes 20–30 minutes to rebuild after white light.")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.secondaryText(nightMode))
                        }
                    }
                    .tint(DS.accent(nightMode))
                } header: {
                    Text("Display")
                }
                .listRowBackground(DS.surface)

                Section {
                    NavigationLink { ProbeView() } label: {
                        Label("Capability probe", systemImage: "camera.metering.matrix")
                    }
                } header: {
                    Text("Hardware")
                } footer: {
                    Text("Reads the real exposure, ISO and RAW limits of this device. This one is wired to the actual camera — everything else in this build is a preview.")
                }
                .listRowBackground(DS.surface)

                Section {
                    row("Version", "0.1 preview")
                    row("Capture pipeline", "Not wired")
                    row("Sensor exposure ceiling", "1.0s (measured)")
                } header: {
                    Text("About")
                }
                .listRowBackground(DS.surface)
            }
            .scrollContentBackground(.hidden)
            .background(DS.background)
            .navigationTitle("Settings")
        }
        .tint(DS.accent(nightMode))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(DS.secondaryText(nightMode))
            Spacer()
            Text(v).readout(15, weight: .medium).foregroundStyle(DS.primaryText(nightMode))
        }
    }
}
