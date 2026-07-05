#!/usr/bin/env swift
// MapMe icon generator.
// Renders the AppIcon set (iOS + macOS + tvOS) and a small toolbar set
// into MapMe/Assets.xcassets in a glossy blue squircle style inspired by
// the SecurityHawk icon. Run with: swift Tools/generate_icons.swift

import Cocoa

// MARK: - Paths

let assetsRoot = URL(fileURLWithPath:
    "/Users/denisarsenault/Developer/MapMe/MapMe/Assets.xcassets")
let appIconDir = assetsRoot.appendingPathComponent("AppIcon.appiconset")
let watchAppIconDir = URL(fileURLWithPath:
    "/Users/denisarsenault/Developer/MapMe/MapMeWatch/Assets.xcassets/AppIcon.appiconset")
let watchAssetsRoot = URL(fileURLWithPath:
    "/Users/denisarsenault/Developer/MapMe/MapMeWatch/Assets.xcassets")
let previewURL = URL(fileURLWithPath:
    "/Users/denisarsenault/Developer/MapMe/Tools/icons_preview.png")

// MARK: - Palette

let cFrameOuter = NSColor(red: 0.04, green: 0.16, blue: 0.36, alpha: 1.0)
let cFrameInner = NSColor(red: 0.10, green: 0.30, blue: 0.58, alpha: 1.0)
let cBgTop      = NSColor(white: 1.00, alpha: 1.0)
let cBgBot      = NSColor(white: 0.74, alpha: 1.0)
let cPin        = NSColor(red: 0.12, green: 0.55, blue: 1.00, alpha: 1.0)
let cPinDark    = NSColor(red: 0.04, green: 0.32, blue: 0.78, alpha: 1.0)
let cPinHole    = NSColor.white
let cSpeedLine  = NSColor(red: 0.42, green: 0.72, blue: 1.00, alpha: 0.95)
let cGloss      = NSColor(white: 1.0, alpha: 0.55)
let cToolbar    = NSColor(red: 0.08, green: 0.36, blue: 0.78, alpha: 1.0)

// MARK: - Bitmap helpers

func makeRep(width: Int, height: Int) -> NSBitmapImageRep {
    let r = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32)!
    r.size = NSSize(width: width, height: height)
    return r
}

func draw(into rep: NSBitmapImageRep, _ body: (CGContext) -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let ctxObj = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctxObj
    body(ctxObj.cgContext)
    NSGraphicsContext.restoreGraphicsState()
}

func savePNG(_ rep: NSBitmapImageRep, to url: URL) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

// MARK: - Map pin path

func mapPinPath(cx: CGFloat, tipY: CGFloat, headRadius r: CGFloat) -> CGPath {
    // tipY is the y coord of the pin's pointy bottom (math y-up).
    // Head circle is centered above the tip.
    let headCY = tipY + 2.5 * r
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx, y: tipY))
    p.addQuadCurve(to: CGPoint(x: cx + r, y: headCY),
                   control: CGPoint(x: cx + r * 0.42, y: headCY - r * 1.45))
    p.addArc(center: CGPoint(x: cx, y: headCY), radius: r,
             startAngle: 0, endAngle: .pi, clockwise: false)
    p.addQuadCurve(to: CGPoint(x: cx, y: tipY),
                   control: CGPoint(x: cx - r * 0.42, y: headCY - r * 1.45))
    p.closeSubpath()
    return p
}

// MARK: - Composition pieces (operate in a normalized 0..s coordinate space)

func drawSpeedLines(_ ctx: CGContext, s: CGFloat) {
    ctx.saveGState()
    ctx.setFillColor(cSpeedLine.cgColor)
    let h = s * 0.028
    let lines: [(y: CGFloat, w: CGFloat, x: CGFloat)] = [
        (0.65, 0.46, 0.10),
        (0.55, 0.40, 0.10),
        (0.44, 0.32, 0.10),
        (0.33, 0.22, 0.10),
    ]
    for l in lines {
        let rect = CGRect(x: s * l.x, y: s * l.y, width: s * l.w, height: h)
        ctx.addPath(CGPath(roundedRect: rect,
                           cornerWidth: h/2, cornerHeight: h/2, transform: nil))
    }
    ctx.fillPath()
    ctx.restoreGState()
}

func drawMapPin(_ ctx: CGContext, s: CGFloat) {
    let cx = s * 0.62
    let tipY = s * 0.18
    let r = s * 0.18
    let pinPath = mapPinPath(cx: cx, tipY: tipY, headRadius: r)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010),
                  blur: s * 0.022,
                  color: NSColor.black.withAlphaComponent(0.40).cgColor)
    ctx.addPath(pinPath)
    ctx.setFillColor(cPinDark.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient
    ctx.saveGState()
    ctx.addPath(pinPath)
    ctx.clip()
    let colors = [cPin.cgColor, cPinDark.cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0.0, 1.0])!
    let bbox = pinPath.boundingBox
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: bbox.maxY),
                           end:   CGPoint(x: 0, y: bbox.minY),
                           options: [])
    ctx.restoreGState()

    // White hole
    let headCY = tipY + 2.5 * r
    let holeR = r * 0.42
    let holeRect = CGRect(x: cx - holeR, y: headCY - holeR,
                          width: 2*holeR, height: 2*holeR)
    ctx.setFillColor(cPinHole.cgColor)
    ctx.fillEllipse(in: holeRect)

    // Subtle inner shadow at top of hole
    ctx.saveGState()
    ctx.addPath(CGPath(ellipseIn: holeRect, transform: nil))
    ctx.clip()
    let shadowColors = [
        NSColor.black.withAlphaComponent(0.30).cgColor,
        NSColor.clear.cgColor
    ] as CFArray
    let shadowGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: shadowColors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(shadowGrad,
                           start: CGPoint(x: cx, y: holeRect.maxY),
                           end:   CGPoint(x: cx, y: holeRect.midY),
                           options: [])
    ctx.restoreGState()
}

