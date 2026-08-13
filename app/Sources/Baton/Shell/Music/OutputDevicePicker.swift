import CoreAudio   // AudioDeviceID
import SwiftUI
import BatonPlaybackKit

/// Where Baton's own audio goes — the replacement for `AVRoutePickerView` while the engine
/// deck is active.
///
/// The system picker routes **AVPlayer**. With the engine deck playing, AVPlayer plays
/// nothing, so choosing a speaker there reported success — checkmark, volume slider — while
/// the sound carried on out of the previous device. A control that lies is worse than one
/// that is missing, because there is nothing to notice.
///
/// This routes *per-app*: `AVAudioEngine` is pointed at one CoreAudio device, so Baton moves
/// and every other app stays. Switching the system default would also work — that is how
/// AirPlay was proved reachable at all — but a music player re-pointing the whole machine's
/// audio from a button in its transport bar is not a thing to do to someone.
///
/// **AirPlay's caveat is surfaced rather than hidden.** An AirPlay destination becomes a
/// CoreAudio device only once macOS has connected it, so it cannot appear here first. The
/// menu says so and points at Control Centre, instead of silently offering a shorter list
/// than the user expects and leaving them to guess why.
struct OutputDevicePicker: View {
    /// The boundary of per-app routing, in the menu rather than in a doc nobody opens.
    ///
    /// Spoken summaries used to be on the wrong side of this line, and the line was honest
    /// about it. They now render through `SpeechAudioPlayer`, an engine speech owns, so they
    /// follow the choice — including the built-in fallback voice, which needed synthesizing to
    /// buffers before it could be routed anywhere.
    static let scopeNote =
        "Moves music and spoken summaries. Podcasts, downloads and radio follow the system output."

    @Environment(MusicModel.self) private var model
    var tint: Color = .secondary

    @State private var devices: [AudioOutputDevices.Device] = []
    @State private var selected: AudioDeviceID?

    private var bridge: EngineDeckBridge? { model.engineBridge }

    /// Point everything Baton renders itself at `device`, and report whether the music engine
    /// took it.
    ///
    /// Two engines, one choice. Speech has its own graph (`SpeechAudioPlayer`) because neither
    /// `AVAudioPlayer` nor `AVSpeechSynthesizer` can target a device — but a user picking a
    /// speaker means "send Baton there", not "send one subsystem there". Routing them from a
    /// single place is what keeps that promise; this is exactly the shape CLAUDE.md warns
    /// about, so there is one call site rather than two.
    ///
    /// The return value is the *music* engine's, because that is what decides whether the tick
    /// moves: speech has nothing playing most of the time, and a summary that routes
    /// successfully while the music deck refuses shouldn't tick a device music is not using.
    @discardableResult
    private func route(to device: AudioDeviceID?) -> Bool {
        let musicTook = bridge?.setOutputDevice(device) == true
        model.speech.setOutputDevice(device)
        return musicTook
    }

