import Foundation
@testable import TalkTalkCore

/// Repository paths for tests (no SwiftPM resources, §2.2).
enum TestResources {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func resource(_ name: String) -> URL { repoRoot.appendingPathComponent("Resources").appendingPathComponent(name) }
    static func golden(_ name: String) -> URL {
        repoRoot.appendingPathComponent("Tests/Golden").appendingPathComponent(name)
    }
    static func profile() throws -> PolicyProfile { try PolicyProfile.load(from: resource("PolicyProfile.default.json")) }
    static func prompts() throws -> MTPrompts { try MTPrompts.load(from: resource("prompts/mt.json")) }
    static func gatePatterns() throws -> GatePatterns { try GatePatterns.load(from: resource("prompts/gate.json")) }
}
