import Foundation

let manager = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let now = Date()
let day: TimeInterval = 86_400
var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition { print("PASS: \(message)") }
    else { failures += 1; print("FAIL: \(message)") }
}

func folder(_ name: String) throws -> URL {
    let result = root.appendingPathComponent(name, isDirectory: true)
    try manager.createDirectory(at: result, withIntermediateDirectories: true)
    return result
}

func write(_ url: URL, _ text: String = "original recording") throws {
    try Data(text.utf8).write(to: url)
}

func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }

func records(in folder: URL) throws -> [URL] {
    try manager.contentsOfDirectory(at: folder.appendingPathComponent("Originals"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
}

do {
    let library = try folder("full-retention")
    let source = library.appendingPathComponent("old.mp4")
    try write(source)
    try manager.setAttributes([.creationDate: now.addingTimeInterval(-120 * day), .modificationDate: now.addingTimeInterval(-120 * day)], ofItemAtPath: source.path)
    let archived = try OriginalsArchive.retain(source, now: now)
    check(!exists(source) && exists(archived), "retaining moves the original out of the library")
    check(try Data(contentsOf: archived) == Data("original recording".utf8), "the original's contents survive unchanged")
    OriginalsArchive.prune(in: library, keeping: .month, now: now.addingTimeInterval(29 * day))
    check(exists(archived), "an old recording keeps the full retention window from compression")
    OriginalsArchive.prune(in: library, keeping: .month, now: now.addingTimeInterval(31 * day))
    check(!exists(archived), "an owned recording expires after its retention window")
    check(try records(in: library).isEmpty, "expiry also removes the completed ownership record")
}

do {
    let library = try folder("foreign-originals")
    let originals = library.appendingPathComponent("Originals", isDirectory: true)
    try manager.createDirectory(at: originals, withIntermediateDirectories: true)
    let foreign = originals.appendingPathComponent("family.mp4")
    try write(foreign)
    let foreignDirectory = originals.appendingPathComponent("collection.gif", isDirectory: true)
    try manager.createDirectory(at: foreignDirectory, withIntermediateDirectories: true)
    let child = foreignDirectory.appendingPathComponent("keep.txt")
    try write(child)
    OriginalsArchive.prune(in: library, keeping: .week, now: now.addingTimeInterval(200 * day))
    check(exists(foreign) && exists(child), "unowned recordings and directories in Originals are never deleted")

    let source = library.appendingPathComponent("family.mp4")
    try write(source, "new recording")
    let archived = try OriginalsArchive.retain(source, now: now)
    check(archived != foreign && exists(foreign), "archiving preserves existing names")
    OriginalsArchive.prune(in: library, keeping: .discard, now: now.addingTimeInterval(200 * day))
    check(exists(archived), "Move to Trash policy leaves earlier retained originals alone")
    OriginalsArchive.prune(in: library, keeping: .week, now: now.addingTimeInterval(8 * day))
    check(!exists(archived) && exists(foreign), "only the owned copy expires beside an unrelated original")
}

do {
    let library = try folder("replacement-identity")
    let source = library.appendingPathComponent("clip.mp4")
    try write(source)
    let archived = try OriginalsArchive.retain(source, now: now)
    let moved = library.appendingPathComponent("recovered.mp4")
    try manager.moveItem(at: archived, to: moved)
    try write(archived, "unrelated replacement")
    OriginalsArchive.prune(in: library, keeping: .week, now: now.addingTimeInterval(8 * day))
    check(exists(archived) && exists(moved), "a different file at an archive's old name is preserved")

    try manager.removeItem(at: archived)
    try manager.createSymbolicLink(at: archived, withDestinationURL: moved)
    OriginalsArchive.prune(in: library, keeping: .week, now: now.addingTimeInterval(8 * day))
    check(exists(archived) && exists(moved), "symlinks are never followed by archive expiry")

    try manager.removeItem(at: archived)
    try manager.createDirectory(at: archived, withIntermediateDirectories: true)
    let child = archived.appendingPathComponent("child")
    try write(child)
    OriginalsArchive.prune(in: library, keeping: .week, now: now.addingTimeInterval(8 * day))
    check(exists(child), "a directory replacing an archive is never recursively removed")
}

do {
    let library = try folder("missing-metadata")
    let source = library.appendingPathComponent("clip.gif")
    try write(source)
    let archived = try OriginalsArchive.retain(source, now: now)
    for record in try records(in: library) { try manager.removeItem(at: record) }
    OriginalsArchive.prune(in: library, keeping: .week, now: now.addingTimeInterval(8 * day))
    check(exists(archived), "a missing ownership record preserves the original")
}

do {
    let library = try folder("corrupt-metadata")
    let source = library.appendingPathComponent("clip.gif")
    try write(source)
    let archived = try OriginalsArchive.retain(source, now: now)
    for record in try records(in: library) { try write(record, "not JSON") }
    OriginalsArchive.prune(in: library, keeping: .week, now: now.addingTimeInterval(8 * day))
    check(exists(archived), "a corrupt ownership record preserves the original")
}

do {
    let library = try folder("invalid-metadata-path")
    let source = library.appendingPathComponent("clip.mp4")
    try write(source)
    let archived = try OriginalsArchive.retain(source, now: now)
    let recovered = library.appendingPathComponent("recovered.mp4")
    try manager.moveItem(at: archived, to: recovered)
    for record in try records(in: library) {
        var contents = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: Any]
        contents["filename"] = "../recovered.mp4"
        try JSONSerialization.data(withJSONObject: contents).write(to: record)
    }
    OriginalsArchive.prune(in: library, keeping: .week, now: now.addingTimeInterval(8 * day))
    check(exists(recovered), "invalid metadata cannot expire a file outside Originals")
}

do {
    let library = try folder("archive-blocked")
    let source = library.appendingPathComponent("clip.mp4")
    try write(source)
    try write(library.appendingPathComponent("Originals"), "an unrelated file occupies the folder name")
    do {
        try OriginalsArchive.retain(source, now: now)
        check(false, "unavailable archive storage reports failure")
    } catch {
        check(exists(source), "an archive preparation failure preserves the source")
    }
}

print(failures == 0 ? "\nAll archive checks passed." : "\n\(failures) archive check(s) failed.")
exit(failures == 0 ? 0 : 1)
