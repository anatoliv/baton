import SwiftUI

/// The **Mixes** tab — auto-generated "smart playlists" built on the fly from the server
/// (newest / top-rated / most-played / random) and your local signals (play history,
/// likes). Each card fetches its tracks on tap and plays them. No manual curation. The mix
/// cards themselves are the shared `MusicMix` / `MusicMixCard` (also used on Home).
struct MusicMixesView: View {
    @Environment(MusicModel.self) private var model

    private var mixes: [MusicMix] { MusicMixCatalog.auto(model) }
    private var genreMixes: [MusicMix] { MusicMixCatalog.genres(model) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mixes").font(.title3.weight(.semibold))
                Spacer()
            }
            // Match the shared browse header (Search): .title3 semibold at 12 / 8 / 4, and the
            // same row height (its filter field) so the title centers at the same Y.
            .frame(height: 28)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                    ForEach(mixes) { MusicMixCard(mix: $0) }
                }
                .padding(16)
                if !genreMixes.isEmpty {
                    HStack {
                        Text("Genres").font(.headline)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        ForEach(genreMixes) { MusicMixCard(mix: $0) }
                    }
                    .padding(16)
                }
            }
        }
        .task {
            if model.musicLibrary.starred.songs.isEmpty { await model.musicLibrary.loadStarred() }
            if model.musicLibrary.genres.isEmpty { await model.musicLibrary.loadGenres() }
        }
    }
}
