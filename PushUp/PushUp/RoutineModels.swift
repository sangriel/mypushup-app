import Foundation
import SwiftData

struct PushupProgram: Decodable {
    let program: [RoutineWeek]
}

struct RoutineWeek: Decodable, Identifiable, Hashable {
    let week: Int
    let days: [RoutineDay]

    var id: Int { week }
}

struct RoutineDay: Decodable, Identifiable, Hashable {
    let day: Int
    let restSeconds: Int
    let ranges: [String: RoutineSets]

    var id: Int { day }

    enum CodingKeys: String, CodingKey {
        case day
        case restSeconds = "rest_seconds"
        case ranges
    }
}

struct RoutineSets: Decodable, Hashable {
    let set1: SetTarget
    let set2: SetTarget
    let set3: SetTarget
    let set4: SetTarget
    let set5: SetTarget

    var targets: [SetTarget] {
        [set1, set2, set3, set4, set5]
    }
}

enum SetTarget: Decodable, Hashable {
    case fixed(Int)
    case minimum(Int)

    var displayText: String {
        switch self {
        case .fixed(let value):
            "\(value)"
        case .minimum(let value):
            "\(value)+"
        }
    }

    var minimumReps: Int {
        switch self {
        case .fixed(let value), .minimum(let value):
            value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Int.self) {
            self = .fixed(value)
            return
        }

        let rawValue = try container.decode(String.self)
        if rawValue.hasSuffix("+"),
           let value = Int(rawValue.dropLast()) {
            self = .minimum(value)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported set target: \(rawValue)"
        )
    }
}

enum RoutineLoader {
    static func load() throws -> [RoutineWeek] {
        guard let url = Bundle.main.url(forResource: "data", withExtension: "json") else {
            throw RoutineLoadingError.missingResource
        }

        let data = try Data(contentsOf: url)
        let program = try JSONDecoder().decode(PushupProgram.self, from: data)
        return program.program.sorted { $0.week < $1.week }
    }
}

enum RoutineLoadingError: LocalizedError {
    case missingResource

    var errorDescription: String? {
        switch self {
        case .missingResource:
            "data.json was not found in the app bundle."
        }
    }
}

@Model
final class AppState {
    @Attribute(.unique) var id: String
    var selectedRangeKey: String?
    var currentWeek: Int
    var currentDay: Int
    var startedAt: Date

    init(
        id: String = "default",
        selectedRangeKey: String? = nil,
        currentWeek: Int = 1,
        currentDay: Int = 1,
        startedAt: Date = .now
    ) {
        self.id = id
        self.selectedRangeKey = selectedRangeKey
        self.currentWeek = currentWeek
        self.currentDay = currentDay
        self.startedAt = startedAt
    }
}

@Model
final class WorkoutCompletion {
    var id: UUID
    var week: Int
    var day: Int
    var rangeKey: String
    var targetRepsCSV: String
    var actualRepsCSV: String
    var completedAt: Date

    init(
        id: UUID = UUID(),
        week: Int,
        day: Int,
        rangeKey: String,
        targetRepsCSV: String,
        actualRepsCSV: String,
        completedAt: Date = .now
    ) {
        self.id = id
        self.week = week
        self.day = day
        self.rangeKey = rangeKey
        self.targetRepsCSV = targetRepsCSV
        self.actualRepsCSV = actualRepsCSV
        self.completedAt = completedAt
    }
}

extension Array where Element == RoutineWeek {
    func session(week: Int, day: Int) -> RoutineSession? {
        guard let routineWeek = first(where: { $0.week == week }),
              let routineDay = routineWeek.days.first(where: { $0.day == day }) else {
            return nil
        }

        return RoutineSession(week: routineWeek.week, day: routineDay)
    }

    func firstSession() -> RoutineSession? {
        sorted { $0.week < $1.week }
            .compactMap { week in
                week.days.sorted { $0.day < $1.day }.first.map {
                    RoutineSession(week: week.week, day: $0)
                }
            }
            .first
    }

    func nextSession(after current: RoutineSession) -> RoutineSession? {
        let sessions = sorted { $0.week < $1.week }
            .flatMap { week in
                week.days.sorted { $0.day < $1.day }.map {
                    RoutineSession(week: week.week, day: $0)
                }
            }

        guard let index = sessions.firstIndex(where: { $0.week == current.week && $0.day.day == current.day.day }),
              sessions.indices.contains(index + 1) else {
            return nil
        }

        return sessions[index + 1]
    }
}

struct RoutineSession: Hashable {
    let week: Int
    let day: RoutineDay
}

extension Dictionary where Key == String, Value == RoutineSets {
    var orderedRangeKeys: [String] {
        keys.sorted { lhs, rhs in
            rangeSortValue(lhs) < rangeSortValue(rhs)
        }
    }

    private func rangeSortValue(_ key: String) -> Int {
        if key.hasPrefix("<") {
            return Int(key.dropFirst()) ?? 0
        }

        if key.hasPrefix(">") {
            return (Int(key.dropFirst()) ?? 0) + 10_000
        }

        if let first = key.split(separator: "-").first,
           let value = Int(first) {
            return value
        }

        return Int.max
    }
}
