import SwiftUI
import CoreBluetooth

struct StoppedOrPausedView: View {
    
    @EnvironmentObject
    var device: WalkingPad

    var body: some View {
        VStack {
            WorkoutStateView()
            HStack {
                Button(action: {
                    self.device.start()
                }) {
                    Text("Start")
                }
            }
        }
    }
}
