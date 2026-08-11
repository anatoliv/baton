import CarPlay
import Foundation

/// CarPlay: a tab bar of Albums / Liked / Downloads lists plus the system Now
/// Playing template. Template structure follows flo's MIT-licensed CarPlay layer
/// (the correct push-placeholder-then-update pattern) with Shelv's two hard-won
/// budgeting lessons applied: leave a virtual slot for the auto-pushed Now Playing
/// template, and respect `maximumItemCount` — CarPlay silently drops overflow.
///
/// DORMANT until the com.apple.developer.carplay-audio entitlement is granted:
/// without it iOS never launches this scene. The code compiles and ships inert.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let tabs = CPTabBarTemplate(templates: [albumsTemplate(), likedTemplate(), downloadsTemplate()])
        interfaceController.setRootTemplate(tabs, animated: false) { _, _ in }
        Task { @MainActor in await self.populate() }
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    // MARK: - Templates (placeholder-first, then updateSections)

    private let albumsList = CPListTemplate(title: "Albums", sections: [])
    private let likedList = CPListTemplate(title: "Liked", sections: [])
    private let downloadsList = CPListTemplate(title: "Downloads", sections: [])

    private func albumsTemplate() -> CPListTemplate {
        albumsList.tabTitle = "Albums"
        albumsList.tabImage = UIImage(systemName: "square.stack")
        return albumsList
    }

    private func likedTemplate() -> CPListTemplate {
        likedList.tabTitle = "Liked"
        likedList.tabImage = UIImage(systemName: "heart")
        return likedList
    }

    private func downloadsTemplate() -> CPListTemplate {
        downloadsList.tabTitle = "Downloads"
        downloadsList.tabImage = UIImage(systemName: "arrow.down.circle")
        return downloadsList
    }

    @MainActor
    private func populate() async {
        guard let model = AppServicesHolder.model else { return }
        if model.musicLibrary.albums.isEmpty { await model.musicLibrary.loadAlbums() }
        await model.musicLibrary.loadStarred()

        let itemBudget = CPListTemplate.maximumItemCount

        let albumItems = model.musicLibrary.albums.prefix(itemBudget).map { album in
            let item = CPListItem(text: album.name, detailText: album.artist)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    let songs = await model.musicLibrary.albumSongs(id: album.id)
                    if !songs.isEmpty {
                        model.music.play(songs, source: .init(label: album.name, kind: .album, id: album.id))
                        self?.pushNowPlaying()
                    }
                    completion()
                }
            }
            return item
        }
        albumsList.updateSections([CPListSection(items: Array(albumItems))])

        let likedSongs = model.musicLibrary.starred.songs
        let likedItems = likedSongs.prefix(itemBudget).enumerated().map { index, song in
            let item = CPListItem(text: song.title, detailText: song.artist)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    model.music.play(likedSongs, startAt: index, source: .init(label: "Liked", kind: .liked))
                    self?.pushNowPlaying()
                    completion()
                }
            }
            return item
        }
        likedList.updateSections([CPListSection(items: Array(likedItems))])

        let downloads = MusicDownloadStore.shared.downloadedItems()
        let downloadItems = downloads.prefix(itemBudget).enumerated().map { index, entry in
            let item = CPListItem(text: entry.title, detailText: entry.artist)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    model.music.play(downloads.map(\.song), startAt: index, source: .init(label: "Downloads", kind: .playlist))
                    self?.pushNowPlaying()
                    completion()
                }
            }
            return item
        }
        downloadsList.updateSections([CPListSection(items: Array(downloadItems))])
    }

    /// Push the system Now Playing template after starting playback — but never
    /// deeper than the depth budget allows (the auto-pushed instance occupies a
    /// virtual slot; pushing carelessly is the classic CarPlay hierarchy crash).
    private func pushNowPlaying() {
        guard let interfaceController, interfaceController.templates.count < 4 else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { _, _ in }
    }
}
