import Foundation
import Testing
@testable import CalendarApp

@Suite("DigestSettingsTests")
struct DigestSettingsTests {
    @Test func inMemoryCredentialsSaveOverwriteDeleteAndNeverTreatEmptyAsConfigured() throws {
        let store = InMemoryDigestCredentialStore()
        #expect(try store.load() == nil)
        #expect(store.isConfigured == false)

        try store.save("secret-one")
        #expect(try store.load() == "secret-one")
        #expect(store.isConfigured)

        try store.save("secret-two")
        #expect(try store.load() == "secret-two")

        try store.save("   ")
        #expect(try store.load() == nil)
        #expect(store.isConfigured == false)

        try store.save("secret-three")
        try store.delete()
        #expect(try store.load() == nil)
        #expect(store.isConfigured == false)
    }

    @Test func endpointMustBeHTTPSWithoutTrailingSlashAndModelMustBeNonempty() {
        #expect(DigestSettingsNormalization.endpoint("https://api.example.com/v1/") == "https://api.example.com/v1")
        #expect(DigestSettingsNormalization.endpoint("https://api.example.com/v1") == "https://api.example.com/v1")
        #expect(DigestSettingsNormalization.endpoint("http://api.example.com/v1") == nil)
        #expect(DigestSettingsNormalization.endpoint("ftp://api.example.com/v1") == nil)
        #expect(DigestSettingsNormalization.endpoint("https://user:secret@api.example.com/v1") == nil)
        #expect(DigestSettingsNormalization.endpoint("https://api.example.com/v1?tenant=secret") == nil)
        #expect(DigestSettingsNormalization.endpoint("https://api.example.com/v1#secret") == nil)
        #expect(DigestSettingsNormalization.endpoint("not-a-url") == nil)
        #expect(DigestSettingsNormalization.model("  gpt-4o-mini  ") == "gpt-4o-mini")
        #expect(DigestSettingsNormalization.model("   ") == nil)
        #expect(
            DigestRuntimeConfiguration.isConfigured(
                endpoint: "https://api.example.com/v1",
                model: "gpt-test",
                secret: "sk-test"
            )
        )
        #expect(
            DigestRuntimeConfiguration.isConfigured(
                endpoint: "https://api.example.com/v1",
                model: "gpt-test",
                secret: nil
            ) == false
        )
        #expect(
            DigestRuntimeConfiguration.isConfigured(
                endpoint: "http://api.example.com/v1",
                model: "gpt-test",
                secret: "sk-test"
            ) == false
        )
    }

    @Test func settingsStorePersistsOnlyNonSecretPreferences() {
        let suite = "jelly-digest-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = DigestSettingsStore(defaults: defaults)
        #expect(store.endpoint.isEmpty)
        #expect(store.model.isEmpty)

        #expect(store.save(endpoint: "https://api.example.com/v1/", model: " gpt-test "))
        #expect(store.endpoint == "https://api.example.com/v1")
        #expect(store.model == "gpt-test")
        #expect(defaults.string(forKey: DigestSettingsStore.endpointKey) == "https://api.example.com/v1")
        #expect(defaults.string(forKey: DigestSettingsStore.modelKey) == "gpt-test")
        #expect(defaults.dictionaryRepresentation().values.contains(where: { ($0 as? String)?.contains("sk-") == true }) == false)

        #expect(store.save(endpoint: "http://insecure.example.com", model: "gpt-test") == false)
        #expect(store.endpoint == "https://api.example.com/v1")
    }
}