func drawGloss(_ ctx: CGContext, in inner: CGRect) {
    ctx.saveGState()
    let glossRect = CGRect(
        x: inner.minX - inner.width * 0.18,
        y: inner.midY,
        width: inner.width * 1.36,
        height: inner.height * 0.55
    )
    ctx.addPath(CGPath(ellipseIn: glossRect, transform: nil))
    ctx.clip()
    let colors = [cGloss.cgColor, NSColor.clear.cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: inner.maxY),
                           end:   CGPoint(x: 0, y: inner.midY),
                           options: [])
    ctx.restoreGState()
}

// MARK: - App icon

func renderAppIcon(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = makeRep(width: size, height: size)

    draw(into: rep) { ctx in
        // Frame squircle
        let outerInset = s * 0.05
        let outerRect = CGRect(x: outerInset, y: outerInset,
                               width: s - 2*outerInset, height: s - 2*outerInset)
        let outerR = outerRect.width * 0.225
        let outerPath = CGPath(roundedRect: outerRect,
                               cornerWidth: outerR, cornerHeight: outerR,
                               transform: nil)

        // Drop shadow + base fill
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.014),
                      blur: s * 0.05,
                      color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.addPath(outerPath)
        ctx.setFillColor(cFrameOuter.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Frame gradient
        ctx.saveGState()
        ctx.addPath(outerPath); ctx.clip()
        let frameColors = [cFrameInner.cgColor, cFrameOuter.cgColor] as CFArray
        let frameGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: frameColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(frameGrad,
                               start: CGPoint(x: 0, y: s),
                               end:   CGPoint(x: 0, y: 0),
                               options: [])
        ctx.restoreGState()

        // Inner light squircle
        let frameThick = s * 0.05
        let innerRect = outerRect.insetBy(dx: frameThick, dy: frameThick)
        let innerR = innerRect.width * 0.20
        let innerPath = CGPath(roundedRect: innerRect,
                               cornerWidth: innerR, cornerHeight: innerR,
                               transform: nil)

        ctx.saveGState()
        ctx.addPath(innerPath); ctx.clip()

        let bgColors = [cBgTop.cgColor, cBgBot.cgColor] as CFArray
        let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: bgColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(bgGrad,
                               start: CGPoint(x: 0, y: s),
                               end:   CGPoint(x: 0, y: 0),
                               options: [])

        drawSpeedLines(ctx, s: s)
        drawMapPin(ctx, s: s)
        drawGloss(ctx, in: innerRect)
        ctx.restoreGState()
    }

    return rep
}

// MARK: - watchOS icon (circular)

func renderWatchIcon(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = makeRep(width: size, height: size)

    draw(into: rep) { ctx in
        let fullRect = CGRect(x: 0, y: 0, width: s, height: s)

        // Dark blue ring (outer disk)
        let outerInset = s * 0.02
        let outerRect = fullRect.insetBy(dx: outerInset, dy: outerInset)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                      blur: s * 0.04,
                      color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.addPath(CGPath(ellipseIn: outerRect, transform: nil))
        ctx.setFillColor(cFrameOuter.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Frame gradient
        ctx.saveGState()
        ctx.addPath(CGPath(ellipseIn: outerRect, transform: nil))
        ctx.clip()
        let frameColors = [cFrameInner.cgColor, cFrameOuter.cgColor] as CFArray
        let frameGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: frameColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(frameGrad,
                               start: CGPoint(x: 0, y: s),
                               end:   CGPoint(x: 0, y: 0),
                               options: [])
        ctx.restoreGState()

        // Inner light disk
        let frameThick = s * 0.05
        let innerRect = outerRect.insetBy(dx: frameThick, dy: frameThick)
        ctx.saveGState()
        ctx.addPath(CGPath(ellipseIn: innerRect, transform: nil))
        ctx.clip()

        let bgColors = [cBgTop.cgColor, cBgBot.cgColor] as CFArray
        let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: bgColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(bgGrad,
                               start: CGPoint(x: 0, y: s),
                               end:   CGPoint(x: 0, y: 0),
                               options: [])

        drawSpeedLines(ctx, s: s)
        drawMapPin(ctx, s: s)
        drawGloss(ctx, in: innerRect)
        ctx.restoreGState()
    }

    return rep
}

// MARK: - tvOS icon (1280x768 — flat, since the legacy Contents.json uses it)

func renderTvIcon(width: Int, height: Int) -> NSBitmapImageRep {
    let w = CGFloat(width); let h = CGFloat(height)
    let rep = makeRep(width: width, height: height)

    draw(into: rep) { ctx in
        // Background (darker blue gradient)
        let bgColors = [cFrameInner.cgColor, cFrameOuter.cgColor] as CFArray
        let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: bgColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(bgGrad,
                               start: CGPoint(x: 0, y: h),
                               end:   CGPoint(x: 0, y: 0),
                               options: [])

        // Centered icon + wordmark area
        let s = h * 0.78
        let cx = w * 0.28
        let cy = h * 0.5
        let inner = CGRect(x: cx - s/2, y: cy - s/2, width: s, height: s)
        let r = s * 0.20
        let innerPath = CGPath(roundedRect: inner,
                               cornerWidth: r, cornerHeight: r, transform: nil)

        ctx.saveGState()
        ctx.addPath(innerPath); ctx.clip()
        let lightColors = [cBgTop.cgColor, cBgBot.cgColor] as CFArray
        let lightGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: lightColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(lightGrad,
                               start: CGPoint(x: 0, y: inner.maxY),
                               end:   CGPoint(x: 0, y: inner.minY),
                               options: [])
        ctx.translateBy(x: inner.minX, y: inner.minY)
        drawSpeedLines(ctx, s: s)
        drawMapPin(ctx, s: s)
        drawGloss(ctx, in: CGRect(x: 0, y: 0, width: s, height: s))
        ctx.restoreGState()

        // Wordmark to the right
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: h * 0.16, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ]
        let str = NSAttributedString(string: "MapMe", attributes: attrs)
        let textRect = CGRect(x: w * 0.56, y: cy - h * 0.10,
                              width: w * 0.42, height: h * 0.22)
        str.draw(in: textRect)
    }

    return rep
}

