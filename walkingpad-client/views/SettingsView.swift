import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
            } footer: {
                Text("Starts the WalkingPad client automatically when you log in.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 340, height: 120)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .onChange(of: launchAtLogin) { _, newValue in
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
                NSLog("Failed to toggle launch at login: %@", String(describing: error))
            }
        }
    }
}
