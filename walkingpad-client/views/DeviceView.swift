import SwiftUI
import CoreBluetooth


struct DeviceView: View {
    @EnvironmentObject
    var walkingPadService: WalkingPadService

    var body: some View {
        if (!walkingPadService.isConnected()) {
            return AnyView(WaitingForTreadmillView())
        }
        if (walkingPadService.lastStatus()?.speed ?? 0 == 0) {
            return AnyView(StoppedOrPausedView())
        }
        return AnyView(RunningView())
    }
}