// MARK: - AppIcon plan

enum IconShape { case squircle, circle, tv }

struct AppIconEntry {
    let filename: String
    let pixelW: Int
    let pixelH: Int
    let shape: IconShape
    let json: [String: Any]
}

let appIconEntries: [AppIconEntry] = [
    AppIconEntry(filename: "icon-ios-1024.png", pixelW: 1024, pixelH: 1024, shape: .squircle,
                 json: ["filename": "icon-ios-1024.png", "idiom": "universal",
                        "platform": "ios", "size": "1024x1024"]),

    AppIconEntry(filename: "icon-mac-16.png",   pixelW: 16,  pixelH: 16, shape: .squircle,
                 json: ["filename": "icon-mac-16.png",   "idiom": "mac", "scale": "1x", "size": "16x16"]),
    AppIconEntry(filename: "icon-mac-16@2x.png", pixelW: 32,  pixelH: 32, shape: .squircle,
                 json: ["filename": "icon-mac-16@2x.png", "idiom": "mac", "scale": "2x", "size": "16x16"]),
    AppIconEntry(filename: "icon-mac-32.png",   pixelW: 32,  pixelH: 32, shape: .squircle,
                 json: ["filename": "icon-mac-32.png",   "idiom": "mac", "scale": "1x", "size": "32x32"]),
    AppIconEntry(filename: "icon-mac-32@2x.png", pixelW: 64,  pixelH: 64, shape: .squircle,
                 json: ["filename": "icon-mac-32@2x.png", "idiom": "mac", "scale": "2x", "size": "32x32"]),
    AppIconEntry(filename: "icon-mac-128.png",   pixelW: 128, pixelH: 128, shape: .squircle,
                 json: ["filename": "icon-mac-128.png",   "idiom": "mac", "scale": "1x", "size": "128x128"]),
    AppIconEntry(filename: "icon-mac-128@2x.png", pixelW: 256, pixelH: 256, shape: .squircle,
                 json: ["filename": "icon-mac-128@2x.png", "idiom": "mac", "scale": "2x", "size": "128x128"]),
    AppIconEntry(filename: "icon-mac-256.png",   pixelW: 256, pixelH: 256, shape: .squircle,
                 json: ["filename": "icon-mac-256.png",   "idiom": "mac", "scale": "1x", "size": "256x256"]),
    AppIconEntry(filename: "icon-mac-256@2x.png", pixelW: 512, pixelH: 512, shape: .squircle,
                 json: ["filename": "icon-mac-256@2x.png", "idiom": "mac", "scale": "2x", "size": "256x256"]),
    AppIconEntry(filename: "icon-mac-512.png",   pixelW: 512, pixelH: 512, shape: .squircle,
                 json: ["filename": "icon-mac-512.png",   "idiom": "mac", "scale": "1x", "size": "512x512"]),
    AppIconEntry(filename: "icon-mac-512@2x.png", pixelW: 1024, pixelH: 1024, shape: .squircle,
                 json: ["filename": "icon-mac-512@2x.png", "idiom": "mac", "scale": "2x", "size": "512x512"]),

    // tvOS lives in AppIcon.brandassets (layered for parallax) — see writeTvBrandAssets().
    // watchOS lives in MapMeWatch/Assets.xcassets — see writeWatchIcon().
]

// Watch app has its own asset catalog (MapMeWatch/Assets.xcassets) — the
// watchOS target's sources don't include MapMe/Assets.xcassets, so the watch
// icon must live in the watch catalog or it won't ship.
let watchIconFilename = "icon-watch-1024.png"

func writeAppIcons() {
    try! FileManager.default.createDirectory(at: appIconDir,
                                             withIntermediateDirectories: true)
    var contentsImages: [[String: Any]] = []

    for e in appIconEntries {
        print("  AppIcon \(e.filename) (\(e.pixelW)x\(e.pixelH))")
        let rep: NSBitmapImageRep
        switch e.shape {
        case .squircle: rep = renderAppIcon(size: e.pixelW)
        case .circle:   rep = renderWatchIcon(size: e.pixelW)
        case .tv:       rep = renderTvIcon(width: e.pixelW, height: e.pixelH)
        }
        savePNG(rep, to: appIconDir.appendingPathComponent(e.filename))
        contentsImages.append(e.json)
    }

    let contents: [String: Any] = [
        "images": contentsImages,
        "info": ["author": "xcode", "version": 1],
    ]
    let json = try! JSONSerialization.data(
        withJSONObject: contents,
        options: [.prettyPrinted, .sortedKeys])
    try! json.write(to: appIconDir.appendingPathComponent("Contents.json"))
}

