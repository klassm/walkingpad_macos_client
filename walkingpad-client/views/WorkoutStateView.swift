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

func formatTime(_ seconds: Int) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .positional

    return formatter.string(from: TimeInterval(seconds)) ?? ""
    
}


struct WorkoutStateView: View {
    @EnvironmentObject
    var workout: Workout
    
    @EnvironmentObject
    var walkingPadService: WalkingPadService

    var body: some View {
        let statusSeconds = walkingPadService.lastStatus()?.walkingTimeSeconds ?? 0
        VStack {
            Text("\(formatTime(workout.walkingSeconds)) (\(formatTime(statusSeconds)))")
            Text("\(workout.steps) Steps")
            Text("\(distanceTextFor(workout.distance))")
        }
    }
}
