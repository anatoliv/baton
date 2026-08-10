import Foundation

/// Whether a radio station is well enough formed to save.
///
/// The Mac has checked scheme and host since the editor shipped; the phone checked only
/// that the two fields were non-empty, so "my station" with a stream URL of "radio" saved
/// happily and then failed silently at play time with nothing on screen to explain it.
/// A validator that exists on one platform is a validator the other platform's users do
/// not have.
public enum RadioStationInput {
    /// A station needs a name and an absolute http(s) stream URL.
    ///
    /// http as well as https deliberately: internet radio is overwhelmingly plain-HTTP
    /// Shoutcast/Icecast, which is why the app carries an ATS media exception at all.
    public static func isValid(name: String, streamURL: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = streamURL.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return false }
        guard let url = URL(string: trimmedURL), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
}
