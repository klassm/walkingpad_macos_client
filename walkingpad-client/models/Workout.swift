import SwiftUI
import Foundation

struct WorkoutSaveData: Codable {
    var steps: Int
    var distance: Int
    var walkingSeconds: Int
    var date: Date
}


struct WorkoutsSaveData: Codable {
    var workouts: [WorkoutSaveData]
}


public struct Change {
    var oldTime: Date
    var newTime: Date
    var stepsDiff: Int
    var oldSpeed: Int
    var newSpeed: Int
}


public typealias OnChangeCallback = (_ change: Change) -> Void

class Workout: ObservableObject {
    @Published
    public var steps: Int = 0
    
    @Published
    public var distance: Int = 0
    
    @Published
    public var walkingSeconds: Int = 0
    
    public var lastUpdateTime: Date = Date()
    
    public var onChangeCallback: OnChangeCallback =  {_ in }
    
    init() {
        self.load()
    }
    
    public func resetIfDateChanged() {
        let now = Date()
        if now.get(.day) != self.lastUpdateTime.get(.day) {
            self.distance = 0
            self.steps = 0
            self.walkingSeconds = 0
        }
    }
    
    public func update(_ oldState: DeviceState, _ newState: DeviceState) {
        self.resetIfDateChanged()

        let stepDiff = newState.steps - oldState.steps
        let distanceDiff = newState.distance - oldState.distance
        
        if (self.steps > 0 && oldState.steps == 0) {
            return
        }
        
        
        print("adding steps=\(stepDiff) distance=\(distanceDiff)")
        
        if (steps > 0 && newState.statusType != .lastStatus) {
            let change = Change(
                oldTime: self.lastUpdateTime,
                newTime: newState.time,
                stepsDiff: stepDiff,
                oldSpeed: oldState.speed,
                newSpeed: newState.speed
            )
            self.onChangeCallback(change)
        }
        
        self.steps = self.steps + stepDiff
        self.distance = self.distance + distanceDiff
        self.walkingSeconds = newState.walkingTimeSeconds
        self.lastUpdateTime = newState.time
        
        if (oldState.speed != newState.speed) {
            save()
        }
    }
    
    
    public func save() {
        let workoutData = WorkoutSaveData(steps: self.steps, distance: self.distance, walkingSeconds: self.walkingSeconds, date: self.lastUpdateTime)
        let withoutToday = loadAll().filter { !Calendar.current.isDateInToday($0.date)}
        let newData = withoutToday + [workoutData];
        
        let jsonEncoder = JSONEncoder()
        do {
            let json = try jsonEncoder.encode(WorkoutsSaveData(workouts: newData))
            FileSystem().save(filename: "workouts.json", data: json)
        } catch {
            print("could not save")
        }
    }
    
    public func load() {
        let workouts = loadAll()
        let workout = workouts.first (where: { entry in Calendar.current.isDateInToday(entry.date) })
    
        if let foundWorkout = workout {
            self.steps = foundWorkout.steps
            self.distance = foundWorkout.distance
            self.walkingSeconds = foundWorkout.walkingSeconds
            self.lastUpdateTime = foundWorkout.date
        }
    }
    
    public func loadAll() -> [WorkoutSaveData] {
        let jsonDecoder = JSONDecoder()
        do {
            let optionalData = FileSystem().load(filename: "workouts.json")
            if let data = optionalData {
                let workoutData = try jsonDecoder.decode(WorkoutsSaveData.self, from: data)
                return workoutData.workouts.suffix(500)
            }
            return []
        } catch {
            print("Could not load workout data \(error)")
            return []
        }
    }
}
