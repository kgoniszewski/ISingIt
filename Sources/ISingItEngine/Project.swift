import Foundation

/// An iSingIt project: the score plus how to render it. Saved as JSON in `.isingit`
/// files (phase 1; the plan's package format with a render cache comes later).
public struct Project: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1
    public static let fileExtension = "isingit"

    public var formatVersion: Int
    public var score: Score
    public var settings: RenderSettings

    public init(score: Score = Score(), settings: RenderSettings = RenderSettings()) {
        self.formatVersion = Project.currentFormatVersion
        self.score = score
        self.settings = settings
    }

    /// Opens a project file, or imports MusicXML/MIDI into a new project.
    public static func open(_ data: Data, fileName: String) throws -> Project {
        if fileName.lowercased().hasSuffix(".\(fileExtension)"),
           let project = try? JSONDecoder().decode(Project.self, from: data)
        {
            return project
        }
        var score = try ScoreImporter.importData(data, fileName: fileName)
        if score.title == nil {
            score.title = (fileName as NSString).deletingPathExtension
        }
        return Project(score: score)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
