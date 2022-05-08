import SwiftUI
import Foundation

struct WorkoutSaveData: Codable {
    var steps: Double
    var meters: Double
    var date: Date
}


struct WorkoutsSaveData: Codable {
    var workouts: [WorkoutSaveData]
}


public struct Change {
    var oldTime: Date
    var newTime: Date
    var steps: Int
    var oldSpeedLevel: Int
    var newSpeedLevel: Int
}


public typealias OnChangeCallback = (_ change: Change) -> Void

class Workout: ObservableObject {
    @Published
    public var steps: Double = 0
    
    @Published
    public var distanceMeters: Double = 0
    
    public var lastUpdateTime: Date = Date()
    
    public var onChangeCallback: OnChangeCallback =  {_ in }
    
    init() {
        self.load()
    }
    
    private func metersFor(seconds: Double, speedKmh: Double) -> Double {
        let speedMs = speedKmh / 3.6
        return speedMs * seconds;
    }
    
    public func resetIfDateChanged() {
        let now = Date()
        if now.get(.day) != self.lastUpdateTime.get(.day) {
            self.distanceMeters = 0
            self.steps = 0
        }
    }
    
    public func update(_ oldState: DeviceState, _ newState: DeviceState) {
        if (oldState.status != .Running && newState.status == .Running) {
            self.resetIfDateChanged()
        }
        if (oldState.status != .Running && newState.status != .Running) {
            return
        }
        
        let seconds = newState.time.timeIntervalSince(oldState.time)
        let meters = self.metersFor(seconds: seconds, speedKmh: oldState.speedKmh())
        let steps = meters * 1.31
        
        print("adding steps \(steps)")
        
        let intSteps = Int(steps)
        if (steps > 0) {
            let change = Change(oldTime: self.lastUpdateTime, newTime: newState.time, steps: intSteps, oldSpeedLevel: oldState.speedLevel, newSpeedLevel: newState.speedLevel)
            self.onChangeCallback(change)
        }
        
        self.steps += steps
        self.distanceMeters += meters
        self.lastUpdateTime = newState.time
        
        if (oldState.status == .Running && newState.status != .Running) {
            save()
        }
    }
    
    
    public func save() {
        
        let workoutData = WorkoutSaveData(steps: self.steps, meters: self.distanceMeters, date: self.lastUpdateTime)
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
            self.distanceMeters = foundWorkout.meters
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
    
    public func testIncStep() {
        print("update")
        self.steps += 1
    }
}
