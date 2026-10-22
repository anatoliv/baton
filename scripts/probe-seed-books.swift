// Puts a few tiny books on a throwaway gateway through its own routes, for probes that need a
// home server with books on it (scripts/probe-storage-home-server.sh):
//
//   probe-seed-books <gateway base URL> <token file> <work dir>
//
// Each book is shaped by the same BatonDocuments code the apps use, submitted with
// `PUT /v1/books/{id}`, made by the gateway (against whatever voice server it was given), and
// waited for. The first is then marked finished, so its row carries a keep date. Prints one
// "<id> <bytes> <title>" line per book. The token is read from a file, never argv.
//
// Compiled together with Packages/BatonDocuments/Sources/BatonDocuments/*.swift (Foundation only).
import Foundation

@main
struct SeedBooks {
    static let books: [(String, String)] = [
        ("The Machine Stops", "## The Air-Ship\n\nImagine, if you can, a small room, hexagonal in shape, like the cell of a bee.\n\n## The Mending Apparatus\n\nThe Machine stops.\n"),
        ("Two Rooms", "## One\n\nAn electric bell rang.\n\n## Two\n\nThe light at the top was grey.\n\n## Three\n\nShe opened the door.\n"),
        ("Notes on a Garden", "## Spring\n\nThe beds were dug in March.\n"),
    ]

    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 4, let base = URL(string: args[1]),
              let token = try? String(contentsOfFile: args[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            FileHandle.standardError.write(Data("usage: probe-seed-books <base URL> <token file> <work dir>\n".utf8))
            exit(64)
        }
        let client = GatewayBookClient(baseURL: base, token: token)
        var ids: [String] = []
        do {
            for (title, body) in books {
                let url = URL(fileURLWithPath: args[3]).appendingPathComponent("\(title).md")
                try "# \(title)\n\n\(body)".write(to: url, atomically: true, encoding: .utf8)
                let prepared = DocumentSpeech.prepare(try DocumentImporter.importFile(at: url),
                                                      voices: VoicePlan(narrator: "kokoro:bf_emma"))
                ids.append(try await client.submit(prepared).id)
            }
            let deadline = Date().addingTimeInterval(180)
            var summaries: [BookJob.Summary] = []
            while Date() < deadline {
                summaries = []
                for id in ids { summaries.append(try await client.status(id)) }
                if summaries.allSatisfy({ $0.status == .ready }) { break }
                if let stuck = summaries.first(where: { $0.status == .failed || $0.status == .paused }) {
                    FileHandle.standardError.write(Data("\(stuck.title): \(stuck.status) \(stuck.pauseReason ?? "")\n".utf8))
                    exit(1)
                }
                try await Task.sleep(for: .seconds(1))
            }
            guard summaries.allSatisfy({ $0.status == .ready }) else {
                FileHandle.standardError.write(Data("the books were not made in time\n".utf8))
                exit(1)
            }
            try await client.markFinished(ids[0])
            for id in ids {
                let summary = try await client.status(id)
                print("\(summary.id) \(summary.bytes) \(summary.title)")
            }
        } catch {
            FileHandle.standardError.write(Data("seeding failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
