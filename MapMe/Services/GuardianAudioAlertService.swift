#if os(iOS) || os(macOS) || os(tvOS)
import Foundation
import CoreData
import AVFoundation
import Combine

/// Guardian-side motion announcer. Watches the shared-store for new
/// `LocationRecord` arrivals, decides whether a paired Minor "just
/// started moving," and speaks their nickname aloud via
/// `AVSpeechSynthesizer` — "Alice is on the move."
///
/// Design decisions (per user scope):
///  - Nicknames are **local** to each Guardian device (UserDefaults),
///    keyed by profile UUID. Falls back to `MinorProfile.displayName`
///    when unset. This lets one Guardian device say "Alice" while
///    another says "Kiddo" without needing a CoreData migration.
///  - Runs on iOS, macOS, tvOS — everywhere a Guardian dashboard
///    can live. Watch is Minor-side; skipped there.
///  - Detection uses a "gap since last seen" heuristic: an incoming
///    record announces motion only if it lands more than
///    `restThreshold` after the previously-announced fix for the
///    same profile. That way a burst of CloudKit imports after
///    startup doesn't fire ten alerts.
///  - Debounced: at most one announcement per profile every
///    `minAlertSpacing`, so a walk that emits fixes every 15 s
///    doesn't spam the speaker.
@MainActor
final class GuardianAudioAlertService: ObservableObject {
    static let shared = GuardianAudioAlertService()

    // MARK: - Persistent settings

