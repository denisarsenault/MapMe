import SwiftUI

/// Brief brand splash shown over `RootView` on launch. Same composition as
/// the iOS UILaunchScreen (dark navy background + frameless MapMe wordmark)
/// so the system launch image and the in-app splash form one continuous
/// loading moment — no jarring flash when the SwiftUI hierarchy spins up.
///
/// macOS and tvOS don't have an OS-level launch screen, so this view *is*
/// the splash on those platforms. It self-dismisses after the callers'
/// timed binding flips.
struct SplashView: View {
    @State private var revealed = false

    var body: some View {
        ZStack {
            // Matches Info-iOS.plist UILaunchScreen UIColorName so the
            // system launch image and this view share the same fill.
            Color("MMSplashBackground")
                .ignoresSafeArea()

            HStack(spacing: 18) {
                MapPinShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.30, green: 0.66, blue: 1.00),
                                Color(red: 0.10, green: 0.42, blue: 0.92),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(
                        // White hole in the pin head.
                        GeometryReader { g in
                            let w = g.size.width
                            let h = g.size.height
                            let r = w / 2
                            let tipY = h - 4
                            let headCY = tipY - 2.5 * r
                            Circle()
                                .fill(.white)
                                .frame(width: r * 0.84, height: r * 0.84)
                                .position(x: w / 2, y: headCY)
                        }
                    )
                    .frame(width: 64, height: 92)
                    .offset(y: revealed ? 0 : -16)
                    .opacity(revealed ? 1 : 0)

                Text("MapMe")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .opacity(revealed ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                revealed = true
            }
        }
    }
}

/// Teardrop pin path — SwiftUI twin of the CG version in
/// `Tools/generate_icons.swift`.
private struct MapPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        _ = rect.height
        let r = w / 2
        let cx = rect.midX
        let tipY = rect.maxY - 4
        let headCY = tipY - 2.5 * r

        var p = Path()
        p.move(to: CGPoint(x: cx, y: tipY))
        p.addQuadCurve(
            to: CGPoint(x: cx + r, y: headCY),
            control: CGPoint(x: cx + r * 0.42, y: headCY + r * 1.45)
        )
        // SwiftUI is y-down: sweep right (0°) → left (180°) *clockwise*
        // to go over the top of the head circle.
        p.addArc(
            center: CGPoint(x: cx, y: headCY),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(180),
            clockwise: true
        )
        p.addQuadCurve(
            to: CGPoint(x: cx, y: tipY),
            control: CGPoint(x: cx - r * 0.42, y: headCY + r * 1.45)
        )
        p.closeSubpath()
        return p
    }
}

#Preview {
    SplashView()
}
