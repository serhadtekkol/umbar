//
//  DefaultsMigrationTests.swift
//  umbarTests
//
//  Fresh installs get the new defaults (K13, #93); an existing install keeps
//  what it was running with, explicit choices included.
//

import Foundation
import Testing

@Suite("DefaultsMigration")
struct DefaultsMigrationTests {
    private let version = DefaultsMigration.versionKey

    @Test func freshInstallOnlyRecordsTheVersion() {
        let writes = DefaultsMigration.writes(for: [:])
        #expect(writes.count == 1)
        #expect(writes[version] as? Int == DefaultsMigration.currentVersion)
    }

    @Test func systemKeysAloneStillMeanFreshInstall() {
        let stored: [String: Any] = [
            "NSWindow Frame Settings": "0 0 700 500",
            "AppleLanguages": ["tr"],
            "com.apple.something": true,
        ]
        let writes = DefaultsMigration.writes(for: stored)
        #expect(writes["hudReplacement"] == nil)
        #expect(writes["autoRemoveShelfItems"] == nil)
    }

    @Test func existingInstallKeepsTheOldDefaults() {
        let writes = DefaultsMigration.writes(for: ["preferred_screen_uuid": "ABC"])
        #expect(writes[version] as? Int == DefaultsMigration.currentVersion)
        for change in DefaultsMigration.changes {
            #expect(writes[change.key] as? Bool == change.previousDefault)
        }
    }

    @Test func explicitChoiceIsNeverOverwritten() {
        let writes = DefaultsMigration.writes(for: ["hudReplacement": true, "firstLaunch": false])
        #expect(writes["hudReplacement"] == nil)
    }

    @Test func currentDomainIsLeftAlone() {
        let stored: [String: Any] = [version: DefaultsMigration.currentVersion, "firstLaunch": false]
        #expect(DefaultsMigration.writes(for: stored).isEmpty)
    }

    @Test func versionedInstallOnlyGetsLaterChanges() {
        // An install already at version 1 never had hudReplacement stored
        // because it started with the new default; it must keep that.
        let stored: [String: Any] = [version: 1]
        let writes = DefaultsMigration.writes(for: stored)
        #expect(writes["hudReplacement"] == nil)
        for change in DefaultsMigration.changes where change.version > 1 {
            #expect(writes[change.key] as? Bool == change.previousDefault)
        }
    }

    @Test func versionKeyAloneIsNotEvidenceOfAnOldInstall() {
        #expect(!DefaultsMigration.isExistingInstall(storedKeys: [version]))
        #expect(DefaultsMigration.isExistingInstall(storedKeys: [version, "firstLaunch"]))
    }

    @Test func applyWritesIntoTheDomain() throws {
        let suite = "umbarTests.DefaultsMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: "firstLaunch")
        DefaultsMigration.apply(to: defaults, bundleID: suite)

        #expect(defaults.object(forKey: "hudReplacement") as? Bool == false)
        #expect(defaults.integer(forKey: version) == DefaultsMigration.currentVersion)
        #expect(defaults.object(forKey: "firstLaunch") as? Bool == false)
    }
}
