import SwiftUI
import CoreBluetooth

func getContentView(status: Status) -> some View {
    if (status == .Stopped || status == .Paused) {
        return AnyView(StoppedOrPausedView())
    }
    if (status == .Running || status == .Starting) {
        return AnyView(RunningView())
    }
    return AnyView(WaitingForTreadmillView())
}

struct DeviceView: View {
    @EnvironmentObject
    var device: WalkingPad

    var body: some View {
        getContentView(status: device.status.status)
    }
}
