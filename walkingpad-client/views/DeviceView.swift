import SwiftUI
import CoreBluetooth


struct DeviceView: View {
    @EnvironmentObject
    var device: WalkingPad

    var body: some View {
        if (device.peripheral == nil) {
            return AnyView(WaitingForTreadmillView())
        }
        if (device.status.speed == 0) {
            return AnyView(StoppedOrPausedView())
        }
        return AnyView(RunningView())
    }
}
