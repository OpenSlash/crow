import AppKit

/// What a persona needs to draw one animation frame. `phase` advances about
/// 2.25 per second; `level` is the microphone level, 0...1.
struct CrowPersonaFrame {
    var state: IslandVisualState
    var phase: CGFloat
    var level: CGFloat
    var accent: NSColor
    var statusDot: NSColor
}

/// The island personas besides the default brand crow. Each one reacts to the
/// voice state with an expression, not only a color, and has a simpler form
/// below 24 pt, where the island header draws it.
enum CrowPersona {
    static func draw(_ style: IslandAvatarStyle, in rect: NSRect, frame: CrowPersonaFrame) {
        let size = min(rect.width, rect.height)
        let box = NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
        switch style {
        case .cute: drawCuteCrow(in: box, frame)
        case .robot: drawRobot(in: box, frame)
        case .jarvis: drawCore(in: box, frame)
        case .default: return
        }
        frame.statusDot.setFill()
        let dot = max(2.0, size * 0.13)
        NSBezierPath(ovalIn: NSRect(x: box.maxX - dot * 0.8, y: box.minY, width: dot, height: dot)).fill()
    }

    // MARK: Cute crow

    /// A round, big-eyed crow facing right like the brand mark: charcoal with a
    /// rim light so it reads on the black island, a thick slate beak, and a
    /// collar in the state color.
    private static func drawCuteCrow(in box: NSRect, _ f: CrowPersonaFrame) {
        let s = box.width
        let small = s < 24
        let breath = (sin(f.phase * 0.9) + 1) / 2
        var lift: CGFloat = 0
        var tilt: CGFloat = 0
        switch f.state {
        case .idle: lift = breath * s * 0.015
        case .listening: lift = f.level * s * 0.05; tilt = 4 + f.level * 6
        case .running: tilt = -6
        case .thinking: tilt = 5 * sin(f.phase * 0.6)
        default: break
        }
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * s, y: box.minY + y * s + lift) }

        let body = NSColor(calibratedWhite: 0.19, alpha: 1)
        let rim = NSColor.white.withAlphaComponent(f.state == .idle ? 0.34 : 0.48)
        let rimWidth = max(0.7, s * 0.04)

        // Tail and body, behind the head.
        let tail = NSBezierPath()
        tail.move(to: p(0.24, 0.30))
        tail.line(to: p(0.03, 0.18))
        tail.line(to: p(0.10, 0.12))
        tail.line(to: p(0.28, 0.16))
        tail.close()
        let torso = NSBezierPath(ovalIn: NSRect(origin: p(0.18, 0.07), size: NSSize(width: s * 0.56, height: s * 0.50)))
        for path in [tail, torso] {
            body.setFill(); path.fill()
            rim.setStroke(); path.lineWidth = rimWidth; path.stroke()
        }
        if !small {
            NSColor.white.withAlphaComponent(0.55).setStroke()
            let feet = NSBezierPath()
            feet.move(to: p(0.40, 0.09)); feet.line(to: p(0.38, 0.0))
            feet.move(to: p(0.52, 0.09)); feet.line(to: p(0.54, 0.0))
            feet.lineWidth = max(0.7, s * 0.035)
            feet.stroke()
        }

        // Head, tilted around its center.
        let headCenter = p(0.50, 0.60)
        NSGraphicsContext.saveGraphicsState()
        let turn = NSAffineTransform()
        turn.translateX(by: headCenter.x, yBy: headCenter.y)
        turn.rotate(byDegrees: tilt)
        turn.translateX(by: -headCenter.x, yBy: -headCenter.y)
        turn.concat()

        // Beak first so the head overlaps its base. The lower half opens to speak.
        let open: CGFloat = f.state == .speaking ? (0.5 + 0.5 * sin(f.phase * 3.2)) * 0.07 : 0
        let beakColor = NSColor(calibratedWhite: 0.60, alpha: 1)
        let upper = NSBezierPath()
        upper.move(to: p(0.72, 0.66))
        upper.curve(to: p(0.99, 0.57), controlPoint1: p(0.84, 0.70), controlPoint2: p(0.95, 0.65))
        upper.line(to: p(0.72, 0.56))
        upper.close()
        let lower = NSBezierPath()
        lower.move(to: p(0.72, 0.56))
        lower.line(to: p(0.93, 0.55 - open))
        lower.curve(to: p(0.72, 0.49), controlPoint1: p(0.86, 0.51 - open), controlPoint2: p(0.78, 0.49))
        lower.close()
        beakColor.setFill()
        upper.fill()
        beakColor.blended(withFraction: 0.25, of: .black)?.setFill()
        lower.fill()

        let head = NSBezierPath(ovalIn: NSRect(x: headCenter.x - s * 0.30, y: headCenter.y - s * 0.28, width: s * 0.60, height: s * 0.56))
        body.setFill(); head.fill()
        rim.setStroke(); head.lineWidth = rimWidth; head.stroke()
        if !small {
            // Soft light on the crown and a two-feather tuft.
            NSColor.white.withAlphaComponent(0.07).setFill()
            NSBezierPath(ovalIn: NSRect(origin: p(0.30, 0.70), size: NSSize(width: s * 0.30, height: s * 0.14))).fill()
            rim.setStroke()
            let tuft = NSBezierPath()
            tuft.move(to: p(0.46, 0.87)); tuft.curve(to: p(0.40, 0.98), controlPoint1: p(0.45, 0.93), controlPoint2: p(0.42, 0.97))
            tuft.move(to: p(0.52, 0.87)); tuft.curve(to: p(0.52, 0.97), controlPoint1: p(0.53, 0.92), controlPoint2: p(0.53, 0.95))
            tuft.lineWidth = rimWidth
            tuft.lineCapStyle = .round
            tuft.stroke()
        }

        drawCuteEye(center: p(0.58, 0.64), radius: s * (small ? 0.13 : 0.12), state: f.state, phase: f.phase, accent: f.accent)
        NSGraphicsContext.restoreGraphicsState()

        // Collar where head meets body: the state color.
        f.accent.withAlphaComponent(f.state == .idle ? 0.55 : 0.95).setStroke()
        let collar = NSBezierPath()
        collar.move(to: p(0.30, 0.40))
        collar.curve(to: p(0.66, 0.40), controlPoint1: p(0.40, 0.33), controlPoint2: p(0.56, 0.33))
        collar.lineWidth = max(1.0, s * 0.06)
        collar.lineCapStyle = .round
        collar.stroke()
    }

    private static func drawCuteEye(center c: NSPoint, radius r: CGFloat, state: IslandVisualState, phase: CGFloat, accent: NSColor) {
        let white = NSColor(calibratedWhite: 0.97, alpha: 1)
        let line = max(0.8, r * 0.34)
        if state == .failed {
            // A cross: it did not work.
            accent.setStroke()
            let x = NSBezierPath()
            x.move(to: NSPoint(x: c.x - r * 0.7, y: c.y - r * 0.7)); x.line(to: NSPoint(x: c.x + r * 0.7, y: c.y + r * 0.7))
            x.move(to: NSPoint(x: c.x - r * 0.7, y: c.y + r * 0.7)); x.line(to: NSPoint(x: c.x + r * 0.7, y: c.y - r * 0.7))
            x.lineWidth = line
            x.lineCapStyle = .round
            x.stroke()
            return
        }
        // Blinks now and then, and not while listening.
        let blink = state != .listening && fmod(phase, 9) > 8.6
        if blink {
            white.setStroke()
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: c.x - r, y: c.y)); lid.line(to: NSPoint(x: c.x + r, y: c.y))
            lid.lineWidth = line
            lid.lineCapStyle = .round
            lid.stroke()
            return
        }
        white.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()

        var look = NSPoint(x: r * 0.22, y: 0)
        var pupil = r * 0.62
        switch state {
        case .listening: pupil = r * 0.70
        case .thinking: look = NSPoint(x: r * 0.05, y: r * 0.32)
        case .approval: pupil = r * 0.52
        default: break
        }
        NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x + look.x - pupil / 2, y: c.y + look.y - pupil / 2, width: pupil, height: pupil)).fill()
        white.setFill()
        let glint = pupil * 0.34
        NSBezierPath(ovalIn: NSRect(x: c.x + look.x + pupil * 0.05, y: c.y + look.y + pupil * 0.10, width: glint, height: glint)).fill()

        // Lids give the mood: sleepy when idle, focused while working.
        let lidCover: CGFloat
        switch state {
        case .idle: lidCover = 0.45
        case .running: lidCover = 0.30
        default: lidCover = 0
        }
        if lidCover > 0 {
            // The lid stays inside the eye.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).addClip()
            NSColor(calibratedWhite: 0.19, alpha: 1).setFill()
            let top = c.y + r - r * 2 * lidCover
            NSBezierPath(rect: NSRect(x: c.x - r, y: top, width: r * 2, height: r * 2)).fill()
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let edge = NSBezierPath()
            edge.move(to: NSPoint(x: c.x - r, y: top)); edge.line(to: NSPoint(x: c.x + r, y: top))
            edge.lineWidth = max(0.5, r * 0.18)
            edge.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        if state == .approval {
            // A raised brow: Crow is asking.
            accent.setStroke()
            let brow = NSBezierPath()
            brow.move(to: NSPoint(x: c.x - r * 0.8, y: c.y + r * 1.35)); brow.line(to: NSPoint(x: c.x + r * 0.9, y: c.y + r * 1.75))
            brow.lineWidth = line * 0.8
            brow.lineCapStyle = .round
            brow.stroke()
        }
    }

    // MARK: Robot

    /// A light helmet with a dark face screen; the eyes are light on the screen
    /// and carry the expression, the antenna tip carries the state color.
    private static func drawRobot(in box: NSRect, _ f: CrowPersonaFrame) {
        let s = box.width
        let small = s < 24
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * s, y: box.minY + y * s) }
        let bob = f.state == .listening ? f.level * s * 0.04 : (sin(f.phase * 0.9) + 1) / 2 * s * 0.012

        // Antenna.
        NSColor(calibratedWhite: 0.70, alpha: 1).setStroke()
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: p(0.5, 0.80).x, y: p(0.5, 0.80).y + bob))
        stem.line(to: NSPoint(x: p(0.5, 0.92).x, y: p(0.5, 0.92).y + bob))
        stem.lineWidth = max(0.8, s * 0.045)
        stem.stroke()
        let tipGlow = f.state == .idle ? 0.5 : 0.75 + 0.25 * sin(f.phase * 2.4)
        let tip = s * 0.11
        let tipCenter = NSPoint(x: p(0.5, 0.94).x, y: p(0.5, 0.94).y + bob)
        withGlow(f.accent, radius: small ? 0 : s * 0.12) {
            f.accent.withAlphaComponent(tipGlow).setFill()
            NSBezierPath(ovalIn: NSRect(x: tipCenter.x - tip / 2, y: tipCenter.y - tip / 2, width: tip, height: tip)).fill()
        }

        // Ears, then the helmet over them.
        NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
        for x in [0.02, 0.86] as [CGFloat] {
            NSBezierPath(roundedRect: NSRect(x: p(x, 0).x, y: p(0, 0.36).y + bob, width: s * 0.12, height: s * 0.24), xRadius: s * 0.05, yRadius: s * 0.05).fill()
        }
        let helmetRect = NSRect(x: p(0.09, 0).x, y: p(0, 0.12).y + bob, width: s * 0.82, height: s * 0.70)
        let helmet = NSBezierPath(roundedRect: helmetRect, xRadius: s * 0.26, yRadius: s * 0.26)
        NSGradient(starting: NSColor(calibratedWhite: 0.97, alpha: 1), ending: NSColor(calibratedWhite: 0.74, alpha: 1))?.draw(in: helmet, angle: -90)

        let screen = helmetRect.insetBy(dx: s * 0.10, dy: s * 0.10)
        NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
        NSBezierPath(roundedRect: screen, xRadius: s * 0.15, yRadius: s * 0.15).fill()

        let eyeY = screen.midY + screen.height * 0.08
        let left = NSPoint(x: screen.minX + screen.width * 0.30, y: eyeY)
        let right = NSPoint(x: screen.minX + screen.width * 0.70, y: eyeY)
        let w = screen.width * 0.17
        let h = screen.height * 0.40
        let color = f.accent.withAlphaComponent(f.state == .idle ? 0.75 : 1)
        let stroke = max(0.9, s * 0.055)
        withGlow(f.accent, radius: small ? 0 : s * 0.10) {
            color.setFill()
            color.setStroke()
            switch f.state {
            case .listening:
                // Eyes open wider with the voice.
                let grow = h * (0.85 + f.level * 0.45)
                for c in [left, right] { pill(center: c, width: w, height: grow).fill() }
            case .speaking:
                // Happy arcs and a mouth that moves.
                for c in [left, right] {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: NSPoint(x: c.x, y: c.y - h * 0.2), radius: w * 0.75, startAngle: 20, endAngle: 160)
                    arc.lineWidth = stroke
                    arc.lineCapStyle = .round
                    arc.stroke()
                }
                let talk = 0.35 + 0.65 * (sin(f.phase * 3.4) + 1) / 2
                pill(center: NSPoint(x: screen.midX, y: screen.minY + screen.height * 0.24), width: screen.width * 0.26, height: max(1, screen.height * 0.16 * talk)).fill()
            case .thinking:
                // Looking up and to the side, drifting.
                let drift = sin(f.phase * 0.8) * w * 0.5
                for c in [left, right] { pill(center: NSPoint(x: c.x + drift, y: c.y + h * 0.15), width: w, height: h * 0.55).fill() }
            case .running:
                // Focused bars and a scan line under them.
                for c in [left, right] { pill(center: c, width: w * 1.25, height: h * 0.32).fill() }
                let t = (sin(f.phase * 1.6) + 1) / 2
                let x = screen.minX + screen.width * (0.22 + t * 0.56)
                pill(center: NSPoint(x: x, y: screen.minY + screen.height * 0.22), width: screen.width * 0.14, height: max(1, screen.height * 0.08)).fill()
            case .approval:
                // One eye squints: a question.
                pill(center: left, width: w, height: h).fill()
                pill(center: right, width: w * 1.2, height: h * 0.32).fill()
            case .failed:
                for c in [left, right] {
                    let x = NSBezierPath()
                    let r = w * 0.6
                    x.move(to: NSPoint(x: c.x - r, y: c.y - r)); x.line(to: NSPoint(x: c.x + r, y: c.y + r))
                    x.move(to: NSPoint(x: c.x - r, y: c.y + r)); x.line(to: NSPoint(x: c.x + r, y: c.y - r))
                    x.lineWidth = stroke
                    x.lineCapStyle = .round
                    x.stroke()
                }
            case .idle:
                let blink = fmod(f.phase, 9) > 8.6
                for c in [left, right] { pill(center: c, width: w, height: blink ? max(1, h * 0.12) : h * 0.8).fill() }
            }
        }
    }

    // MARK: Core

    /// A HUD reactor: a tick ring, two counter-rotating arcs and a glowing core.
    /// Motion speeds up with activity; approval and failure hold still.
    private static func drawCore(in box: NSRect, _ f: CrowPersonaFrame) {
        let s = box.width
        let small = s < 24
        let c = NSPoint(x: box.midX, y: box.midY)
        let still = f.state == .approval || f.state == .failed
        let speed: CGFloat
        switch f.state {
        case .idle: speed = 0.25
        case .listening, .speaking: speed = 0.9
        case .thinking, .running: speed = 1.6
        case .approval, .failed: speed = 0
        }
        let spin = f.phase * speed * 40 // degrees
        let accent = f.accent
        let dim: CGFloat = f.state == .idle ? 0.72 : 1

        // Outer ring: ticks with a bright sweep, or a plain ring when small.
        let outer = s * 0.46
        if small {
            accent.withAlphaComponent(0.35 * dim).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
            ring.lineWidth = max(0.7, s * 0.05)
            ring.stroke()
        } else {
            let ticks = 28
            for i in 0..<ticks {
                let angle = CGFloat(i) / CGFloat(ticks) * 360
                var distance = fmod(angle - spin * 1.5 + 3600, 360) / 360 // 0 at the sweep head
                if still { distance = 0.6 }
                let bright = max(0.28, 1 - distance * 1.6)
                accent.withAlphaComponent(bright * 0.85 * dim).setStroke()
                let tick = NSBezierPath()
                tick.appendArc(withCenter: c, radius: outer, startAngle: angle, endAngle: angle + 360 / CGFloat(ticks) * 0.55)
                tick.lineWidth = max(0.8, s * 0.05)
                tick.stroke()
            }
        }

        // Two arcs turning against each other; broken when failed.
        let middle = s * 0.33
        accent.withAlphaComponent(0.85 * dim).setStroke()
        for (offset, direction) in [(0.0, 1.0), (180.0, -1.0)] as [(CGFloat, CGFloat)] {
            let start = offset + spin * direction
            let length: CGFloat = f.state == .failed ? 50 : 110
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: middle, startAngle: start, endAngle: start + length)
            arc.lineWidth = max(1, s * 0.065)
            arc.lineCapStyle = .round
            arc.stroke()
        }
        if !small {
            accent.withAlphaComponent(0.30 * dim).setStroke()
            let inner = NSBezierPath(ovalIn: NSRect(x: c.x - s * 0.22, y: c.y - s * 0.22, width: s * 0.44, height: s * 0.44))
            inner.lineWidth = max(0.5, s * 0.02)
            inner.stroke()
        }

        // Core: grows with the voice, pulses while speaking, blinks for approval.
        var radius = s * 0.13
        var alpha: CGFloat = 0.95 * dim
        switch f.state {
        case .listening: radius *= 1 + f.level * 0.6
        case .speaking: radius *= 1 + 0.3 * (sin(f.phase * 3.4) + 1) / 2
        case .approval: alpha = 0.55 + 0.45 * (sin(f.phase * 2.6) + 1) / 2
        case .idle: radius *= 0.9 + 0.1 * (sin(f.phase * 0.9) + 1) / 2
        default: break
        }
        withGlow(accent, radius: small ? s * 0.15 : s * 0.22) {
            let core = NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            let light = accent.blended(withFraction: 0.65, of: .white) ?? accent
            NSGradient(starting: light.withAlphaComponent(alpha), ending: accent.withAlphaComponent(alpha))?
                .draw(in: NSBezierPath(ovalIn: core), relativeCenterPosition: .zero)
        }
    }

    // MARK: Helpers

    private static func pill(center: NSPoint, width: CGFloat, height: CGFloat) -> NSBezierPath {
        let r = min(width, height) / 2
        return NSBezierPath(roundedRect: NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height), xRadius: r, yRadius: r)
    }

    private static func withGlow(_ color: NSColor, radius: CGFloat, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        if radius > 0 {
            let shadow = NSShadow()
            shadow.shadowColor = color.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = radius
            shadow.shadowOffset = .zero
            shadow.set()
        }
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Development aid: CROW_PERSONA_SHEET=<file.png> renders every persona in every
/// state, at header and panel size, on the island's black, then quits.
enum CrowPersonaSheet {
    @MainActor static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CROW_PERSONA_SHEET"], !path.isEmpty else { return }
        let states: [(IslandVisualState, String, NSColor)] = [
            (.idle, "idle", NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0, alpha: 1)),
            (.listening, "listening", NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.63, alpha: 1)),
            (.speaking, "speaking", NSColor(calibratedRed: 0.18, green: 0.68, blue: 0.98, alpha: 1)),
            (.thinking, "thinking", NSColor(calibratedRed: 0.43, green: 0.60, blue: 1.00, alpha: 1)),
            (.running, "running", NSColor(calibratedRed: 0.68, green: 0.54, blue: 0.96, alpha: 1)),
            (.approval, "approval", NSColor(calibratedRed: 1.00, green: 0.66, blue: 0.20, alpha: 1)),
            (.failed, "failed", NSColor(calibratedRed: 0.96, green: 0.32, blue: 0.34, alpha: 1)),
        ]
        let styles: [IslandAvatarStyle] = [.cute, .robot, .jarvis]
        let cell: CGFloat = 92
        let scale: CGFloat = 3
        let size = NSSize(width: CGFloat(states.count) * cell + 80, height: CGFloat(styles.count) * cell + 30)
        let image = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale))
        image.lockFocus()
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()
        NSColor(calibratedWhite: 0.02, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1)]
        for (column, state) in states.enumerated() {
            (state.1 as NSString).draw(at: NSPoint(x: 80 + CGFloat(column) * cell + 20, y: size.height - 18), withAttributes: label)
        }
        for (row, style) in styles.enumerated() {
            let y = size.height - 30 - CGFloat(row + 1) * cell
            (style.rawValue as NSString).draw(at: NSPoint(x: 10, y: y + cell / 2), withAttributes: label)
            for (column, state) in states.enumerated() {
                let x = 80 + CGFloat(column) * cell
                let frame = CrowPersonaFrame(state: state.0, phase: 2.0, level: 0.6, accent: state.2,
                                             statusDot: state.0 == .idle ? NSColor.white.withAlphaComponent(0.42) : state.2.withAlphaComponent(0.9))
                CrowPersona.draw(style, in: NSRect(x: x + 8, y: y + 30, width: 44, height: 44), frame: frame)
                CrowPersona.draw(style, in: NSRect(x: x + 58, y: y + 42, width: 20, height: 20), frame: frame)
            }
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }
}
