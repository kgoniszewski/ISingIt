import Foundation

/// A tempo change at a beat position.
public struct TempoEvent: Codable, Sendable, Equatable {
    public var beat: Double
    /// Quarter notes per minute.
    public var bpm: Double

    public init(beat: Double, bpm: Double) {
        self.beat = beat
        self.bpm = bpm
    }
}

/// Converts between beats and seconds across tempo changes (step changes, no ramps).
public struct TempoMap: Codable, Sendable, Equatable {
    public private(set) var events: [TempoEvent]

    public init(events: [TempoEvent] = [TempoEvent(beat: 0, bpm: 120)]) {
        self.events = TempoMap.cleaned(events)
    }

    public init(bpm: Double) {
        self.init(events: [TempoEvent(beat: 0, bpm: bpm)])
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events = TempoMap.cleaned(try container.decode([TempoEvent].self, forKey: .events))
    }

    private enum CodingKeys: String, CodingKey { case events }

    /// Sorted, deduplicated, positive tempos, always starting at beat 0.
    private static func cleaned(_ events: [TempoEvent]) -> [TempoEvent] {
        var sorted = events.filter { $0.bpm > 0 && $0.bpm.isFinite }.sorted { $0.beat < $1.beat }
        var result: [TempoEvent] = []
        for event in sorted {
            if let last = result.last, abs(last.beat - event.beat) < 1e-9 {
                result[result.count - 1] = event  // later event at the same beat wins
            } else if let last = result.last, last.bpm == event.bpm {
                continue  // redundant
            } else {
                result.append(event)
            }
        }
        if result.isEmpty { result = [TempoEvent(beat: 0, bpm: 120)] }
        // The first tempo mark also covers any pickup before it.
        result[0].beat = 0
        sorted = result
        return sorted
    }

    public mutating func add(_ event: TempoEvent) {
        events = TempoMap.cleaned(events + [event])
    }

    /// Tempo in force at a beat.
    public func bpm(atBeat beat: Double) -> Double {
        events.last(where: { $0.beat <= beat + 1e-9 })?.bpm ?? events[0].bpm
    }

    /// Returns a copy with every tempo multiplied by `factor` (2 = twice as fast).
    public func scaled(by factor: Double) -> TempoMap {
        TempoMap(events: events.map { TempoEvent(beat: $0.beat, bpm: $0.bpm * factor) })
    }

    public func seconds(atBeat beat: Double) -> Double {
        var seconds = 0.0
        for (i, event) in events.enumerated() {
            let segmentEnd = i + 1 < events.count ? events[i + 1].beat : Double.infinity
            if beat <= segmentEnd {
                return seconds + (beat - event.beat) * 60.0 / event.bpm
            }
            seconds += (segmentEnd - event.beat) * 60.0 / event.bpm
        }
        return seconds
    }

    public func beat(atSeconds target: Double) -> Double {
        var seconds = 0.0
        for (i, event) in events.enumerated() {
            let segmentEnd = i + 1 < events.count ? events[i + 1].beat : Double.infinity
            let segmentSeconds = (segmentEnd - event.beat) * 60.0 / event.bpm
            if target <= seconds + segmentSeconds {
                return event.beat + (target - seconds) * event.bpm / 60.0
            }
            seconds += segmentSeconds
        }
        return events.last!.beat
    }
}
