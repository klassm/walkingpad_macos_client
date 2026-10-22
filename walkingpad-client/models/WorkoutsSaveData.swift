import Foundation

struct WorkoutSaveData: Codable {
    var steps: Int
    var distance: Int
    var walkingSeconds: Int
    var date: Date

    private enum CodingKeys: String, CodingKey {
        case steps, distance, walkingSeconds, date
    }

    init(steps: Int, distance: Int, walkingSeconds: Int, date: Date) {
        self.steps = steps
        self.distance = distance
        self.walkingSeconds = walkingSeconds
        self.date = date
    }

    // Writes ISO dates, reads both: legacy JSONEncoder epoch seconds
    // (timeIntervalSinceReferenceDate, e.g. 814281103.157693) and string dates.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.steps = try container.decode(Int.self, forKey: .steps)
        self.distance = try container.decode(Int.self, forKey: .distance)
        self.walkingSeconds = try container.decode(Int.self, forKey: .walkingSeconds)

        if let seconds = try? container.decode(Double.self, forKey: .date) {
            self.date = Date(timeIntervalSinceReferenceDate: seconds)
        } else if let dateString = try? container.decode(String.self, forKey: .date) {
            guard let date = Self.parse(dateString: dateString) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unrecognized workout date \"\(dateString)\""
                ))
            }
            self.date = date
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Workout date is neither a number nor a string"
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(steps, forKey: .steps)
        try container.encode(distance, forKey: .distance)
        try container.encode(walkingSeconds, forKey: .walkingSeconds)
        try container.encode(Self.isoDateFormatterWithSeconds.string(from: date), forKey: .date)
    }

    private static let isoDateFormatterWithSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDateFormatter = ISO8601DateFormatter()

    private static let dayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(dateString: String) -> Date? {
        isoDateFormatterWithSeconds.date(from: dateString)
            ?? isoDateFormatter.date(from: dateString)
            ?? dayDateFormatter.date(from: dateString)
    }
}

struct WorkoutsSaveData: Codable {
    var workouts: [WorkoutSaveData]
}
