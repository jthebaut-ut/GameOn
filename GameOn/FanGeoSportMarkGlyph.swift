import SwiftUI

/// Custom vector silhouettes for official FanGeo sport marks.
/// Drawn in unit space and scaled to the mark. Never emoji. Never SF Symbols.
struct FanGeoSportMarkGlyph: Shape {
    var kind: FanGeoSportMarkKind

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
        var path = Path()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * s, y: origin.y + y * s)
        }
        func addCircle(cx: CGFloat, cy: CGFloat, r: CGFloat) {
            path.addEllipse(in: CGRect(
                x: origin.x + (cx - r) * s,
                y: origin.y + (cy - r) * s,
                width: r * 2 * s,
                height: r * 2 * s
            ))
        }
        func addOval(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) {
            path.addEllipse(in: CGRect(
                x: origin.x + (cx - rx) * s,
                y: origin.y + (cy - ry) * s,
                width: rx * 2 * s,
                height: ry * 2 * s
            ))
        }
        func addRoundedRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, cr: CGFloat) {
            path.addRoundedRect(
                in: CGRect(x: origin.x + x * s, y: origin.y + y * s, width: w * s, height: h * s),
                cornerSize: CGSize(width: cr * s, height: cr * s)
            )
        }

        switch kind {
        case .soccer:
            addCircle(cx: 0.50, cy: 0.50, r: 0.28)
            addCircle(cx: 0.50, cy: 0.50, r: 0.09)
            path.move(to: p(0.50, 0.22))
            path.addLine(to: p(0.42, 0.42))
            path.addLine(to: p(0.58, 0.42))
            path.closeSubpath()
            path.move(to: p(0.28, 0.38))
            path.addLine(to: p(0.42, 0.42))
            path.move(to: p(0.72, 0.38))
            path.addLine(to: p(0.58, 0.42))
            path.move(to: p(0.42, 0.42))
            path.addLine(to: p(0.36, 0.62))
            path.move(to: p(0.58, 0.42))
            path.addLine(to: p(0.64, 0.62))
            path.move(to: p(0.36, 0.62))
            path.addLine(to: p(0.50, 0.74))
            path.addLine(to: p(0.64, 0.62))

        case .basketball:
            addCircle(cx: 0.50, cy: 0.50, r: 0.28)
            path.move(to: p(0.50, 0.22))
            path.addLine(to: p(0.50, 0.78))
            path.move(to: p(0.22, 0.50))
            path.addLine(to: p(0.78, 0.50))
            path.move(to: p(0.32, 0.24))
            path.addQuadCurve(to: p(0.32, 0.76), control: p(0.46, 0.50))
            path.move(to: p(0.68, 0.24))
            path.addQuadCurve(to: p(0.68, 0.76), control: p(0.54, 0.50))

        case .football:
            addOval(cx: 0.50, cy: 0.50, rx: 0.32, ry: 0.18)
            path.move(to: p(0.38, 0.50))
            path.addLine(to: p(0.62, 0.50))
            path.move(to: p(0.42, 0.44))
            path.addLine(to: p(0.42, 0.56))
            path.move(to: p(0.50, 0.44))
            path.addLine(to: p(0.50, 0.56))
            path.move(to: p(0.58, 0.44))
            path.addLine(to: p(0.58, 0.56))
            path.move(to: p(0.22, 0.42))
            path.addQuadCurve(to: p(0.22, 0.58), control: p(0.18, 0.50))
            path.move(to: p(0.78, 0.42))
            path.addQuadCurve(to: p(0.78, 0.58), control: p(0.82, 0.50))

        case .baseball, .softball:
            addCircle(cx: 0.50, cy: 0.50, r: 0.27)
            path.move(to: p(0.28, 0.28))
            path.addQuadCurve(to: p(0.28, 0.72), control: p(0.42, 0.50))
            path.move(to: p(0.72, 0.28))
            path.addQuadCurve(to: p(0.72, 0.72), control: p(0.58, 0.50))

        case .hockey:
            addRoundedRect(x: 0.18, y: 0.22, w: 0.10, h: 0.48, cr: 0.04)
            addRoundedRect(x: 0.72, y: 0.22, w: 0.10, h: 0.48, cr: 0.04)
            addRoundedRect(x: 0.12, y: 0.62, w: 0.22, h: 0.10, cr: 0.04)
            addRoundedRect(x: 0.66, y: 0.62, w: 0.22, h: 0.10, cr: 0.04)
            addOval(cx: 0.50, cy: 0.50, rx: 0.12, ry: 0.08)

        case .tennis, .volleyball:
            addCircle(cx: 0.50, cy: 0.50, r: 0.27)
            if kind == .tennis {
                path.move(to: p(0.30, 0.26))
                path.addQuadCurve(to: p(0.30, 0.74), control: p(0.48, 0.50))
                path.move(to: p(0.70, 0.26))
                path.addQuadCurve(to: p(0.70, 0.74), control: p(0.52, 0.50))
            } else {
                path.move(to: p(0.28, 0.38))
                path.addQuadCurve(to: p(0.72, 0.38), control: p(0.50, 0.22))
                path.move(to: p(0.28, 0.62))
                path.addQuadCurve(to: p(0.72, 0.62), control: p(0.50, 0.78))
                path.move(to: p(0.38, 0.28))
                path.addQuadCurve(to: p(0.38, 0.72), control: p(0.22, 0.50))
                path.move(to: p(0.62, 0.28))
                path.addQuadCurve(to: p(0.62, 0.72), control: p(0.78, 0.50))
            }

        case .badminton:
            addOval(cx: 0.50, cy: 0.72, rx: 0.10, ry: 0.08)
            path.move(to: p(0.50, 0.64))
            path.addLine(to: p(0.22, 0.22))
            path.addLine(to: p(0.34, 0.26))
            path.closeSubpath()
            path.move(to: p(0.50, 0.64))
            path.addLine(to: p(0.38, 0.18))
            path.addLine(to: p(0.46, 0.24))
            path.closeSubpath()
            path.move(to: p(0.50, 0.64))
            path.addLine(to: p(0.50, 0.16))
            path.addLine(to: p(0.56, 0.24))
            path.closeSubpath()
            path.move(to: p(0.50, 0.64))
            path.addLine(to: p(0.62, 0.18))
            path.addLine(to: p(0.54, 0.24))
            path.closeSubpath()
            path.move(to: p(0.50, 0.64))
            path.addLine(to: p(0.78, 0.22))
            path.addLine(to: p(0.66, 0.26))
            path.closeSubpath()

        case .golf:
            addRoundedRect(x: 0.46, y: 0.18, w: 0.06, h: 0.52, cr: 0.03)
            path.move(to: p(0.52, 0.18))
            path.addLine(to: p(0.78, 0.32))
            path.addLine(to: p(0.52, 0.40))
            path.closeSubpath()
            addOval(cx: 0.50, cy: 0.74, rx: 0.16, ry: 0.06)

        case .tableTennis, .pickleball, .padel:
            addRoundedRect(x: 0.46, y: 0.58, w: 0.08, h: 0.22, cr: 0.04)
            let bladeH: CGFloat = kind == .padel ? 0.36 : 0.34
            addOval(cx: 0.50, cy: 0.40, rx: kind == .padel ? 0.18 : 0.16, ry: bladeH / 2)
            if kind != .padel {
                addCircle(cx: 0.72, cy: 0.28, r: 0.08)
            } else {
                path.move(to: p(0.42, 0.30))
                path.addLine(to: p(0.58, 0.50))
                path.move(to: p(0.58, 0.30))
                path.addLine(to: p(0.42, 0.50))
            }

        case .cricket:
            addRoundedRect(x: 0.28, y: 0.18, w: 0.10, h: 0.56, cr: 0.05)
            addRoundedRect(x: 0.22, y: 0.16, w: 0.22, h: 0.10, cr: 0.04)
            addCircle(cx: 0.66, cy: 0.58, r: 0.12)

        case .rugby:
            addOval(cx: 0.50, cy: 0.50, rx: 0.30, ry: 0.18)
            path.move(to: p(0.36, 0.50))
            path.addLine(to: p(0.64, 0.50))
            path.move(to: p(0.42, 0.42))
            path.addLine(to: p(0.42, 0.58))
            path.move(to: p(0.50, 0.42))
            path.addLine(to: p(0.50, 0.58))
            path.move(to: p(0.58, 0.42))
            path.addLine(to: p(0.58, 0.58))

        case .lacrosse:
            addRoundedRect(x: 0.46, y: 0.42, w: 0.08, h: 0.38, cr: 0.04)
            addOval(cx: 0.50, cy: 0.32, rx: 0.16, ry: 0.18)
            path.move(to: p(0.40, 0.24))
            path.addLine(to: p(0.60, 0.40))
            path.move(to: p(0.60, 0.24))
            path.addLine(to: p(0.40, 0.40))

        case .handball:
            addCircle(cx: 0.50, cy: 0.50, r: 0.26)
            path.move(to: p(0.34, 0.32))
            path.addQuadCurve(to: p(0.66, 0.32), control: p(0.50, 0.18))
            path.move(to: p(0.32, 0.50))
            path.addQuadCurve(to: p(0.68, 0.50), control: p(0.50, 0.40))

        case .running, .trackField:
            addCircle(cx: 0.58, cy: 0.22, r: 0.08)
            path.move(to: p(0.56, 0.30))
            path.addLine(to: p(0.48, 0.50))
            path.addLine(to: p(0.62, 0.50))
            path.addLine(to: p(0.70, 0.72))
            path.move(to: p(0.48, 0.50))
            path.addLine(to: p(0.32, 0.68))
            path.move(to: p(0.56, 0.30))
            path.addLine(to: p(0.32, 0.38))
            path.move(to: p(0.56, 0.30))
            path.addLine(to: p(0.74, 0.42))
            if kind == .trackField {
                path.move(to: p(0.22, 0.78))
                path.addLine(to: p(0.78, 0.78))
            }

        case .cycling, .roadCycling, .mountainBike:
            addCircle(cx: 0.30, cy: 0.62, r: kind == .mountainBike ? 0.16 : 0.14)
            addCircle(cx: 0.70, cy: 0.62, r: kind == .mountainBike ? 0.16 : 0.14)
            path.move(to: p(0.30, 0.62))
            path.addLine(to: p(0.48, 0.38))
            path.addLine(to: p(0.70, 0.62))
            path.move(to: p(0.48, 0.38))
            path.addLine(to: p(0.58, 0.28))
            path.move(to: p(0.48, 0.38))
            path.addLine(to: p(0.38, 0.30))
            if kind == .mountainBike {
                addRoundedRect(x: 0.20, y: 0.74, w: 0.20, h: 0.05, cr: 0.02)
                addRoundedRect(x: 0.60, y: 0.74, w: 0.20, h: 0.05, cr: 0.02)
            }

        case .swimming:
            path.move(to: p(0.22, 0.62))
            path.addQuadCurve(to: p(0.50, 0.58), control: p(0.36, 0.50))
            path.addQuadCurve(to: p(0.78, 0.64), control: p(0.64, 0.72))
            path.move(to: p(0.22, 0.72))
            path.addQuadCurve(to: p(0.50, 0.68), control: p(0.36, 0.60))
            path.addQuadCurve(to: p(0.78, 0.74), control: p(0.64, 0.82))
            addCircle(cx: 0.62, cy: 0.32, r: 0.07)
            path.move(to: p(0.56, 0.38))
            path.addLine(to: p(0.42, 0.52))
            path.move(to: p(0.56, 0.38))
            path.addLine(to: p(0.78, 0.46))

        case .triathlon:
            addCircle(cx: 0.32, cy: 0.32, r: 0.12)
            addCircle(cx: 0.68, cy: 0.32, r: 0.12)
            addCircle(cx: 0.50, cy: 0.64, r: 0.12)

        case .climbing:
            addCircle(cx: 0.46, cy: 0.22, r: 0.07)
            path.move(to: p(0.46, 0.30))
            path.addLine(to: p(0.50, 0.52))
            path.addLine(to: p(0.38, 0.78))
            path.move(to: p(0.50, 0.52))
            path.addLine(to: p(0.64, 0.72))
            path.move(to: p(0.46, 0.30))
            path.addLine(to: p(0.28, 0.40))
            path.move(to: p(0.46, 0.30))
            path.addLine(to: p(0.68, 0.26))
            addRoundedRect(x: 0.70, y: 0.18, w: 0.10, h: 0.10, cr: 0.02)
            addRoundedRect(x: 0.74, y: 0.48, w: 0.10, h: 0.10, cr: 0.02)

        case .skateboarding:
            addRoundedRect(x: 0.16, y: 0.58, w: 0.68, h: 0.10, cr: 0.05)
            addCircle(cx: 0.30, cy: 0.74, r: 0.06)
            addCircle(cx: 0.70, cy: 0.74, r: 0.06)
            addCircle(cx: 0.46, cy: 0.28, r: 0.07)
            path.move(to: p(0.46, 0.36))
            path.addLine(to: p(0.50, 0.56))
            path.move(to: p(0.46, 0.36))
            path.addLine(to: p(0.32, 0.48))

        case .inlineSkating:
            addRoundedRect(x: 0.32, y: 0.28, w: 0.36, h: 0.28, cr: 0.08)
            addCircle(cx: 0.34, cy: 0.68, r: 0.06)
            addCircle(cx: 0.46, cy: 0.70, r: 0.06)
            addCircle(cx: 0.58, cy: 0.70, r: 0.06)
            addCircle(cx: 0.70, cy: 0.68, r: 0.06)

        case .electricScooter:
            addCircle(cx: 0.28, cy: 0.70, r: 0.10)
            addCircle(cx: 0.72, cy: 0.70, r: 0.10)
            path.move(to: p(0.28, 0.70))
            path.addLine(to: p(0.72, 0.70))
            path.addLine(to: p(0.62, 0.28))
            path.addLine(to: p(0.48, 0.28))

        case .skiing:
            addRoundedRect(x: 0.22, y: 0.70, w: 0.56, h: 0.07, cr: 0.03)
            addCircle(cx: 0.48, cy: 0.22, r: 0.07)
            path.move(to: p(0.48, 0.30))
            path.addLine(to: p(0.50, 0.52))
            path.addLine(to: p(0.42, 0.70))
            path.move(to: p(0.50, 0.52))
            path.addLine(to: p(0.62, 0.70))
            path.move(to: p(0.48, 0.30))
            path.addLine(to: p(0.32, 0.42))

        case .snowboarding:
            addRoundedRect(x: 0.18, y: 0.62, w: 0.64, h: 0.12, cr: 0.06)
            addCircle(cx: 0.50, cy: 0.26, r: 0.07)
            path.move(to: p(0.50, 0.34))
            path.addLine(to: p(0.52, 0.62))
            path.move(to: p(0.50, 0.40))
            path.addLine(to: p(0.34, 0.52))

        case .bowling:
            addOval(cx: 0.38, cy: 0.48, rx: 0.10, ry: 0.28)
            addCircle(cx: 0.38, cy: 0.22, r: 0.08)
            addCircle(cx: 0.66, cy: 0.62, r: 0.14)
            addCircle(cx: 0.60, cy: 0.54, r: 0.025)
            addCircle(cx: 0.68, cy: 0.52, r: 0.025)
            addCircle(cx: 0.66, cy: 0.60, r: 0.025)

        case .boxing:
            addOval(cx: 0.34, cy: 0.46, rx: 0.16, ry: 0.20)
            addOval(cx: 0.66, cy: 0.46, rx: 0.16, ry: 0.20)
            addRoundedRect(x: 0.22, y: 0.60, w: 0.24, h: 0.12, cr: 0.04)
            addRoundedRect(x: 0.54, y: 0.60, w: 0.24, h: 0.12, cr: 0.04)

        case .mma:
            path.move(to: p(0.30, 0.22))
            path.addLine(to: p(0.70, 0.22))
            path.addLine(to: p(0.82, 0.42))
            path.addLine(to: p(0.70, 0.78))
            path.addLine(to: p(0.30, 0.78))
            path.addLine(to: p(0.18, 0.42))
            path.closeSubpath()

        case .wrestling, .martialArts, .karate, .judo, .taekwondo:
            addCircle(cx: 0.50, cy: 0.22, r: 0.08)
            path.move(to: p(0.50, 0.30))
            path.addLine(to: p(0.50, 0.54))
            path.addLine(to: p(0.36, 0.78))
            path.move(to: p(0.50, 0.54))
            path.addLine(to: p(0.68, 0.78))
            path.move(to: p(0.50, 0.36))
            path.addLine(to: p(0.22, 0.28))
            path.move(to: p(0.50, 0.36))
            path.addLine(to: p(0.80, 0.42))

        case .gym:
            addRoundedRect(x: 0.18, y: 0.38, w: 0.12, h: 0.24, cr: 0.03)
            addRoundedRect(x: 0.70, y: 0.38, w: 0.12, h: 0.24, cr: 0.03)
            addRoundedRect(x: 0.12, y: 0.42, w: 0.08, h: 0.16, cr: 0.02)
            addRoundedRect(x: 0.80, y: 0.42, w: 0.08, h: 0.16, cr: 0.02)
            addRoundedRect(x: 0.30, y: 0.46, w: 0.40, h: 0.08, cr: 0.04)

        case .crossFit:
            addOval(cx: 0.50, cy: 0.42, rx: 0.16, ry: 0.20)
            addRoundedRect(x: 0.44, y: 0.58, w: 0.12, h: 0.18, cr: 0.04)

        case .yoga:
            addCircle(cx: 0.50, cy: 0.28, r: 0.08)
            path.move(to: p(0.50, 0.36))
            path.addLine(to: p(0.50, 0.58))
            path.move(to: p(0.28, 0.70))
            path.addQuadCurve(to: p(0.50, 0.58), control: p(0.32, 0.48))
            path.addQuadCurve(to: p(0.72, 0.70), control: p(0.68, 0.48))
            path.move(to: p(0.50, 0.42))
            path.addLine(to: p(0.32, 0.38))
            path.move(to: p(0.50, 0.42))
            path.addLine(to: p(0.68, 0.38))

        case .motorsport, .nascar, .motocross:
            addRoundedRect(x: 0.18, y: 0.40, w: 0.64, h: 0.22, cr: 0.08)
            addCircle(cx: 0.32, cy: 0.66, r: 0.10)
            addCircle(cx: 0.68, cy: 0.66, r: 0.10)
            addRoundedRect(x: 0.40, y: 0.28, w: 0.28, h: 0.14, cr: 0.04)
            if kind == .nascar {
                addRoundedRect(x: 0.22, y: 0.22, w: 0.12, h: 0.10, cr: 0.02)
                addRoundedRect(x: 0.36, y: 0.22, w: 0.12, h: 0.10, cr: 0.02)
            }

        case .esports:
            addRoundedRect(x: 0.18, y: 0.36, w: 0.64, h: 0.30, cr: 0.12)
            addCircle(cx: 0.34, cy: 0.50, r: 0.05)
            addCircle(cx: 0.44, cy: 0.50, r: 0.05)
            addRoundedRect(x: 0.60, y: 0.44, w: 0.16, h: 0.05, cr: 0.02)
            addRoundedRect(x: 0.66, y: 0.40, w: 0.05, h: 0.14, cr: 0.02)

        case .chess:
            addRoundedRect(x: 0.30, y: 0.70, w: 0.40, h: 0.10, cr: 0.03)
            addRoundedRect(x: 0.40, y: 0.42, w: 0.20, h: 0.30, cr: 0.04)
            addCircle(cx: 0.50, cy: 0.28, r: 0.10)
            addOval(cx: 0.62, cy: 0.22, rx: 0.08, ry: 0.12)

        case .paragliding, .hangGliding, .paramotoring:
            path.move(to: p(0.18, 0.32))
            path.addQuadCurve(to: p(0.82, 0.32), control: p(0.50, 0.08))
            path.addQuadCurve(to: p(0.18, 0.32), control: p(0.50, 0.22))
            path.closeSubpath()
            path.move(to: p(0.34, 0.32))
            path.addLine(to: p(0.48, 0.62))
            path.move(to: p(0.66, 0.32))
            path.addLine(to: p(0.52, 0.62))
            addCircle(cx: 0.50, cy: 0.68, r: 0.08)
            if kind == .paramotoring {
                addCircle(cx: 0.68, cy: 0.68, r: 0.08)
            }

        case .breakdance, .ballet:
            addCircle(cx: 0.50, cy: 0.22, r: 0.08)
            path.move(to: p(0.50, 0.30))
            path.addLine(to: p(0.50, 0.54))
            path.addLine(to: p(0.32, 0.76))
            path.move(to: p(0.50, 0.54))
            path.addLine(to: p(0.70, 0.76))
            path.move(to: p(0.50, 0.36))
            path.addLine(to: p(0.22, 0.32))
            path.move(to: p(0.50, 0.36))
            path.addLine(to: p(0.78, 0.28))
            if kind == .ballet {
                path.move(to: p(0.28, 0.76))
                path.addLine(to: p(0.36, 0.76))
                path.move(to: p(0.64, 0.76))
                path.addLine(to: p(0.74, 0.76))
            }

        case .discGolf:
            addCircle(cx: 0.38, cy: 0.42, r: 0.16)
            addRoundedRect(x: 0.54, y: 0.28, w: 0.08, h: 0.44, cr: 0.03)
            addOval(cx: 0.62, cy: 0.24, rx: 0.10, ry: 0.06)
            addOval(cx: 0.50, cy: 0.76, rx: 0.18, ry: 0.06)

        case .hiking:
            addCircle(cx: 0.50, cy: 0.22, r: 0.08)
            path.move(to: p(0.50, 0.30))
            path.addLine(to: p(0.50, 0.52))
            path.addLine(to: p(0.38, 0.76))
            path.move(to: p(0.50, 0.52))
            path.addLine(to: p(0.64, 0.76))
            path.move(to: p(0.50, 0.34))
            path.addLine(to: p(0.32, 0.48))
            path.move(to: p(0.50, 0.34))
            path.addLine(to: p(0.62, 0.22))
            path.addLine(to: p(0.62, 0.58))

        case .kayaking:
            addOval(cx: 0.50, cy: 0.58, rx: 0.32, ry: 0.12)
            path.move(to: p(0.18, 0.48))
            path.addLine(to: p(0.82, 0.68))
            addCircle(cx: 0.50, cy: 0.36, r: 0.07)
            path.move(to: p(0.50, 0.44))
            path.addLine(to: p(0.50, 0.58))

        case .surfing:
            addOval(cx: 0.50, cy: 0.58, rx: 0.12, ry: 0.28)
            path.move(to: p(0.22, 0.72))
            path.addQuadCurve(to: p(0.78, 0.62), control: p(0.50, 0.82))
            addCircle(cx: 0.50, cy: 0.28, r: 0.07)
            path.move(to: p(0.50, 0.36))
            path.addLine(to: p(0.50, 0.48))

        case .generic:
            addCircle(cx: 0.50, cy: 0.50, r: 0.26)
            addRoundedRect(x: 0.46, y: 0.22, w: 0.08, h: 0.56, cr: 0.04)
            addRoundedRect(x: 0.22, y: 0.46, w: 0.56, h: 0.08, cr: 0.04)
        }

        return path
    }
}

/// Small shield used by the recruiting badge (custom vector, not an SF Symbol).
struct FanGeoRecruitingShieldGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.50, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.92, y: rect.minY + h * 0.18))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.92, y: rect.minY + h * 0.52))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + w * 0.50, y: rect.maxY),
            control: CGPoint(x: rect.minX + w * 0.92, y: rect.minY + h * 0.82)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + w * 0.08, y: rect.minY + h * 0.52),
            control: CGPoint(x: rect.minX + w * 0.08, y: rect.minY + h * 0.82)
        )
        path.addLine(to: CGPoint(x: rect.minX + w * 0.08, y: rect.minY + h * 0.18))
        path.closeSubpath()
        return path
    }
}
