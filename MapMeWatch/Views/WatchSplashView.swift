import SwiftUI

/// Compact splash for watchOS. Series 7+/Ultra screens (1.7–1.92") are too
/// small for the iOS horizontal lockup — we stack pin above wordmark and
/// shrink the type.
struct WatchSplashView: View {
    @State private var revealed = false

    var body: some View {
        ZStack {
            Color("MMSplashBackground")
                .ignoresSafeArea()

            VStack(spacing: 6) {
                WatchPinShape()
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
                    .frame(width: 36, height: 52)
                    .offset(y: revealed ? 0 : -8)
                    .opacity(revealed ? 1 : 0)

                Text("MapMe")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
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

private struct WatchPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
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
    WatchSplashView()
}
