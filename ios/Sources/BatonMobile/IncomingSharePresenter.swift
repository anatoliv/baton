import BatonShareKit
import BatonSubsonicKit
import CoreFoundation
import SwiftUI
import UIKit

/// One scene-bound owner presents above nested SwiftUI sheets without dismissing their drafts.
private struct IncomingSharePresenter: UIViewControllerRepresentable {
    let model: MobileModel
    let pauseLibrary: () -> Void
    let playLibrary: (NavidromeSong) -> Void
    let invitation: ShareInvitation?
    let generation: UUID
    let scenePhase: ScenePhase
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIViewController(context: Context) -> AnchorController {
        let anchor = AnchorController()
        anchor.changed = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return anchor
    }
    func updateUIViewController(_ anchor: AnchorController, context: Context) {
        context.coordinator.update(invitation: invitation, generation: generation, phase: scenePhase,
                                   colorScheme: colorScheme, pause: pauseLibrary, play: playLibrary)
        context.coordinator.attach(anchor.viewIfLoaded?.window)
    }
    static func dismantleUIViewController(_ anchor: AnchorController, coordinator: Coordinator) {
        anchor.changed = nil
        coordinator.tearDown()
    }

    final class AnchorView: UIView {
        var changed: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); changed?(window) }
    }
    final class AnchorController: UIViewController {
        var changed: ((UIWindow?) -> Void)?
        override func loadView() {
            let anchor = AnchorView()
            anchor.isUserInteractionEnabled = false
            anchor.changed = { [weak self] window in self?.changed?(window) }
            view = anchor
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); changed?(view.window) }
    }
    final class IncomingHost: UIHostingController<AnyView> {
        var disappeared: (() -> Void)?
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed || presentingViewController == nil { disappeared?() }
        }
    }

    @MainActor final class Coordinator {
        private let model: MobileModel
        private weak var window: UIWindow?
        private var state = IncomingSharePresentationState<ShareInvitation>()
        private var host: IncomingHost?
        private var observer: CFRunLoopObserver?
        private var waitingTransition: ObjectIdentifier?
        private var active = false
        private var tornDown = false
        private var phase: ScenePhase = .inactive
        private var colorScheme: ColorScheme = .dark
        private var pause: () -> Void = {}
        private var play: (NavidromeSong) -> Void = { _ in }

        init(model: MobileModel) { self.model = model }
        func attach(_ candidate: UIWindow?) {
            // A fullScreenCover may detach the anchor; retain only the original weak window.
            guard !tornDown else { return }
            if let candidate {
                if let window, window !== candidate { return }
                window = candidate
            }
            drive()
        }
        func update(invitation: ShareInvitation?, generation: UUID, phase: ScenePhase, colorScheme: ColorScheme,
                    pause: @escaping () -> Void, play: @escaping (NavidromeSong) -> Void) {
            guard !tornDown else { return }
            self.phase = phase; self.colorScheme = colorScheme
            self.pause = pause; self.play = play
            active = phase == .active
            state.receive(invitation, token: generation)
            if state.request == nil || state.needsPrivateContentClear(sourceToken: model.incomingShareGeneration) {
                // Supersession clears old decrypted content/audio before an inactive scene,
                // stable alert or transition can defer the replacement presentation.
                host?.rootView = AnyView(EmptyView())
            }
            if !active { stopObserving() }
            // Keep scene lifecycle explicit in this separate hosting tree.
            if let request = state.request,
               state.phase == .presenting(request.token) || state.phase == .visible(request.token) {
                host?.rootView = content(request)
            }
            drive()
        }
        private func content(_ request: IncomingSharePresentationState<ShareInvitation>.Request) -> AnyView {
            let token = request.token
            let session = IncomingShareAudioSession { [weak self] callback in
                guard let self, !self.tornDown,
                      self.state.canActivateAudio(token, sourceToken: self.model.incomingShareGeneration,
                          foreground: self.active && self.window?.windowScene?.activationState == .foregroundActive)
                else { throw CancellationError() }
                return try self.model.incomingShareAudioSession.activate(callback)
            }
            return AnyView(IncomingSharedContent(invitation: request.invitation, audioSession: session,
                pauseLibrary: { [weak self] in
                    guard let self, self.isCurrent(token) else { return }; self.pause()
                }, playLibrary: { [weak self] song in
                    guard let self, self.isCurrent(token) else { return }; self.play(song)
                }, close: { [weak self] in self?.close(token) })
                .id(token).defaultAppStorage(BatonStorage.defaults)
                .environment(\.scenePhase, phase).environment(\.colorScheme, colorScheme))
        }
        private func isCurrent(_ token: UUID) -> Bool {
            state.isCurrent(token, sourceToken: model.incomingShareGeneration)
        }
        private func close(_ token: UUID) {
            guard isCurrent(token), state.close(token) else { return }
            model.incomingShare = nil
            host?.rootView = AnyView(EmptyView()) // release keys/audio even during presentation.
            stopObserving()
            drive()
        }
        private func topmost() -> UIViewController? {
            guard let window, window.windowScene?.activationState == .foregroundActive else { return nil }
            var controller = window.rootViewController
            while let presented = controller?.presentedViewController { controller = presented }
            return controller
        }
        private func drive() {
            guard !tornDown, active, let top = topmost() else { stopObserving(); return }
            // Transition completion owns retries; stable alerts legitimately wait for user input.
            if let transition = top.transitionCoordinator, transition.isAnimated {
                let identity = ObjectIdentifier(transition as AnyObject)
                guard waitingTransition != identity else { return }
                waitingTransition = identity; stopObserving()
                let accepted = transition.animate(alongsideTransition: nil) { [weak self] _ in
                    // UIKit completion is on the main thread; do not send UIKit state across actors.
                    MainActor.assumeIsolated {
                        guard let self, self.waitingTransition == identity else { return }
                        self.waitingTransition = nil; self.drive()
                    }
                }
                if accepted { return }
                waitingTransition = nil
                if state.request != nil { observeEvents() }
                return
            }
            let blocked = top is UIAlertController || top.isBeingPresented || top.isBeingDismissed
            if blocked {
                if state.request != nil { observeEvents() } else { stopObserving() }
                return
            }
            if let action = state.next(canPresent: true) {
                stopObserving()
                switch action {
                case let .present(request):
                    let token = request.token
                    let incoming = IncomingHost(rootView: content(request))
                    incoming.modalPresentationStyle = .overFullScreen
                    incoming.view.backgroundColor = UIColor.systemBackground
                    incoming.disappeared = { [weak self, weak incoming] in
                        guard let self, self.host === incoming else { return }
                        self.didDismiss(token)
                    }
                    host = incoming
                    top.present(incoming, animated: true) { [weak self, weak incoming] in
                        guard let self, self.host === incoming else { return }
                        self.state.presented(token); self.drive()
                    }
                case let .replace(request):
                    let token = request.token
                    host?.rootView = content(request)
                    host?.disappeared = { [weak self, weak host] in
                        guard let self, self.host === host else { return }; self.didDismiss(token)
                    }
                case let .dismiss(token):
                    // Dismiss only this controller, never its presenter or unrelated sheets.
                    guard let host else { state.dismissed(token); drive(); return }
                    host.rootView = AnyView(EmptyView())
                    host.dismiss(animated: true) { [weak self, weak host] in
                        guard let self, self.host === host else { return }; self.didDismiss(token)
                    }
                }
            } else { stopObserving() }
        }
        private func didDismiss(_ token: UUID) {
            guard state.phase == .presenting(token) || state.phase == .visible(token)
                || state.phase == .dismissing(token) else { return }
            // A late callback from the previous request cannot clear its replacement.
            if state.close(token), model.incomingShareGeneration == token { model.incomingShare = nil }
            state.dismissed(token)
            host?.disappeared = nil; host?.rootView = AnyView(EmptyView()); host = nil
            drive()
        }
        private func observeEvents() {
            guard observer == nil, state.request != nil, active, !tornDown else { return }
            // Passive event boundary only: no timer, task, wakeup or retry loop. UIKit input
            // that dismisses a pre-existing alert triggers the next foreground check.
            observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                true, 0) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.drive() }
                }
            if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        }
        private func stopObserving() {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        }
        func tearDown() {
            guard !tornDown else { return }
            tornDown = true; stopObserving(); waitingTransition = nil
            if let request = state.request, model.incomingShareGeneration == request.token { model.incomingShare = nil }
            state.clear()
            host?.disappeared = nil; host?.rootView = AnyView(EmptyView())
            host?.dismiss(animated: false); host = nil; window = nil
        }
    }
}

/// Read observable request identity in SwiftUI's body, not only in a UIKit update hook.
private struct IncomingSharePresentationOwner: View {
    let model: MobileModel
    let sceneID: UUID
    let pauseLibrary: () -> Void
    let playLibrary: (NavidromeSong) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        IncomingSharePresenter(model: model, pauseLibrary: pauseLibrary, playLibrary: playLibrary,
            invitation: IncomingShareSceneScope.owns(model.incomingShareSceneID, scene: sceneID) ? model.incomingShare : nil,
            generation: model.incomingShareGeneration,
            scenePhase: scenePhase, colorScheme: colorScheme)
            .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension View {
    func incomingSharePresenter(model: MobileModel, sceneID: UUID, pauseLibrary: @escaping () -> Void,
                                playLibrary: @escaping (NavidromeSong) -> Void) -> some View {
        background(IncomingSharePresentationOwner(model: model, sceneID: sceneID, pauseLibrary: pauseLibrary, playLibrary: playLibrary))
    }
}
