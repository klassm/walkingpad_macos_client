import XCTest
@testable import walkingpad_client

// Workout persistence semantics: one cumulative entry per calendar day,
// no duplicate pairs (the midnight rollover used to re-append the last
// save), no zero-shadow entries, and multi-session days aggregate.

final class InMemoryWorkoutStorage: WorkoutStoring {
    var files: [String: Data] = [:]
    func save(filename: String, data: Data) { files[filename] = data }
    func load(filename: String) -> Data? { files[filename] }
}

final class WorkoutTests: XCTestCase {
    private func makeWorkout(_ storage: InMemoryWorkoutStorage) -> Workout {
        Workout(storage: storage)
    }

    private func state(
        steps: Int,
        speed: Int,
        seconds: Int? = nil,
        distanceMeters: Int? = nil,
        time: Date = Date(),
        statusType: StatusType = .currentStatus
    ) -> DeviceState {
        DeviceState(
            time: time,
            walkingTimeSeconds: seconds ?? steps,
            speed: speed,
            steps: steps,
            distance: distanceMeters ?? steps,
            deviceName: "test",
            statusType: statusType
        )
    }

    /// Read workouts.json the way the app does (tolerant decode included).
    private func storedEntries(_ storage: InMemoryWorkoutStorage) throws -> [WorkoutSaveData] {
        let data = try XCTUnwrap(storage.files["workouts.json"])
        return try JSONDecoder().decode(WorkoutsSaveData.self, from: data).workouts
    }

    private func seedFile(_ storage: InMemoryWorkoutStorage, entries: [WorkoutSaveData]) throws {
        storage.files["workouts.json"] = try JSONEncoder().encode(WorkoutsSaveData(workouts: entries))
    }

    private func minutesFromMidnightToday(_ minutes: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.minute = minutes
        return Calendar.current.date(from: components)!
    }

