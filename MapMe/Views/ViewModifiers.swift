import SwiftUI

extension View {
    /// Caps a Form/List/text view so it doesn't stretch absurdly wide on
    /// macOS and iPad landscape, and centers it in the parent. On compact
    /// iPhone widths the cap has no effect because the screen is narrower
    /// than the cap.
    func centeredContent(maxWidth: CGFloat = 640) -> some View {
        self
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Wraps a Form so it gets the grouped style on every platform and a
    /// centered, capped width on Mac/iPad. Apply at the top of a view's
    /// `body` instead of writing the form modifier ladder by hand.
    func centeredForm(maxWidth: CGFloat = 640) -> some View {
        self
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .centeredContent(maxWidth: maxWidth)
    }

    /// Drops the full MapMe wordmark into the centred slot of the
    /// navigation bar so every top-level screen leads with the brand.
    /// `.principal` placement REPLACES the screen's own
    /// `.navigationTitle`; that's a deliberate tradeoff — on iOS the
    /// tab bar's label already tells the user which screen they're on
    /// (Live / History / Guardian / Settings), so the title slot is
    /// redundant and is a better home for the brand mark.
    ///
    /// No-op on tvOS (custom top chrome) and watchOS (doesn't share
    /// these screens).
    func mapMeBrandToolbar() -> some View {
        #if os(tvOS) || os(watchOS)
        return self
        #else
        return self.toolbar {
            ToolbarItem(placement: .principal) {
                // 132 × ~40 reads clearly on a 390 pt-wide iPhone nav
                // bar without crowding the back chevron or trailing
                // toolbar items.
                MapMeBrandImage()
                    .frame(width: 132, height: 40)
            }
        }
        #endif
    }
}

/// Center-of-screen stack of announcement balloons overlaying any
/// Guardian dashboard. Observes
/// `GuardianAudioAlertService.shared.visualAnnouncements` — fires
/// on every tracking transition (see the decoupled-from-audio
/// design). Center placement was chosen after top-right stacked
/// balloons were consistently missed by Guardians whose eyes were
/// already tracking the map's centre.
///
/// Each balloon slides in with a small downward drift, sits for
/// `visualAnnouncementTTL` (~6 s), then fades. Multiple in-flight
/// balloons stack vertically. Non-interactive
/// (`allowsHitTesting(false)`) so it doesn't steal focus / touches
/// from the underlying dashboard.
struct GuardianBalloonOverlay: View {
    @ObservedObject private var alerts = GuardianAudioAlertService.shared

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            ForEach(Array(alerts.visualAnnouncements.enumerated()), id: \.element.id) { _, ann in
                Text(ann.text)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.9).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.45, dampingFraction: 0.85),
                   value: alerts.visualAnnouncements.map(\.id))
    }
}

/// Motion + connectivity state Guardian dashboards display next to
/// each paired device.
///
/// - `.moving`: fresh fix within 30 min AND the latest fix has
///   meaningful speed (> 0.5 km/h). Bright green pulsing dot.
/// - `.stationary`: fresh fix within 30 min but speed is near zero
///   — either a real still-at-a-spot fix OR one of our synthetic
///   15-min heartbeats. Dim green solid dot.
/// - `.offline`: no fix in > 30 min. Grey dot.
enum DeviceMotionStatus {
    case moving
    case stationary
    case offline
}

/// Coloured dot rendered inside each Guardian-side device row / card
/// indicating the paired device's motion + connectivity state.
///
/// Three states — see `DeviceMotionStatus`. Shared across all four
/// Guardian surfaces (iPhone `FamilyDashboardView`, iPad
/// `IPadGuardianDashboardView`, macOS `MacGuardianDashboardView`
/// sidebar, tvOS `AppleTVGuardianDashboardView`) so the visual
/// state agrees everywhere and matches `GuardianAudioAlertService`'s
/// audible "back online" threshold.
struct OnlineIndicatorDot: View {
    let status: DeviceMotionStatus
    /// Sizing knob so per-surface densities (small in a Mac sidebar
    /// row, larger inside a tvOS card) can dial appropriately.
    var diameter: CGFloat = 10
    @State private var pulse: Bool = false

    /// Back-compat init for callers that only knew about the
    /// two-state green/grey. Maps `true` → `.moving` so existing
    /// call sites don't downgrade to `stationary`; new call sites
    /// should pass the full three-state enum.
    init(isOnline: Bool, diameter: CGFloat = 10) {
        self.status = isOnline ? .moving : .offline
        self.diameter = diameter
    }

    init(status: DeviceMotionStatus, diameter: CGFloat = 10) {
        self.status = status
        self.diameter = diameter
    }

