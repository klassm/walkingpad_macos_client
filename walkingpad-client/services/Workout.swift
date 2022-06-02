import SwiftUI
import Foundation

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
    
    public func update(_ oldState: DeviceState?, _ newState: DeviceState) {
        self.resetIfDateChanged()

        let stepDiff = newState.steps - (oldState?.steps ?? 0)
        let distanceDiff = newState.distance - (oldState?.distance ?? 0)
        let walkingTimeDiff = newState.walkingTimeSeconds - ( oldState?.walkingTimeSeconds ?? 0)
        
        if (self.steps > 0 && oldState == nil) {
            return
        }
        if (oldState != nil && oldState?.speed != newState.speed) {
            save()
        }
        
        print("adding steps=\(stepDiff) distance=\(distanceDiff)")
        
        if (steps > 0 && newState.statusType == .currentStatus) {
            let change = Change(
                oldTime: self.lastUpdateTime,
                newTime: newState.time,
                stepsDiff: stepDiff,
                oldSpeed: oldState?.speed ?? 0,
                newSpeed: newState.speed
            )
            self.onChangeCallback(change)
        }
        
        self.steps = self.steps + stepDiff
        self.distance = self.distance + distanceDiff
        self.walkingSeconds = self.walkingSeconds + walkingTimeDiff
        self.lastUpdateTime = newState.time
        
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
