import SwiftUI
import CoreBluetooth

func distanceTextFor(_ meters: Double) -> String {
    if (meters < 10000) {
        let rounded = Int(meters.rounded())
        return "\(rounded) m"
    }
    return String(format: "%.00f km", meters / 1000.0)
}


func stepsTextFor(_ steps: Double) -> String {
    return String(Int(steps.rounded()))
}


struct WorkoutStateView: View {
    @EnvironmentObject
    var device: WalkingPad
    @EnvironmentObject
    var workout: Workout

    var body: some View {
        let steps = workout.steps
        let meters = workout.distanceMeters
    
        VStack {
            Text("\(stepsTextFor(steps)) Steps")
            Text("\(distanceTextFor(meters))")
        }
    }
}