    var body: some View {
        Menu {
            Button {
                route(to: nil)
                selected = nil
                refresh()
            } label: {
                Label("System output", systemImage: selected == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(devices) { device in
                Button {
                    if route(to: device.id) { selected = device.id }
                    refresh()
                } label: {
                    // The system-default device is marked, because "System output" above and
                    // that named device are the same destination by another route, and two
                    // entries that do the same thing look like a bug otherwise.
                    Text(device.isSystemDefault ? "\(device.name) (system)" : device.name)
                    if device.id == selected { Image(systemName: "checkmark") }
                }
            }
            Divider()
            // Connecting and routing are two different jobs, and this picker can only do
            // the second. A CoreAudio device is what an AirPlay speaker *becomes* once
            // macOS has connected it; before that it exists only as an AirPlay destination
            // on the network, which is what the system picker discovers. Dropping the
            // system picker therefore lost the ability to reach a speaker that wasn't
            // already in use — narrower than the control it replaced. So it stays, for
            // connecting; the list above then routes Baton to it without moving anyone else.
            Button("Connect a Speaker…") { openSystemRoutePicker() }
            Text(AudioOutputDevices.systemDefaultHint)
            // What this control does *not* move (§3.5). Per-app routing means rendering
            // through a graph we own, so it reaches exactly what we render: library streams
            // on the music engine, and spoken summaries on speech's own engine. Podcasts,
            // downloads and internet radio are AVPlayer, which has no output-device API, so
            // they still follow the system output.
            //
            // Spoken summaries were on that list until §3.5 was done, and moving them off it
            // took more than a swap: the built-in fallback voice had to be synthesized to
            // buffers first, because `AVSpeechSynthesizer` cannot target a device either.
            // Saying where the boundary is, is the difference between a capability with a
            // boundary and a control that quietly lies about its reach.
            Text(Self.scopeNote)
        } label: {
            Image(systemName: "airplayaudio").foregroundStyle(tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Output device for music and spoken summaries — podcasts, downloads and radio follow the system output")
        .onAppear(perform: refresh)
    }

    /// Open macOS's own AirPlay list so a speaker can be *connected* — one click, in place.
    ///
    /// `AVRoutePickerView` has no API to present its menu, so the picker is hosted (sized to
    /// nothing, behind the transport) and its internal button is clicked directly. Apple's
    /// own AirPlay list then appears at that point. Using it only to *connect* sidesteps
    /// what made it useless here: its route selection drives AVPlayer, which plays nothing
    /// on this path — but connecting is a system-level act, and that part works.
    ///
    /// Reaching into another view's subviews is fragile by nature, so it degrades rather
    /// than fails: no button found, and Sound settings opens instead. Same destination, one
    /// extra step, and it cannot break.
    private func openSystemRoutePicker() {
        // Remember what existed before, so the speaker the user connects can be recognised
        // as *new* and followed.
        let before = Set(AudioOutputDevices.outputs().map(\.id))
        // Sound settings, *not* AVRoutePickerView — measured, after building it the other
        // way first. Apple's picker reports a speaker as connected (checkmark, volume
        // slider) while creating no system audio route at all: no CoreAudio device appears
        // and the default output never changes. Its "connection" is scoped to AVPlayer, the
        // same reason its route selection was useless here. Sound settings performs a real
        // system-level connection, after which the speaker exists as a device and the
        // routing below can reach it.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        followNewlyConnectedDevice(notIn: before, attemptsLeft: 60)
    }

    /// Move Baton onto whatever speaker the user just connected.
    ///
    /// Connecting and routing are separate acts underneath — a speaker becomes a CoreAudio
    /// device when macOS connects it, and Baton points at a device — but that distinction is
    /// ours, not the listener's. Choosing a speaker from Baton's menu and having the music
    /// stay where it was reads as a broken control, however correct the layering is. So the
    /// connect step now carries the routing with it.
    ///
    /// Polled because the device appears asynchronously, some seconds after the picker is
    /// dismissed, and there is no notification for "an AirPlay endpoint became a device".
    /// It gives up after thirty seconds rather than waiting forever on a connection that
    /// failed — which is what happens with a receiver that refuses, and the music simply
    /// stays put. Thirty rather than ten because an Apple TV handshake can sit on a spinner
    /// well past ten seconds, and a window that expires mid-connection looks exactly like
    /// the bug this exists to fix.
    private func followNewlyConnectedDevice(notIn before: Set<AudioDeviceID>, attemptsLeft: Int) {
        guard attemptsLeft > 0 else { refresh(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let now = AudioOutputDevices.outputs()
            if let fresh = now.first(where: { !before.contains($0.id) }) {
                if route(to: fresh.id) { selected = fresh.id }
                refresh()
            } else {
                followNewlyConnectedDevice(notIn: before, attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    private func refresh() {
        devices = AudioOutputDevices.outputs()
        // Re-read rather than trust our own last write: the device can change under us
        // (unplugged, AirPlay dropped) and the engine falls back on its own.
        if let live = bridge?.currentOutputDeviceID,
           live != AudioOutputDevices.defaultOutputDeviceID() {
            selected = live
        } else {
            selected = nil
        }
    }
}

