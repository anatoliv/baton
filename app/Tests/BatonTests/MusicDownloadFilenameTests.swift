import Testing
@testable import Baton

struct MusicDownloadFilenameTests {
    @Test("Default template renders “Artist - Title.mp3”")
    func defaultTemplate() {
        let name = MusicDownloadStore.renderFilename(
            template: "{artist} - {title}",
            artist: "Daft Punk", album: "Discovery", title: "One More Time", id: "abc", taken: [:]
        )
        #expect(name == "Daft Punk - One More Time.mp3")
    }

    @Test("All tokens substitute")
    func allTokens() {
        let name = MusicDownloadStore.renderFilename(
            template: "{album}/{artist} — {title} ({id})",
            artist: "Air", album: "Moon Safari", title: "La Femme d'Argent", id: "xyz", taken: [:]
        )
        // The slash is illegal in a filename and is scrubbed to a space.
        #expect(name == "Moon Safari Air — La Femme d'Argent (xyz).mp3")
    }

    @Test("Illegal characters are stripped")
    func illegalStripped() {
        let name = MusicDownloadStore.renderFilename(
            template: "{artist}: {title}?",
            artist: "AC/DC", album: nil, title: "Who Made Who", id: "1", taken: [:]
        )
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!name.contains("?"))
        #expect(name.hasSuffix(".mp3"))
    }

    @Test("Empty result falls back to the id")
    func emptyFallsBackToID() {
        let name = MusicDownloadStore.renderFilename(
            template: "{artist} - {album}",
            artist: nil, album: nil, title: "x", id: "song42", taken: [:]
        )
        #expect(name == "song42.mp3")
    }

    @Test("A name owned by a different song is disambiguated; the same song keeps it")
    func dedupe() {
        let taken = ["other": "Daft Punk - One More Time.mp3"]
        let collide = MusicDownloadStore.renderFilename(
            template: "{artist} - {title}",
            artist: "Daft Punk", album: "", title: "One More Time", id: "mysong", taken: taken
        )
        #expect(collide == "Daft Punk - One More Time [mysong].mp3")

        // The song that already owns the file keeps the clean name (no suffix).
        let ownSelf = MusicDownloadStore.renderFilename(
            template: "{artist} - {title}",
            artist: "Daft Punk", album: "", title: "One More Time", id: "other", taken: taken
        )
        #expect(ownSelf == "Daft Punk - One More Time.mp3")
    }

    @Test("Leading dots are dropped so downloads aren't hidden files")
    func noHiddenFiles() {
        let name = MusicDownloadStore.renderFilename(
            template: "{title}", artist: nil, album: nil, title: ".hidden", id: "1", taken: [:]
        )
        #expect(!name.hasPrefix("."))
    }
}