// MARK: - Wordmark (launch / splash logotype — NOT the app icon)

// Frameless "MapMe" lockup: solid blue pin (no squircle, no bevel) next to
// a bold white wordmark. Designed to live on the dark splash background,
// not to be mistaken for the home-screen icon.
let wordmarkBlueTop  = NSColor(red: 0.30, green: 0.66, blue: 1.00, alpha: 1.0)
let wordmarkBlueBot  = NSColor(red: 0.10, green: 0.42, blue: 0.92, alpha: 1.0)

func renderWordmark(width: Int, height: Int, textColor: NSColor = .white) -> NSBitmapImageRep {
    let w = CGFloat(width); let h = CGFloat(height)
    let rep = makeRep(width: width, height: height)

    draw(into: rep) { ctx in
        // Layout: pin on the left, wordmark on the right, the *pair*
        // horizontally centred in the image. Earlier versions pinned
        // the pin to a fixed x of 0.18·w and the text to 0.28·w, which
        // left ~125 px of blank space on the right of a 480 px image
        // and only ~60 px on the left — when iOS UILaunchScreen
        // centred the bitmap on screen, the visible lockup sat
        // noticeably left of screen centre. Measuring the text first
        // and packing pin + gap + text as a unit lets the unit centre
        // on the image's true horizontal centre.
        let pinRadius = h * 0.20
        let pinWidth = 2 * pinRadius
        let gap = w * 0.04

        let fontSize = h * 0.48
        let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let descriptor = baseFont.fontDescriptor.withDesign(.rounded) ?? baseFont.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: fontSize) ?? baseFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .kern: fontSize * -0.015,
        ]
        let str = NSAttributedString(string: "MapMe", attributes: attrs)
        let stringSize = str.size()

        let lockupWidth = pinWidth + gap + stringSize.width
        let lockupLeft = (w - lockupWidth) / 2
        let pinCx = lockupLeft + pinRadius
        let textX = lockupLeft + pinWidth + gap

        let pinTipY = h * 0.5 - pinRadius * 1.45
        let pinPath = mapPinPath(cx: pinCx, tipY: pinTipY, headRadius: pinRadius)

        // Flat gradient pin (no drop shadow — logotype, not 3-D icon).
        ctx.saveGState()
        ctx.addPath(pinPath); ctx.clip()
        let pinColors = [wordmarkBlueTop.cgColor, wordmarkBlueBot.cgColor] as CFArray
        let pinGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: pinColors, locations: [0.0, 1.0])!
        let bbox = pinPath.boundingBox
        ctx.drawLinearGradient(pinGrad,
                               start: CGPoint(x: 0, y: bbox.maxY),
                               end:   CGPoint(x: 0, y: bbox.minY),
                               options: [])
        ctx.restoreGState()

        // White hole in the pin head.
        let headCY = pinTipY + 2.5 * pinRadius
        let holeR = pinRadius * 0.42
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: pinCx - holeR, y: headCY - holeR,
                                   width: 2*holeR, height: 2*holeR))

        // Wordmark text — SF Rounded Bold in white.
        let textY = (h - stringSize.height) / 2
        str.draw(at: NSPoint(x: textX, y: textY))
    }
    return rep
}

// Writes an MMLogo-style wordmark imageset (universal 1x/2x/3x).
//
// `MMLogo` (white text) is referenced by Info-iOS.plist UILaunchScreen
// and used wherever the wordmark sits on a dark/branded background
// (SplashView fallback, dark-mode nav bars, lock screen on dark
// material). The in-app SplashView draws the same shape directly in
// SwiftUI so we don't pixel-double on the launch→splash seam.
//
// `MMLogoLight` (black text) is the companion for white / light-mode
// backgrounds — light-mode navigation bars, the on-light-material
// status pill on LiveMapView, etc. Picked at runtime by the
// `MapMeBrandImage` SwiftUI helper based on `@Environment(\.colorScheme)`.
func writeMMLogo(
    into root: URL,
    assetName: String = "MMLogo",
    textColor: NSColor = .white,
    baseWidth: Int = 480,
    baseHeight: Int = 144
) {
    let dir = root.appendingPathComponent("\(assetName).imageset")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var images: [[String: Any]] = []
    for scale in [1, 2, 3] {
        let fn = scale == 1 ? "logo@1x.png" : "logo@\(scale)x.png"
        let rep = renderWordmark(
            width: baseWidth * scale,
            height: baseHeight * scale,
            textColor: textColor
        )
        savePNG(rep, to: dir.appendingPathComponent(fn))
        images.append(["filename": fn, "idiom": "universal", "scale": "\(scale)x"])
        print("  \(assetName) \(root.lastPathComponent)/\(fn)")
    }
    writeJSON([
        "images": images,
        "info": ["author": "xcode", "version": 1],
    ], to: dir.appendingPathComponent("Contents.json"))
}

