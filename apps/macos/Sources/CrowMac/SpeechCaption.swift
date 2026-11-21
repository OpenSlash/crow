import Foundation

/// Subtitle-style reply text. The model writes far faster than speech plays, so
/// while a reply is spoken the panel shows only the sentences already said and
/// reveals the one being spoken at the estimated speaking rate. TTS gives no
/// word timings: each sentence starts in sync and the rate is learned from how
/// long finished sentences took.
struct CrowSpeechCaption {
    private(set) var isActive = false
    /// Non-whitespace characters of the sentences already spoken.
    private var spoken: [Character] = []
    private var segment: [Character] = []
    private var segmentStart: Date?
    /// Seconds per weighted character; about 4.5 Chinese characters a second.
    private var secondsPerUnit = 0.22

    mutating func start() {
        isActive = true
        spoken = []
        segment = []
        segmentStart = nil
    }

    mutating func stop() {
        isActive = false
        spoken = []
        segment = []
        segmentStart = nil
    }

    /// A sentence was handed to TTS; it shows once its audio starts.
    mutating func beginSegment(_ text: String) {
        finishSegment()
        segment = Self.visible(text)
        segmentStart = nil
    }

    mutating func segmentStarted(at now: Date = Date()) {
        if segmentStart == nil, !segment.isEmpty {
            segmentStart = now
        }
    }

    mutating func finishSegment(at now: Date = Date()) {
        guard !segment.isEmpty else { return }
        if let start = segmentStart {
            let elapsed = now.timeIntervalSince(start)
            let units = segment.reduce(0) { $0 + Self.weight($1) }
            if units >= 4, elapsed > 0.3 {
                secondsPerUnit = min(0.4, max(0.08, secondsPerUnit * 0.6 + elapsed / units * 0.4))
            }
        }
        spoken += segment
        segment = []
        segmentStart = nil
    }

    /// The part of `full` to show now: `full` itself when inactive, or when the
    /// reply was replaced by text the caption is not following.
    func text(full: String, now: Date = Date()) -> String {
        guard isActive else { return full }
        var target = spoken
        if let start = segmentStart {
            let budget = now.timeIntervalSince(start) / secondsPerUnit
            var used = 0.0
            for character in segment {
                used += Self.weight(character)
                if used > budget { break }
                target.append(character)
            }
        }
        guard !target.isEmpty else { return "" }
        // Take the prefix of `full` holding exactly `target`, keeping its spacing and line breaks.
        var matched = 0
        var end = full.startIndex
        for index in full.indices {
            let character = full[index]
            if character.isWhitespace { continue }
            guard character == target[matched] else { return full }
            matched += 1
            if matched == target.count {
                end = full.index(after: index)
                return String(full[..<end])
            }
        }
        return full
    }

    private static func visible(_ text: String) -> [Character] {
        text.filter { !$0.isWhitespace }.map { $0 }
    }

    /// Rough speaking time of a character: Chinese characters take longest,
    /// punctuation is a pause, Latin letters are short.
    private static func weight(_ character: Character) -> Double {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if scalar.value >= 0x2E80 {
            return CharacterSet.punctuationCharacters.contains(scalar) ? 0.8 : 1
        }
        if CharacterSet.punctuationCharacters.contains(scalar) { return 0.6 }
        return 0.32
    }
}
