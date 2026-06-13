
import SwiftUI

struct WaitingForTreadmillView: View {
    @EnvironmentObject var workout: Workout

    var body: some View {
        VStack {
            Spacer()
            if workout.steps > 0 {
                VStack(spacing: 4) {
                    Text("\(formatTime(workout.walkingSeconds))")
                    Text("\(workout.steps) Steps")
                    Text("\(distanceTextFor(workout.distance))")
                }
                Spacer().frame(height: 16)
            }
            HStack {
                ProgressView("Waiting for treadmill...")
            }
            Spacer()
        }
    }
}

struct SearchingForDeviceView_Previews: PreviewProvider {
    static var previews: some View {
        WaitingForTreadmillView()
    }
}
