import SwiftUI
import Foundation

public typealias OnChangeCallback = (_ change: Change) -> Void

struct WorkoutState {
    var steps: Int
    var distance: Int
    var walkingSeconds: Int
}

class Workout: ObservableObject {
    @Published
    public var steps: Int = 0
    
    @Published
    public var distance: Int = 0
    
    @Published
    public var walkingSeconds: Int = 0
    
    public var lastUpdateTime: Date = Date()
    
    private var lastSaveTime: Date = .distantPast
    
    public var onChangeCallback: OnChangeCallback =  {_ in }
    
    init() {
        self.load()
    }
    
    public func resetIfDateChanged() {
        let now = Date()
        if now.get(.day) != self.lastUpdateTime.get(.day) && self.steps > 0 {
            // Persist the previous day's final numbers before zeroing the
            // counters, otherwise a day that ended without a save is lost.
            self.save()
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

        // A walk that ends by disconnecting (speed drops to 0, device counters
        // reset) produces a negative stepDiff and would otherwise be skipped
        // by the guard below without ever being persisted.
        if self.steps > 0, oldState?.speed != newState.speed, newState.speed == 0 {
            save()
            return
        }
        if ((self.steps > 0 && oldState == nil) || stepDiff < 0 || distanceDiff < 0) {
            return
        }
        let speedChanged = oldState != nil && oldState?.speed != newState.speed
        
        if (stepDiff != 0 || distanceDiff != 0) {
            NSLog("adding steps=%d distance=%d", stepDiff, distanceDiff)
        }
        
        if (self.steps > 0 && newState.statusType == .currentStatus) {
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
        
        // Persist after the counters are updated so the saved entry always
        // includes the newest numbers. Save immediately whenever the speed
        // changes (e.g. end of a walk) and otherwise at most every 5 minutes
        // so a steady walk is recorded while it is still ongoing.
        if (speedChanged || (self.steps > 0 && Date().timeIntervalSince(self.lastSaveTime) >= 300)) {
            save()
        }
    }
    
    
    public func save() {
        self.lastSaveTime = Date()
        let workoutData = WorkoutSaveData(steps: self.steps, distance: self.distance, walkingSeconds: self.walkingSeconds, date: self.lastUpdateTime)
        // Drop pointless zero-step entries (legacy files contain zero-shadow
        // entries that overwrite real walks downstream).
        let withoutToday = loadAll().filter { $0.steps > 0 && !Calendar.current.isDateInToday($0.date)}
        // Never regress today's numbers: keep whichever of the in-memory state and
        // the best already-persisted entry for today is higher (guards against
        // zero-shadow saves after reconnects/restarts).
        let bestToday = loadAll().filter { Calendar.current.isDateInToday($0.date) }.max { $0.steps < $1.steps }
        let entryToStore = bestToday != nil && bestToday!.steps > workoutData.steps ? bestToday! : workoutData
        let newData = withoutToday + [entryToStore];
        
        let jsonEncoder = JSONEncoder()
        do {
            let json = try jsonEncoder.encode(WorkoutsSaveData(workouts: newData))
            FileSystem().save(filename: "workouts.json", data: json)
        } catch {
            NSLog("could not save workouts.json: %@", String(describing: error))
        }
    }
    
    public func load() {
        if (self.steps > 0) {
            return
        }
        let workouts = loadAll()
        let workout = workouts
            .filter { entry in Calendar.current.isDateInToday(entry.date) }
            .max { $0.steps < $1.steps }
    
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
                return try decodeWorkouts(data, decoder: jsonDecoder).suffix(500)
            }
            return []
        } catch {
            NSLog("Could not load workout data %@", String(describing: error))
            return []
        }
    }
    
    // Tolerant decoding: a single broken entry (or trailing garbage) no longer
    // discards the whole history — broken entries are skipped instead.
    private func decodeWorkouts(_ data: Data, decoder: JSONDecoder) throws -> [WorkoutSaveData] {
        do {
            return try decoder.decode(WorkoutsSaveData.self, from: data).workouts
        } catch {
            NSLog("workouts.json is partially invalid, recovering individual entries")
        }
        guard let topLevel = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = topLevel["workouts"] as? [[String: Any]] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "workouts.json has no workouts array"))
        }
        return entries.compactMap { entry in
            guard let entryData = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? decoder.decode(WorkoutSaveData.self, from: entryData)
        }
    }
    
    public func workoutState() -> WorkoutState {
        return WorkoutState(steps: self.steps, distance: self.distance, walkingSeconds: self.walkingSeconds)
    }
}
