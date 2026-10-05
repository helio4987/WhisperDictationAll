import Foundation

extension Bundle {
    /// Short marketing version (`CFBundleShortVersionString`), e.g. "1.0.9".
    /// Single source for the version string shown in the menu bar and Settings.
    /// Falls back to "1.0" when unavailable (e.g. the unit-test host bundle).
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

/// This fork's version numbering restarts at 1.0.0, independent of upstream's own
/// versioning. `upstreamVersion` records which upstream sam-pop/WhisperDictation
/// release this fork was originally based on, purely for display (see
/// `versionDisplayString`) so it's clear at a glance how far the fork has drifted.
let upstreamVersion = "1.2.1"

/// Combined version string shown in the menu bar and Settings footer, e.g.
/// "v1.0.0 (based on upstream 1.2.1)".
var versionDisplayString: String {
    "v\(Bundle.main.appVersion) (based on upstream \(upstreamVersion))"
}
