import SwiftUI
import CoreBluetooth

func distanceTextFor(_ meters: Int) -> String {
    if (meters < 10000) {
        return "\(meters) m"
    }
    return String(format: "%.00f km", Double(meters) / 1000)
}


func stepsTextFor(_ steps: Int) -> String {
    return String(steps)
}

func printTime(_ seconds: Int) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .positional

    return formatter.string(from: TimeInterval(seconds)) ?? ""
    
}


struct WorkoutStateView: View {
    @EnvironmentObject
    var device: WalkingPad
    @EnvironmentObject
    var workout: Workout

    var body: some View {
        VStack {
            Text(printTime(workout.walkingSeconds))
            Text("\(workout.steps) Steps")
            Text("\(distanceTextFor(workout.distance))")
        }
    }
}