// Square pin-only brand mark for toolbar / nav-bar use. The wordmark
// MMLogo doesn't scale down well into small square slots (the text becomes
// illegible); this stays readable at 24 pt and reads as a proper icon at
// 40–96 pt where iOS and tvOS use it.
//
// Geometry note: `mapPinPath` lays the pin's tip at `tipY` and centres
// the head at `tipY + 2.5 * r`, so the top of the head lands at
// `tipY + 3.5 * r`. Earlier values (`r = 0.32 s`, `tipY = 0.10 s`)
// pushed the top of the head to `1.22 s` — 22 % past the image's top
// edge — and the PNG saved with the pin head literally clipped (you
// could see the white head-hole rendered as a half-circle on tvOS).
// The values below leave ~6 % margin top and bottom so the design is
// fully contained inside the image bounds.
func renderBrandMark(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = makeRep(width: size, height: size)
    draw(into: rep) { ctx in
        // Pin centred horizontally, fully contained vertically:
        //   tipY = 0.06 s, r = 0.25 s
        //   → top of head = 0.06 s + 3.5 * 0.25 s = 0.935 s (6.5 % margin)
        let r = s * 0.25
        let cx = s * 0.5
        let tipY = s * 0.06
        let pinPath = mapPinPath(cx: cx, tipY: tipY, headRadius: r)

        // Body gradient (top → bottom darker).
        ctx.saveGState()
        ctx.addPath(pinPath); ctx.clip()
        let pinColors = [wordmarkBlueTop.cgColor, wordmarkBlueBot.cgColor] as CFArray
        let pinGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: pinColors, locations: [0.0, 1.0])!
        let bbox = pinPath.boundingBox
        ctx.drawLinearGradient(pinGrad,
                               start: CGPoint(x: 0, y: bbox.maxY),
                               end:   CGPoint(x: 0, y: bbox.minY),
                               options: [])
        ctx.restoreGState()

        // White hole in the head.
        let headCY = tipY + 2.5 * r
        let holeR = r * 0.42
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - holeR, y: headCY - holeR,
                                   width: 2*holeR, height: 2*holeR))
    }
    return rep
}

func writeBrandMark(into root: URL, basePixels: Int = 96) {
    let dir = root.appendingPathComponent("MMBrandMark.imageset")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var images: [[String: Any]] = []
    for scale in [1, 2, 3] {
        let fn = scale == 1 ? "brand@1x.png" : "brand@\(scale)x.png"
        let rep = renderBrandMark(size: basePixels * scale)
        savePNG(rep, to: dir.appendingPathComponent(fn))
        images.append(["filename": fn, "idiom": "universal", "scale": "\(scale)x"])
        print("  BrandMark \(root.lastPathComponent)/\(fn) (\(basePixels * scale)px)")
    }
    writeJSON([
        "images": images,
        "info": ["author": "xcode", "version": 1],
    ], to: dir.appendingPathComponent("Contents.json"))
}

// Dark navy splash background — referenced by Info.plist UILaunchScreen
// (UIColorName) and by SplashView (Color("MMSplashBackground")).
func writeSplashBackgroundColor(into root: URL) {
    let dir = root.appendingPathComponent("MMSplashBackground.colorset")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let color: [String: Any] = [
        "color-space": "srgb",
        "components": [
            "alpha": "1.000",
            "red":   "0.040",
            "green": "0.160",
            "blue":  "0.360",
        ],
    ]
    writeJSON([
        "colors": [["color": color, "idiom": "universal"]],
        "info": ["author": "xcode", "version": 1],
    ], to: dir.appendingPathComponent("Contents.json"))
    print("  SplashBg \(root.lastPathComponent)")
}

// MARK: - tvOS Brand Assets (layered for Home Screen parallax)

// Each layer is a transparent PNG composited by tvOS at runtime. The system
// applies the rounded mask, so layers should fill the full rectangle.

func tvLayoutInnerRect(w: CGFloat, h: CGFloat) -> CGRect {
    let s = h * 0.78
    let cx = w * 0.28
    let cy = h * 0.5
    return CGRect(x: cx - s/2, y: cy - s/2, width: s, height: s)
}

func renderTvBack(width: Int, height: Int) -> NSBitmapImageRep {
    let w = CGFloat(width); let h = CGFloat(height)
    let rep = makeRep(width: width, height: height)
    draw(into: rep) { ctx in
        let bgColors = [cFrameInner.cgColor, cFrameOuter.cgColor] as CFArray
        let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: bgColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(bgGrad,
                               start: CGPoint(x: 0, y: h),
                               end:   CGPoint(x: 0, y: 0),
                               options: [])
    }
    return rep
}

func renderTvMiddle(width: Int, height: Int) -> NSBitmapImageRep {
    let w = CGFloat(width); let h = CGFloat(height)
    let rep = makeRep(width: width, height: height)
    draw(into: rep) { ctx in
        let inner = tvLayoutInnerRect(w: w, h: h)
        let r = inner.width * 0.20
        let innerPath = CGPath(roundedRect: inner,
                               cornerWidth: r, cornerHeight: r,
                               transform: nil)

        // Light squircle card + speed lines (no pin)
        ctx.saveGState()
        ctx.addPath(innerPath); ctx.clip()
        let lightColors = [cBgTop.cgColor, cBgBot.cgColor] as CFArray
        let lightGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: lightColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(lightGrad,
                               start: CGPoint(x: 0, y: inner.maxY),
                               end:   CGPoint(x: 0, y: inner.minY),
                               options: [])
        ctx.translateBy(x: inner.minX, y: inner.minY)
        drawSpeedLines(ctx, s: inner.width)
        ctx.restoreGState()

        // Wordmark on the right
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: h * 0.16, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ]
        let str = NSAttributedString(string: "MapMe", attributes: attrs)
        let textRect = CGRect(x: w * 0.56, y: h * 0.5 - h * 0.10,
                              width: w * 0.42, height: h * 0.22)
        str.draw(in: textRect)
    }
    return rep
}

