import SwiftUI
import CoreBluetooth

struct StoppedOrPausedView: View {
    
    @EnvironmentObject
    var walkingPadService: WalkingPadService

    var body: some View {
        VStack {
            WorkoutStateView()
            HStack {
                Button(action: {
                    NSLog("Start button clicked")
                    self.walkingPadService.command()?.start()
                }) {
                    Text("Start")
                }
            }
        }
    }
}