    var body: some View {
        Circle()
            .fill(fillColor)
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle()
                    .stroke(status == .moving ? Color.green.opacity(0.6) : Color.clear,
                            lineWidth: 2)
                    .scaleEffect(pulse ? 2.0 : 1.0)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(
                        status == .moving
                        ? .easeOut(duration: 1.4).repeatForever(autoreverses: false)
                        : .default,
                        value: pulse
                    )
            )
            .overlay {
                // Small white X centered on the dot when offline —
                // matches the Live-map marker's offline affordance.
                // Two rotated capsules instead of an SF Symbol so
                // the strokes stay crisp at very small diameters
                // (the Mac sidebar uses ~8pt).
                if status == .offline {
                    let barLength = diameter * 0.7
                    let barWidth = max(1.5, diameter * 0.18)
                    ZStack {
                        Capsule()
                            .fill(Color.white)
                            .frame(width: barLength, height: barWidth)
                            .rotationEffect(.degrees(45))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: barLength, height: barWidth)
                            .rotationEffect(.degrees(-45))
                    }
                }
            }
            .onAppear { if status == .moving { pulse = true } }
            .onChange(of: status) { _, newStatus in
                pulse = (newStatus == .moving)
            }
    }

    private var fillColor: Color {
        switch status {
        case .moving:     return Color.green
        case .stationary: return Color.green.opacity(0.55)
        case .offline:    return Color.gray.opacity(0.45)
        }
    }
}

/// Single source of truth for the "is a paired device active" rules
/// every Guardian surface uses. Keeping these as static functions
/// on the audio-alert service (rather than a standalone helper)
/// means the visual state and the "back online" announcement can
/// never disagree.
extension GuardianAudioAlertService {
    /// Speed threshold (km/h). Below this we treat the device as
    /// stationary — matches `LocationService.stationarySpeedKmh` so
    /// heartbeats (written with `speed = 0`) always render
    /// stationary, real slow crawls still render moving, and
    /// dashboards agree with what the Minor was doing.
    static let movingSpeedThresholdKmh: Double = 0.5

    /// `true` when `lastFixAt` is fresh enough to consider the
    /// device online. Nil / never-seen reads as offline.
    static func isOnline(lastFixAt: Date?) -> Bool {
        guard let ts = lastFixAt else { return false }
        return Date().timeIntervalSince(ts) < 30 * 60
    }

    /// Three-state motion status for the indicator dot.
    ///
    /// `latestSpeedMS` is CLLocation's raw `speed` in metres/second
    /// (that's what CoreData stores). Negative or nil = "no speed
    /// data" which we conservatively treat as stationary — better
    /// to show a dim-green "attached" than a bright pulse for a
    /// device that isn't actually moving.
    static func motionStatus(lastFixAt: Date?, latestSpeedMS: Double?) -> DeviceMotionStatus {
        guard isOnline(lastFixAt: lastFixAt) else { return .offline }
        let speedKmh = max(0, (latestSpeedMS ?? 0)) * 3.6
        return speedKmh > movingSpeedThresholdKmh ? .moving : .stationary
    }
}

/// Two-line "© YYYY Hawksnest Software LLC" caption used at the
/// bottom of every startup / lock / setup screen. Kept as a shared
/// view so the year, wording, and styling stay in lockstep across
/// SplashView, LockView, SetPasscodeView, RoleChooserView,
/// WaitingForConsentView, and the watch's lock screen.
///
/// Year is derived from the current date so we never ship a
/// stale copyright string. Colour is `.secondary` so it reads as
/// legal chrome, not primary content.
///
/// Two rendering modes:
///   - `.adaptive` (default) uses `.secondary` so the caption picks
///     up the surrounding colour scheme. Best for iOS/macOS lock and
///     setup screens whose background follows system light/dark.
///   - `.forceLight` uses white-tinted text so it stays legible on
///     top of a permanently-dark background (SplashView's navy fill,
///     tvOS lock screen).
struct CopyrightFooter: View {
    enum Style { case adaptive, forceLight }
    var style: Style = .adaptive

    var body: some View {
        let year = Calendar.current.component(.year, from: Date())
        VStack(spacing: 2) {
            Text("© \(String(year)) Hawksnest Software LLC")
                .font(.caption2)
                .foregroundStyle(style == .forceLight
                                 ? AnyShapeStyle(Color.white.opacity(0.6))
                                 : AnyShapeStyle(.secondary))
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }
}

/// MapMe wordmark that switches between the white-text variant
/// (`MMLogo` — for splash, dark mode nav bars, dark material
/// overlays) and the black-text variant (`MMLogoLight` — for
/// light-mode nav bars, white forms, light material) based on the
/// current `colorScheme`.
///
/// Both assets render at 10:3 aspect; apply a `.frame(width:)` or
/// `.frame(height:)` at the call site to size — never both axes,
/// since that would squash the wordmark.
struct MapMeBrandImage: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Set to `.dark` or `.light` to force one variant regardless of
    /// the surrounding colour scheme. Useful for overlays whose
    /// background is fixed (e.g. the dark navy splash, or a light
    /// thinMaterial pill on top of a dark map). Default `nil`
    /// follows the environment.
    var forced: ColorScheme?

    var body: some View {
        let scheme = forced ?? colorScheme
        Image(scheme == .dark ? "MMLogo" : "MMLogoLight")
            .resizable()
            .scaledToFit()
            .accessibilityLabel("MapMe")
    }
}
