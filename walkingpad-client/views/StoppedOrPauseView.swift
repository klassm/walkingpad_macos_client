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
                    self.walkingPadService.command()?.start()
                }) {
                    Text("Start")
                }
            }
        }
    }
}