func renderTvFront(width: Int, height: Int) -> NSBitmapImageRep {
    let w = CGFloat(width); let h = CGFloat(height)
    let rep = makeRep(width: width, height: height)
    draw(into: rep) { ctx in
        let inner = tvLayoutInnerRect(w: w, h: h)
        ctx.translateBy(x: inner.minX, y: inner.minY)
        drawMapPin(ctx, s: inner.width)
    }
    return rep
}

func renderTopShelf(width: Int, height: Int) -> NSBitmapImageRep {
    let w = CGFloat(width); let h = CGFloat(height)
    let rep = makeRep(width: width, height: height)
    draw(into: rep) { ctx in
        // Background
        let bgColors = [cFrameInner.cgColor, cFrameOuter.cgColor] as CFArray
        let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: bgColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(bgGrad,
                               start: CGPoint(x: 0, y: h),
                               end:   CGPoint(x: 0, y: 0),
                               options: [])
        // Light card + content + wordmark
        let inner = tvLayoutInnerRect(w: w, h: h)
        let r = inner.width * 0.20
        let innerPath = CGPath(roundedRect: inner,
                               cornerWidth: r, cornerHeight: r,
                               transform: nil)
        ctx.saveGState()
        ctx.addPath(innerPath); ctx.clip()
        let lightColors = [cBgTop.cgColor, cBgBot.cgColor] as CFArray
        let lightGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: lightColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(lightGrad,
                               start: CGPoint(x: 0, y: inner.maxY),
                               end:   CGPoint(x: 0, y: inner.minY),
                               options: [])
        ctx.translateBy(x: inner.minX, y: inner.minY)
        drawSpeedLines(ctx, s: inner.width)
        drawMapPin(ctx, s: inner.width)
        drawGloss(ctx, in: CGRect(x: 0, y: 0,
                                  width: inner.width, height: inner.height))
        ctx.restoreGState()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: h * 0.18, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: "MapMe", attributes: attrs)
        let textRect = CGRect(x: w * 0.50, y: h * 0.5 - h * 0.12,
                              width: w * 0.48, height: h * 0.24)
        str.draw(in: textRect)
    }
    return rep
}

let tvBrandAssetsDir = assetsRoot.appendingPathComponent("AppIcon.brandassets")

