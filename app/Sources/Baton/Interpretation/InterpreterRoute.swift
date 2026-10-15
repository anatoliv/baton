import Foundation

@MainActor
protocol InterpreterRoute: AnyObject {
    var onFailure: (@MainActor () -> Void)? { get set }
    func begin() throws
    func append(_ pcm: Data) async throws
    func end() async throws -> (Double, Double)
    func stop()
}
