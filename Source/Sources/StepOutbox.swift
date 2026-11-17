import Foundation

struct StepOutbox {
    private let file: URL
    private(set) var batches: [StepBatch]

    init(file: URL) throws {
        self.file = file
        do {
            batches = try JSONDecoder().decode([StepBatch].self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            batches = []
        }
    }

    mutating func append(_ batch: StepBatch) throws {
        try save(batches + [batch])
    }

    mutating func acknowledge(_ id: UUID) throws {
        guard batches.first?.id == id else { return }
        try save(Array(batches.dropFirst()))
    }

    private mutating func save(_ updated: [StepBatch]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        batches = updated
    }
}