    /// Two walks on one day (device counters reset between them) must end up
    /// as one cumulative day entry, not the last session only.
    func testTwoSessionsAggregateIntoOneDayEntry() throws {
        let storage = InMemoryWorkoutStorage()
        let workout = makeWorkout(storage)

        // Session 1: walk to 3000 device steps ...
        workout.update(nil, state(steps: 3000, speed: 18, seconds: 1800, distanceMeters: 2100))
        XCTAssertEqual(workout.steps, 3000)
        // ... then the treadmill stops and reports the final block of steps.
        workout.update(
            state(steps: 3000, speed: 18, seconds: 1800, distanceMeters: 2100),
            state(steps: 3500, speed: 0, seconds: 2100, distanceMeters: 2450)
        )
        // The final diff must be counted before the walk-end save.
        XCTAssertEqual(workout.steps, 3500)

        // Session 2: reconnect, counters reset to 0 and rise again. The
        // absolute value of the first reconnect status is deliberately not
        // taken over (unknown history), but everything after must add up.
        workout.update(nil, state(steps: 10, speed: 15, seconds: 20, distanceMeters: 10))
        XCTAssertEqual(workout.steps, 3500)
        workout.update(
            state(steps: 10, speed: 15, seconds: 20, distanceMeters: 10),
            state(steps: 110, speed: 15, seconds: 120, distanceMeters: 120)
        )
        XCTAssertEqual(workout.steps, 3600)
        // ... session 2 also ends with a final status before the speed drops.
        workout.update(
            state(steps: 110, speed: 15, seconds: 120, distanceMeters: 120),
            state(steps: 160, speed: 0, seconds: 180, distanceMeters: 160)
        )
        XCTAssertEqual(workout.steps, 3650) // 3500 + 100 + final 50

        let entries = try storedEntries(storage)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].steps, 3650)
    }

    /// The midnight rollover (resetIfDateChanged) saved the previous day's
    /// state while "today" was already the new day; the old save() deduped
    /// only isDateInToday entries and therefore appended an identical twin
    /// of the day's last save. An app that runs across midnight with the
    /// previous day's state in memory must keep exactly one entry for it.
    func testWalkAcrossMidnightProducesOneEntryPerDay() throws {
        let storage = InMemoryWorkoutStorage()
        let justAfterMidnight = minutesFromMidnightToday(5)
        let lateYesterday = Calendar.current.date(byAdding: .minute, value: -16, to: justAfterMidnight)!

        // Yesterday's walk already persisted its final state ...
        try seedFile(storage, entries: [
            WorkoutSaveData(steps: 5200, distance: 4000, walkingSeconds: 3200, date: lateYesterday),
        ])
        // ... and the app was never restarted, so it still holds it in memory.
        let workout = makeWorkout(storage)
        workout.steps = 5200
        workout.distance = 4000
        workout.walkingSeconds = 3200
        workout.lastUpdateTime = lateYesterday

        // First treadmill status of the new day: rollover save for yesterday,
        // counters reset, the new day's session is processed normally.
        workout.update(
            state(steps: 0, speed: 0, seconds: 0, distanceMeters: 0, time: justAfterMidnight),
            state(steps: 300, speed: 15, seconds: 60, distanceMeters: 300, time: minutesFromMidnightToday(6))
        )
        XCTAssertEqual(workout.steps, 300)
        // ... and ends with a final status before the speed drops.
        workout.update(
            state(steps: 300, speed: 15, seconds: 60, distanceMeters: 300, time: minutesFromMidnightToday(6)),
            state(steps: 350, speed: 0, seconds: 100, distanceMeters: 350, time: minutesFromMidnightToday(10))
        )
        XCTAssertEqual(workout.steps, 350)

        let entries = try storedEntries(storage)
        let yesterdayEntries = entries.filter {
            Calendar.current.isDate($0.date, inSameDayAs: lateYesterday)
        }
        XCTAssertEqual(yesterdayEntries.count, 1, "rollover must not append a duplicate")
        XCTAssertEqual(yesterdayEntries[0].steps, 5200)
        XCTAssertTrue(entries.contains { $0.steps == 350 }) // today's session counted after the reset
    }

    /// A file written by older versions (duplicate pairs plus a trailing
    /// zero-shadow entry) must be collapsed to one entry per day on the
    /// next save, keeping the highest-steps snapshot.
    func testSaveCollapsesStaleDuplicateDays() throws {
        let storage = InMemoryWorkoutStorage()
        let now = Date()
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        try seedFile(storage, entries: [
            WorkoutSaveData(steps: 19815, distance: 14500, walkingSeconds: 12112, date: now),
            WorkoutSaveData(steps: 19815, distance: 14500, walkingSeconds: 12112, date: now),
            WorkoutSaveData(steps: 5751, distance: 4200, walkingSeconds: 3422, date: threeDaysAgo),
            WorkoutSaveData(steps: 5751, distance: 4200, walkingSeconds: 3422, date: threeDaysAgo),
            WorkoutSaveData(steps: 0, distance: 0, walkingSeconds: 0, date: now),
        ])
        let workout = makeWorkout(storage) // load() restores today's 19815

        workout.update(nil, state(steps: 10, speed: 15, seconds: 20))
        workout.update(
            state(steps: 10, speed: 15, seconds: 20),
            state(steps: 20, speed: 15, seconds: 40)
        )

        let entries = try storedEntries(storage)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map { Calendar.current.startOfDay(for: $0.date) }).count, 2)
        // Today: loaded 19815 + 10 + 10; no regression, no duplicate pair.
        XCTAssertTrue(entries.contains { $0.steps == 19825 })
        XCTAssertTrue(entries.contains { $0.steps == 5751 })
    }

    /// Restarting the app while the treadmill still reports its session
    /// counter must not double-count: load() restores the persisted 800 and
    /// the first status (oldState == nil, speed 0, device steps 800) used to
    /// take the walk-end branch (nil speed != 0) and add the counter again.
    func testRestartWithUnchangedDeviceCounterDoesNotDoubleCount() throws {
        let storage = InMemoryWorkoutStorage()
        try seedFile(storage, entries: [
            WorkoutSaveData(steps: 800, distance: 600, walkingSeconds: 500, date: Date()),
        ])
        let workout = makeWorkout(storage)
        XCTAssertEqual(workout.steps, 800)

        // First status after restart: no previous state, treadmill idle with
        // its counter still at the walked value.
        workout.update(nil, state(steps: 800, speed: 0, seconds: 500, distanceMeters: 600))
        XCTAssertEqual(workout.steps, 800, "first status after restart must not re-add the device counter")

        // Walking again continues from the restored total.
        workout.update(
            state(steps: 800, speed: 0, seconds: 500, distanceMeters: 600),
            state(steps: 900, speed: 15, seconds: 600, distanceMeters: 700)
        )
        XCTAssertEqual(workout.steps, 900)
    }

    /// A lower in-memory state (e.g. zero-shadow snapshot after reconnects)
    /// must never overwrite the best already-persisted entry of that day.
    func testSaveNeverRegressesTheDay() throws {
        let storage = InMemoryWorkoutStorage()
        try seedFile(storage, entries: [
            WorkoutSaveData(steps: 9000, distance: 6600, walkingSeconds: 5500, date: Date()),
        ])
        let workout = makeWorkout(storage)

        workout.update(nil, state(steps: 10, speed: 15, seconds: 10))
        workout.steps = 100 // emulate a partial state that would regress
        workout.save()

        let entries = try storedEntries(storage)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].steps, 9000)
    }
}
