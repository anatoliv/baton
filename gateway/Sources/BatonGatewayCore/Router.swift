import BatonMCPProtocol
import Foundation

/// The gateway's route table, and the rules for picking a row out of it.
///
/// This used to be a run of `if request.method == … , request.path == …` inside
/// `main.swift`. A target with top-level code cannot be imported by a test target, so every
/// question about dispatch was unanswerable in a test: whether an unknown path 404s, whether
/// every route below `/health` really checks the token before it does anything, whether a
/// `GET` of a `POST`-only route says so or silently reads as "no such route" (S-F24). The
/// handlers stay in the executable, because they need the Navidrome client and the agent
/// loop; only the *choosing* moved here, where it is a value with a table in it.
///
/// ## The order of the checks is the security property
///
/// Authentication is decided **before** the path is looked up, for everything that is not
/// declared public. That ordering is not an accident of the old code, it is the behaviour
/// worth keeping: if an unknown path 404'd while a real one 401'd, an anonymous caller could
/// map every route this gateway serves by reading the status code. So an unauthenticated
/// request to any non-public path gets `401` whether the path exists or not, and `404` and
/// `405` are answers only an authenticated caller ever sees.
///
/// The one deliberate behaviour change from the `if` chain: a method mismatch on a known path
/// now answers `405` with an `Allow` header instead of falling through to `404`. `/v1/files/{id}`
/// already did this by hand; everything else pretended the path did not exist.
public struct Router: Sendable {
    /// A route handler. The second argument is the path parameter: for a `prefix` route,
    /// whatever followed the prefix (a file id); empty for an `exact` route.
    ///
    /// `@MainActor` because the gateway's state (the file store, the device link, the tool
    /// surface) is main-actor isolated, and pushing an actor hop into every handler would buy
    /// nothing but a place for one of them to forget it.
    public typealias Handler = @MainActor @Sendable (HTTPRequestMessage, String) async -> Data

    /// How a route claims a path.
    public enum Pattern: Sendable, Equatable {
        /// The whole path, matched exactly.
        case exact(String)
        /// A prefix; the remainder is handed to the handler as its parameter. Used by
        /// `/v1/files/` so `{id}` reaches the handler without a second `dropFirst` per route.
        case prefix(String)
    }

    public struct Route: Sendable {
        /// Uppercase method names this route answers to.
        public let methods: [String]
        public let pattern: Pattern
        /// True for the handful of routes that answer without a token. `/health` only.
        public let isPublic: Bool
        public let handler: Handler

        public init(methods: [String], pattern: Pattern, isPublic: Bool = false,
                    handler: @escaping Handler) {
            self.methods = methods.map { $0.uppercased() }
            self.pattern = pattern
            self.isPublic = isPublic
            self.handler = handler
        }

        func matchesPath(_ path: String) -> String? {
            switch pattern {
            case let .exact(value):
                return path == value ? "" : nil
            case let .prefix(value):
                return path.hasPrefix(value) ? String(path.dropFirst(value.count)) : nil
            }
        }
    }

    /// What `resolve` decided, before any handler runs. Separate from `dispatch` so the
    /// decision can be asserted on directly, with no handlers and no async.
    public enum Resolution: Sendable, Equatable {
        /// The index of the matching route in the table, and its path parameter.
        case route(index: Int, parameter: String)
        /// No token, or the wrong one, on a route that is not public.
        case unauthorized
        /// The path exists but not for this method. Carries the methods that would work,
        /// sorted, for the `Allow` header.
        case methodNotAllowed(allowed: [String])
        case notFound
    }

    private let routes: [Route]
    private let token: String

    /// - Parameters:
    ///   - token: the bearer token every non-public route requires.
    ///   - routes: the table, in priority order. Earlier rows win, so an `exact` row for a
    ///     path must come before any `prefix` row that would also swallow it.
    public init(token: String, routes: [Route]) {
        self.token = token
        self.routes = routes
    }

    /// Pick a row. Pure, synchronous, and the whole of the dispatch decision.
    public func resolve(method: String, path: String, isAuthenticated: Bool) -> Resolution {
        let method = method.uppercased()
        var allowedOnPath: Set<String> = []
        var sawPath = false

        // Public routes first, so `/health` answers without a token and a method mismatch on
        // it is honest rather than a 401 about a route that needs no auth.
        for (index, route) in routes.enumerated() where route.isPublic {
            guard let parameter = route.matchesPath(path) else { continue }
            sawPath = true
            allowedOnPath.formUnion(route.methods)
            if route.methods.contains(method) { return .route(index: index, parameter: parameter) }
        }
        if sawPath, !isAuthenticated {
            // A public path that exists, wrong method: 405 now, because no token was ever
            // needed here and pretending otherwise says nothing true.
            return .methodNotAllowed(allowed: allowedOnPath.sorted())
        }

        // Everything else is authenticated first and looked up second. See the type's note.
        guard isAuthenticated else { return .unauthorized }

        for (index, route) in routes.enumerated() where !route.isPublic {
            guard let parameter = route.matchesPath(path) else { continue }
            sawPath = true
            allowedOnPath.formUnion(route.methods)
            if route.methods.contains(method) { return .route(index: index, parameter: parameter) }
        }
        if sawPath { return .methodNotAllowed(allowed: allowedOnPath.sorted()) }
        return .notFound
    }

    /// Whether a presented token is the gateway's, compared in constant time.
    public func isAuthenticated(_ request: HTTPRequestMessage) -> Bool {
        BatonMCPAuth.constantTimeEquals(request.bearerToken ?? "", token)
    }

    /// Resolve, then run the handler or render the refusal.
    @MainActor
    public func dispatch(_ request: HTTPRequestMessage) async -> Data {
        switch resolve(method: request.method, path: request.path,
                       isAuthenticated: isAuthenticated(request)) {
        case let .route(index, parameter):
            return await routes[index].handler(request, parameter)
        case .unauthorized:
            return httpResponse(status: "401 Unauthorized", body: #"{"error":"bad token"}"#)
        case let .methodNotAllowed(allowed):
            return httpResponse(
                status: "405 Method Not Allowed", contentType: "application/json",
                payload: Data(jsonObject(["error": "method not allowed"]).utf8),
                extraHeaders: ["Allow": allowed.joined(separator: ", ")])
        case .notFound:
            return httpResponse(status: "404 Not Found", body: #"{"error":"unknown route"}"#)
        }
    }
}
