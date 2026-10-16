import Foundation

/// The APNs environment a build's device tokens belong to, from its
/// provisioning profile. Xcode signs `aps-environment` as `development` and
/// rewrites it on export, so the entitlements file cannot say which one a
/// build has; the embedded profile does.
public enum APSEnvironment {
    /// The relay's name for the environment: `sandbox` or `production`.
    /// `profile` is `embedded.mobileprovision`'s contents; an App Store or
    /// TestFlight build has none, and is production.
    public static func relayName(profile: Data?) -> String {
        guard let profile else { return "production" }
        switch apsEnvironment(inProfile: profile) {
        case "development": return "sandbox"
        default: return "production"
        }
    }

    /// `Entitlements.aps-environment` from a provisioning profile: a CMS
    /// envelope around an XML property list, read without verifying it.
    public static func apsEnvironment(inProfile data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let dict = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any],
              let entitlements = dict["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["aps-environment"] as? String
    }
}
