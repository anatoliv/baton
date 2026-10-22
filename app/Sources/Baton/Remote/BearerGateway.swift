import Foundation
import BatonAgentKit
import BatonPlaybackKit
import BatonSubsonicKit

/// The gateway Settings configures and its token, for every Mac path that sends the token
///
///
/// Nil until both are set, or when the address is one the token must not be sent to: plain
/// HTTP to an IP address off the home network (`GatewayAddress.allowsBearer`, the phone's rule
/// through `MobileModel.bearerGateway`). Kept readings, revoiced clippings, deleting a shared
/// copy, home-server books, the document inbox, preference sync and the Settings buttons all
/// start here. `BearerGatewayTests` fails if another file reads the token's Keychain account.
enum BearerGateway {
    static let addressKey = "baton.agent.gatewayURL"
    static let tokenAccount = "baton.agent.gatewayToken"

    /// The address and token as Settings holds them now.
    static func configured() -> (url: URL, token: String)? {
        resolve(address: BatonStorage.defaults.string(forKey: addressKey), token: savedToken())
    }

    /// The saved token, for Settings to show. Anything that sends it uses `configured()` or
    /// `resolve(address:token:)` instead.
    static func savedToken() -> String? {
        NavidromeKeychain.secret(account: tokenAccount)
    }

    /// Trim both, parse the address, and refuse an address the token must not travel to.
    static func resolve(address: String?, token: String?) -> (url: URL, token: String)? {
        let raw = (address ?? "").trimmingCharacters(in: .whitespaces)
        let secret = (token ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !secret.isEmpty,
              let url = URL(string: raw), url.scheme != nil, url.host != nil,
              GatewayAddress.allowsBearer(to: url, isPrivate: RemoteNaturalLanguage.isPrivate)
        else { return nil }
        return (url, secret)
    }
}