    /// User toggle. When off, the service is entirely inert — no
    /// remote-change subscription, no speech synth kept alive.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.kEnabledKey)
            if isEnabled { start() } else { stop() }
        }
    }
    private static let kEnabledKey = "MapMe.guardianAudioAlerts.enabled"

    /// Per-profile nickname overrides. Keyed by `MinorProfile.id`
    /// (UUID string). If unset, we fall back to
    /// `MinorProfile.displayName` at speak time.
    private var nicknames: [String: String] {
        didSet {
            UserDefaults.standard.set(nicknames, forKey: Self.kNicknamesKey)
        }
    }
    private static let kNicknamesKey = "MapMe.guardianAudioAlerts.nicknames"

    /// Last-announced fix timestamp per profile UUID. Persisted so a
    /// relaunch doesn't re-announce records we've already seen.
    private var lastAnnouncedAt: [String: Date] {
        didSet {
            let dict = lastAnnouncedAt.mapValues { $0.timeIntervalSince1970 }
            UserDefaults.standard.set(dict, forKey: Self.kLastAnnouncedKey)
        }
    }
    private static let kLastAnnouncedKey = "MapMe.guardianAudioAlerts.lastAnnounced"

    // MARK: - Tunables

    /// Minimum gap since the last announcement for a profile before
    /// a new fix counts as "just started moving." 10 min = a
    /// legitimate rest at home, in class, or in a shop.
    private static let restThreshold: TimeInterval = 10 * 60

    /// Minimum spacing between announcements for the *same* profile.
    /// Independent of `restThreshold` — the rest threshold catches
    /// motion-start; this catches "the profile started moving again
    /// after five minutes of stillness" and refuses to speak twice
    /// in quick succession.
    private static let minAlertSpacing: TimeInterval = 5 * 60

    // MARK: - Runtime

    private let synthesizer = AVSpeechSynthesizer()
    private var remoteChangeObserver: NSObjectProtocol?

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.kEnabledKey)
        self.nicknames = (UserDefaults.standard.dictionary(forKey: Self.kNicknamesKey)
                         as? [String: String]) ?? [:]
        if let raw = UserDefaults.standard.dictionary(forKey: Self.kLastAnnouncedKey)
            as? [String: TimeInterval] {
            self.lastAnnouncedAt = raw.mapValues { Date(timeIntervalSince1970: $0) }
        } else {
            self.lastAnnouncedAt = [:]
        }
        if isEnabled { start() }
    }

    // MARK: - Nickname API

    /// Nickname for `profile`, falling back to its display name.
    /// Guarantees a non-empty string so callers can trust the return.
    func nickname(for profile: MinorProfile) -> String {
        if let uuid = profile.id?.uuidString,
           let custom = nicknames[uuid],
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return profile.displayName?.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? "Your device"
    }

    /// Sets the nickname override for `profile`. Pass an empty string
    /// (or nil) to clear back to the display-name fallback.
    func setNickname(_ raw: String?, for profile: MinorProfile) {
        guard let uuid = profile.id?.uuidString else { return }
        let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        if trimmed.isEmpty {
            nicknames.removeValue(forKey: uuid)
        } else {
            nicknames[uuid] = trimmed
        }
    }

    // MARK: - Lifecycle

    private func start() {
        // Wire the remote-change observer; the shared store fires this
        // whenever CloudKit imports fresh records into it (which is
        // exactly when we want to check for a "started moving"
        // transition).
        guard remoteChangeObserver == nil else { return }
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: PersistenceController.shared.container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateAll()
            }
        }
        // Configure the audio session so speech routes through the
        // media channel and mixes gently with other audio (e.g. music).
        configureAudioSession()
    }

    private func stop() {
        if let token = remoteChangeObserver {
            NotificationCenter.default.removeObserver(token)
            remoteChangeObserver = nil
        }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func configureAudioSession() {
        #if os(iOS) || os(tvOS)
        // `.playback` so speech is heard even in silent mode;
        // `.mixWithOthers` so we don't stop the user's music/podcast.
        // `.duckOthers` would dip other audio during the announcement;
        // we deliberately choose `.mixWithOthers` instead so a short
        // announcement doesn't chop up a song noticeably.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        #endif
    }

    // MARK: - Detection

    /// Scans every `MinorProfile` in the private + shared stores,
    /// finds its newest record, and — if the gap from our last
    /// announcement passes the rest threshold — speaks.
    private func evaluateAll() {
        guard isEnabled else { return }
        let ctx = PersistenceController.shared.container.viewContext
        let request = NSFetchRequest<MinorProfile>(entityName: "MinorProfile")
        guard let profiles = try? ctx.fetch(request) else { return }
        let now = Date()

        for profile in profiles {
            guard let uuid = profile.id?.uuidString else { continue }
            guard let newest = latestRecord(for: profile),
                  let ts = newest.timestamp else { continue }
            // Skip stale records (e.g. a batch import of yesterday's
            // fixes) — only announce recent motion.
            guard now.timeIntervalSince(ts) <= 5 * 60 else { continue }

            let lastAnn = lastAnnouncedAt[uuid]
            let restedLongEnough = (lastAnn.map { ts.timeIntervalSince($0) } ?? .infinity) >= Self.restThreshold
            let spacedEnough = (lastAnn.map { now.timeIntervalSince($0) } ?? .infinity) >= Self.minAlertSpacing

            if restedLongEnough && spacedEnough {
                speak(name: nickname(for: profile))
                lastAnnouncedAt[uuid] = ts
            }
        }
    }

    private func latestRecord(for profile: MinorProfile) -> LocationRecord? {
        let set = (profile.records as? Set<LocationRecord>) ?? []
        return set.max { a, b in
            (a.timestamp ?? .distantPast) < (b.timestamp ?? .distantPast)
        }
    }

    /// Speaks the announcement. Keeps the synthesizer alive across
    /// calls (it's a stored property) so we don't cut off mid-word.
    private func speak(name: String) {
        let utterance = AVSpeechUtterance(string: "\(name) is on the move.")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.05
        utterance.postUtteranceDelay = 0.1
        synthesizer.speak(utterance)
    }
}

private extension String {
    /// Nil if the string is empty after whitespace trim, else self.
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespaces).isEmpty ? nil : self
    }
}
#endif