func writeJSON(_ obj: [String: Any], to url: URL) {
    let data = try! JSONSerialization.data(
        withJSONObject: obj,
        options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

func writeTvBrandAssets() {
    // Wipe and recreate the brandassets bundle so deleted layers don't linger.
    try? FileManager.default.removeItem(at: tvBrandAssetsDir)
    try! FileManager.default.createDirectory(at: tvBrandAssetsDir,
                                             withIntermediateDirectories: true)

    func writeImagestack(name: String, width: Int, height: Int, suffix: String) {
        let stackDir = tvBrandAssetsDir.appendingPathComponent("\(name).imagestack")
        try! FileManager.default.createDirectory(at: stackDir,
                                                 withIntermediateDirectories: true)
        let layers: [(String, NSBitmapImageRep, String)] = [
            ("Front",  renderTvFront(width: width, height: height),  "front-\(suffix).png"),
            ("Middle", renderTvMiddle(width: width, height: height), "middle-\(suffix).png"),
            ("Back",   renderTvBack(width: width, height: height),   "back-\(suffix).png"),
        ]
        for (layerName, rep, fn) in layers {
            let layerDir = stackDir.appendingPathComponent("\(layerName).imagestacklayer")
            let imgsetDir = layerDir.appendingPathComponent("Content.imageset")
            try! FileManager.default.createDirectory(at: imgsetDir,
                                                     withIntermediateDirectories: true)
            savePNG(rep, to: imgsetDir.appendingPathComponent(fn))
            writeJSON([
                "images": [["filename": fn, "idiom": "tv", "scale": "1x"]],
                "info": ["author": "xcode", "version": 1],
            ], to: imgsetDir.appendingPathComponent("Contents.json"))
            writeJSON([
                "info": ["author": "xcode", "version": 1],
                "properties": [String: Any](),
            ], to: layerDir.appendingPathComponent("Contents.json"))
            print("  TvBrandAsset \(name)/\(layerName) (\(width)x\(height))")
        }
        writeJSON([
            "layers": [
                ["filename": "Front.imagestacklayer"],
                ["filename": "Middle.imagestacklayer"],
                ["filename": "Back.imagestacklayer"],
            ],
            "info": ["author": "xcode", "version": 1],
        ], to: stackDir.appendingPathComponent("Contents.json"))
    }

    writeImagestack(name: "App Icon - App Store", width: 1280, height: 768, suffix: "large")
    writeImagestack(name: "App Icon",             width: 400,  height: 240, suffix: "small")

    // Top Shelf
    let topShelfDir = tvBrandAssetsDir.appendingPathComponent("Top Shelf Image.imageset")
    try! FileManager.default.createDirectory(at: topShelfDir,
                                             withIntermediateDirectories: true)
    savePNG(renderTopShelf(width: 1920, height: 720),
            to: topShelfDir.appendingPathComponent("top-shelf.png"))
    writeJSON([
        "images": [["filename": "top-shelf.png", "idiom": "tv", "scale": "1x"]],
        "info": ["author": "xcode", "version": 1],
    ], to: topShelfDir.appendingPathComponent("Contents.json"))
    print("  TopShelf 1920x720")

    // Brand assets root
    writeJSON([
        "assets": [
            ["filename": "App Icon - App Store.imagestack",
             "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
            ["filename": "App Icon.imagestack",
             "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
            ["filename": "Top Shelf Image.imageset",
             "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
        ],
        "info": ["author": "xcode", "version": 1],
    ], to: tvBrandAssetsDir.appendingPathComponent("Contents.json"))
}

// MARK: - watchOS app icon (separate catalog)

func writeWatchIcon() {
    try! FileManager.default.createDirectory(at: watchAppIconDir,
                                             withIntermediateDirectories: true)
    let rep = renderWatchIcon(size: 1024)
    savePNG(rep, to: watchAppIconDir.appendingPathComponent(watchIconFilename))
    print("  WatchAppIcon \(watchIconFilename) (1024x1024)")

    let contents: [String: Any] = [
        "images": [[
            "filename": watchIconFilename,
            "idiom": "universal",
            "platform": "watchos",
            "size": "1024x1024",
        ]],
        "info": ["author": "xcode", "version": 1],
    ]
    let json = try! JSONSerialization.data(
        withJSONObject: contents,
        options: [.prettyPrinted, .sortedKeys])
    try! json.write(to: watchAppIconDir.appendingPathComponent("Contents.json"))
}

// MARK: - Toolbar imagesets

struct ToolbarIcon {
    let imagesetName: String      // folder name (without .imageset)
    let baseFile: String          // png basename (without @Nx suffix)
    let symbol: String            // SF Symbol name
    let weight: NSFont.Weight
    let coverage: CGFloat         // symbol pointSize / canvas size
}

let toolbarIcons: [ToolbarIcon] = [
    ToolbarIcon(imagesetName: "MM.Map",      baseFile: "map",      symbol: "map.fill",            weight: .semibold, coverage: 0.78),
    ToolbarIcon(imagesetName: "MM.History",  baseFile: "history",  symbol: "list.bullet",         weight: .bold,     coverage: 0.78),
    ToolbarIcon(imagesetName: "MM.Lock",     baseFile: "lock",     symbol: "lock.fill",           weight: .semibold, coverage: 0.78),
    ToolbarIcon(imagesetName: "MM.Settings", baseFile: "settings", symbol: "gearshape.fill",      weight: .semibold, coverage: 0.82),
    ToolbarIcon(imagesetName: "MM.Pairing",  baseFile: "pairing",  symbol: "link",                weight: .bold,     coverage: 0.72),
    ToolbarIcon(imagesetName: "MM.Family",   baseFile: "family",   symbol: "person.2.fill",       weight: .semibold, coverage: 0.82),
    ToolbarIcon(imagesetName: "MM.Pin",      baseFile: "pin",      symbol: "mappin.and.ellipse",  weight: .semibold, coverage: 0.78),
    ToolbarIcon(imagesetName: "MM.History.Day", baseFile: "day",   symbol: "calendar",            weight: .semibold, coverage: 0.78),
]

let toolbarBaseSize = 28  // @1x pixels

func renderToolbar(symbol: String, pixelSize: Int, weight: NSFont.Weight,
                   coverage: CGFloat, color: NSColor) -> NSBitmapImageRep
{
    let s = CGFloat(pixelSize)
    let rep = makeRep(width: pixelSize, height: pixelSize)

    draw(into: rep) { _ in
        let cfg = NSImage.SymbolConfiguration(pointSize: s * coverage,
                                              weight: weight)
        guard let raw = NSImage(systemSymbolName: symbol,
                                accessibilityDescription: nil) else { return }
        guard let sym = raw.withSymbolConfiguration(cfg) else { return }

        let drawSize = sym.size
        let r = NSRect(x: (s - drawSize.width)/2,
                       y: (s - drawSize.height)/2,
                       width: drawSize.width,
                       height: drawSize.height)
        sym.draw(in: r)

        color.set()
        NSRect(x: 0, y: 0, width: s, height: s).fill(using: .sourceAtop)
    }
    return rep
}

func writeToolbarIcons() {
    for icon in toolbarIcons {
        let dir = assetsRoot.appendingPathComponent("\(icon.imagesetName).imageset")
        try! FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        var images: [[String: Any]] = []
        for scale in [1, 2, 3] {
            let fn = scale == 1
                ? "\(icon.baseFile).png"
                : "\(icon.baseFile)@\(scale)x.png"
            let pixelSize = toolbarBaseSize * scale
            let rep = renderToolbar(symbol: icon.symbol,
                                    pixelSize: pixelSize,
                                    weight: icon.weight,
                                    coverage: icon.coverage,
                                    color: cToolbar)
            savePNG(rep, to: dir.appendingPathComponent(fn))
            images.append([
                "filename": fn,
                "idiom": "universal",
                "scale": "\(scale)x",
            ])
            print("  Toolbar \(icon.imagesetName)/\(fn) (\(pixelSize)x\(pixelSize))")
        }
        let contents: [String: Any] = [
            "images": images,
            "info": ["author": "xcode", "version": 1],
        ]
        let json = try! JSONSerialization.data(
            withJSONObject: contents,
            options: [.prettyPrinted, .sortedKeys])
        try! json.write(to: dir.appendingPathComponent("Contents.json"))
    }
}

// MARK: - Preview

func renderPreview() {
    let cell: CGFloat = 200
    let pad: CGFloat = 24
    let cols = 4
    let toolbarCount = toolbarIcons.count
    let rowsForApp = 1
    let rowsForToolbar = (toolbarCount + cols - 1) / cols
    let rows = rowsForApp + rowsForToolbar
    let w = Int(CGFloat(cols) * cell + CGFloat(cols + 1) * pad)
    let h = Int(CGFloat(rows) * cell + CGFloat(rows + 1) * pad + 60)

    let rep = makeRep(width: w, height: h)
    draw(into: rep) { _ in
        NSColor(white: 0.18, alpha: 1.0).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()

        // Caption
        let caption = NSAttributedString(string: "MapMe icons (preview)", attributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        caption.draw(at: NSPoint(x: pad, y: CGFloat(h) - 44))

        // App icon at first slot, watch icon at second slot
        let appRep = renderAppIcon(size: Int(cell))
        let appImg = NSImage(cgImage: appRep.cgImage!,
                             size: NSSize(width: cell, height: cell))
        var x = pad
        var y = CGFloat(h) - 60 - cell - pad
        appImg.draw(in: NSRect(x: x, y: y, width: cell, height: cell))

        let watchRep = renderWatchIcon(size: Int(cell))
        let watchImg = NSImage(cgImage: watchRep.cgImage!,
                               size: NSSize(width: cell, height: cell))
        watchImg.draw(in: NSRect(x: x + cell + pad, y: y, width: cell, height: cell))

        // Toolbar icons grid
        x = pad
        y -= cell + pad
        var col = 0
        for ic in toolbarIcons {
            let r = renderToolbar(symbol: ic.symbol,
                                  pixelSize: Int(cell * 0.7),
                                  weight: ic.weight,
                                  coverage: ic.coverage,
                                  color: cToolbar)
            let img = NSImage(cgImage: r.cgImage!,
                              size: NSSize(width: cell * 0.7,
                                           height: cell * 0.7))
            // White square card behind toolbar icon for contrast
            NSColor(white: 0.95, alpha: 1.0).setFill()
            NSRect(x: x, y: y, width: cell, height: cell).fill()
            img.draw(in: NSRect(x: x + cell * 0.15, y: y + cell * 0.15,
                                width: cell * 0.7, height: cell * 0.7))

            // Label
            let label = NSAttributedString(string: ic.imagesetName, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.darkGray,
            ])
            label.draw(at: NSPoint(x: x + 6, y: y + 4))

            col += 1
            x += cell + pad
            if col == cols {
                col = 0
                x = pad
                y -= cell + pad
            }
        }
    }
    savePNG(rep, to: previewURL)
    print("  Preview \(previewURL.path)")
}

func renderTvComposite() {
    let url = URL(fileURLWithPath:
        "/Users/denisarsenault/Developer/MapMe/Tools/tv_composite_preview.png")
    let w = 1280, h = 768
    let rep = makeRep(width: w, height: h)
    draw(into: rep) { _ in
        let backRep = renderTvBack(width: w, height: h)
        let midRep  = renderTvMiddle(width: w, height: h)
        let frontRep = renderTvFront(width: w, height: h)
        let r = NSRect(x: 0, y: 0, width: w, height: h)
        NSImage(cgImage: backRep.cgImage!,
                size: NSSize(width: w, height: h)).draw(in: r)
        NSImage(cgImage: midRep.cgImage!,
                size: NSSize(width: w, height: h)).draw(in: r)
        NSImage(cgImage: frontRep.cgImage!,
                size: NSSize(width: w, height: h)).draw(in: r)
    }
    savePNG(rep, to: url)
    print("  TvComposite \(url.path)")
}

// MARK: - Main

_ = NSApplication.shared

// `--brand-only` regenerates ONLY MMBrandMark. Useful when fixing the
// brand-mark geometry without re-rendering the other carefully-tuned
// assets (e.g. the App Store 1024 icon, which has been flattened to
// strip its alpha channel and would lose that flattening on a full
// regenerate). Exits early after writing the brand mark.
if CommandLine.arguments.contains("--brand-only") {
    print("MMBrandMark only:")
    writeBrandMark(into: assetsRoot)
    exit(0)
}

print("Rendering MapMe icons →")
print("AppIcon set:")
writeAppIcons()
print("tvOS Brand Assets:")
writeTvBrandAssets()
print("Watch AppIcon:")
writeWatchIcon()
print("Toolbar imagesets:")
writeToolbarIcons()
print("MMLogo (wordmark) + splash colour + brand mark:")
writeMMLogo(into: assetsRoot)
writeMMLogo(into: watchAssetsRoot, baseWidth: 180, baseHeight: 54)
// Black-text companion for white / light-mode backgrounds. Same
// geometry as MMLogo; only the text colour differs. Watch app stays
// dark-only (its window chrome is always black), so we skip the
// MMLogoLight write there to keep the bundle smaller.
writeMMLogo(into: assetsRoot, assetName: "MMLogoLight", textColor: .black)
writeSplashBackgroundColor(into: assetsRoot)
writeSplashBackgroundColor(into: watchAssetsRoot)
writeBrandMark(into: assetsRoot)
print("Preview:")
renderPreview()
renderTvComposite()
print("Done.")
