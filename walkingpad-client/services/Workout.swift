import SwiftUI
import Foundation

public typealias OnChangeCallback = (_ change: Change) -> Void

struct WorkoutState {
    var steps: Int
    var distance: Int
    var walkingSeconds: Int
}

class Workout: ObservableObject {
    private let storage: WorkoutStoring

    @Published
    public var steps: Int = 0
    
    @Published
    public var distance: Int = 0
    
    @Published
    public var walkingSeconds: Int = 0
    
    public var lastUpdateTime: Date = Date()
    
    var lastSaveTime: Date = .distantPast
    
    public var onChangeCallback: OnChangeCallback =  {_ in }
    
    init(storage: WorkoutStoring = FileSystem()) {
        self.storage = storage
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
        // by the guard below without ever being persisted. Count the diffs
        // that arrived with this final status first, then persist.
        // Requires a real previous status: with oldState == nil the device
        // counter is unknown history (and may still hold the steps the app
        // just restored from disk), so its absolute value must never be added.
        if self.steps > 0, let oldState, oldState.speed != newState.speed, newState.speed == 0 {
            if stepDiff > 0 { self.steps += stepDiff }
            if distanceDiff > 0 { self.distance += distanceDiff }
            if walkingTimeDiff > 0 { self.walkingSeconds += walkingTimeDiff }
            if stepDiff > 0 || distanceDiff > 0 || walkingTimeDiff > 0 {
                self.lastUpdateTime = newState.time
            }
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

        // One entry per calendar day. Every entry is a cumulative snapshot of
        // that day's counters, so the highest-steps entry of a day is its
        // final total. Collapsing every day (not just the current one) also
        // rewrites stale duplicate pairs from older versions: the midnight
        // rollover used to append an identical twin of the day's last save
        // because the old dedup only applied to "today". Zero-step legacy
        // entries are dropped.
        var bestPerDay: [Date: WorkoutSaveData] = [:]
        for entry in loadAll() where entry.steps > 0 {
            let day = Calendar.current.startOfDay(for: entry.date)
            if let existing = bestPerDay[day], existing.steps >= entry.steps {
                continue
            }
            bestPerDay[day] = entry
        }
        // Never regress the numbers: keep whichever of the in-memory state
        // and the best already-persisted entry for the same day is higher.
        if self.steps > 0 {
            let day = Calendar.current.startOfDay(for: workoutData.date)
            if let existing = bestPerDay[day], existing.steps > workoutData.steps {
                // keep the persisted one
            } else {
                bestPerDay[day] = workoutData
            }
        }
        let newData = bestPerDay.values.sorted { $0.date > $1.date }

        let jsonEncoder = JSONEncoder()
        do {
            let json = try jsonEncoder.encode(WorkoutsSaveData(workouts: newData))
            storage.save(filename: "workouts.json", data: json)
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
            let optionalData = storage.load(filename: "workouts.json")
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
