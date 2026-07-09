import Foundation

/// One-shot `@AppStorage` key migrations for settings whose storage key was
/// renamed. Pure and injectable (`defaults` is a parameter) so each migration can
/// be unit tested against a throwaway `UserDefaults(suiteName:)` without touching
/// the app's real `.standard` defaults.
public enum AppStorageMigration {

    /// Copies the value at `oldKey` into `newKey` only when `newKey` is unset AND
    /// `oldKey` is set — idempotent and safe to run on every launch.
    ///
    /// `UserDefaults.object(forKey:)` returns `nil` for a key that was never
    /// written, so an `@AppStorage` default that the user never changed never
    /// trips the "already set" guard (the default is materialized by the property
    /// wrapper on read, not persisted to UserDefaults until the user changes it).
    /// This means: a returning user with a previously-set `conversation.zoom`
    /// keeps their zoom; a fresh install (no old key) is a no-op to the default.
    public static func migrateZoomKey(
        from oldKey: String = "conversation.zoom",
        to newKey: String = "chat.zoom",
        in defaults: UserDefaults
    ) {
        guard defaults.object(forKey: newKey) == nil,
              let value = defaults.object(forKey: oldKey) else { return }
        defaults.set(value, forKey: newKey)
    }
}
