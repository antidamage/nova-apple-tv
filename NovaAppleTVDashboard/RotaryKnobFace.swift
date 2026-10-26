import SwiftUI

/// The knob face's light/dark treatment, exactly the web's `KnobSkinMode`
/// (see the dashboard's `useKnobSkin`). Light is a soft off-white dome with its
/// shading pulled back — a treatment of the same geometry, not an inversion of
/// the dark one.
enum KnobSkinMode {
    case dark
    case light

    var isLight: Bool { self == .light }
}

/// The web dial's recessed coloured well, machined face and bevel. All
/// variants use this geometry; their wrappers supply the paint and readouts.
/// `skin` is the theme's `knobSkin` — the face used to be dark-only, so the
/// dashboard's "light knob" theme drew the dark one.
struct RotaryKnobFace: View {
    let colors: [Color]
    var skin: KnobSkinMode = .dark

    /// Face body, from the outer rim inward. The light skin is off-white and
    /// keeps far less contrast between its rings: at knob size the dark skin's
    /// shadows read as grime on a pale face.
    private var faceColors: [Color] {
        skin.isLight
            ? [Color(white: 0.86), Color(white: 0.97), Color(white: 0.78)]
            : [Color(white: 0.26), Color(white: 0.13), .black]
    }

    private var lipShadowedOpacity: Double { skin.isLight ? 0.22 : 0.75 }
    private var dropShadowOpacity: Double { skin.isLight ? 0.22 : 0.35 }
    /// Knurling ink and its strong/faint alternation.
    private var knurlInk: Color { skin.isLight ? .black : .white }
    private var knurlStrong: Double { skin.isLight ? 0.05 : 0.07 }
    private var knurlFaint: Double { skin.isLight ? 0.02 : 0.025 }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle().fill(LinearGradient(colors: [.white.opacity(0.8), .black.opacity(skin.isLight ? 0.3 : 0.65), .white.opacity(0.65)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().fill(AngularGradient(colors: colors, center: .center)).padding(size * 0.015)
                Circle().stroke(.black.opacity(lipShadowedOpacity), lineWidth: size * 0.035).padding(size * 0.055)
                Circle().fill(RadialGradient(colors: faceColors,
                                             center: UnitPoint(x: 0.43, y: 0.35), startRadius: 0, endRadius: size * 0.55))
                    .padding(size * 0.085)
                Canvas { context, bounds in
                    let centre = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
                    for index in 0..<240 {
                        let angle = Double(index) * .pi / 120
                        var line = Path()
                        let inner = size * 0.17, outer = size * 0.406
                        line.move(to: CGPoint(x: centre.x + cos(angle) * inner, y: centre.y + sin(angle) * inner))
                        line.addLine(to: CGPoint(x: centre.x + cos(angle) * outer, y: centre.y + sin(angle) * outer))
                        context.stroke(line, with: .color(knurlInk.opacity(index.isMultiple(of: 2) ? knurlStrong : knurlFaint)), lineWidth: 0.5)
                    }
                }
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .clear, .black],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
                    .padding(size * 0.085)
            }.shadow(color: .black.opacity(dropShadowOpacity), radius: 7, y: 5)
        }
    }
}

struct RotaryTitleArc: View {
    let title: String
    let diameter: CGFloat
    var body: some View {
        ZStack {
            let letters = Array(title)
            ForEach(letters.indices, id: \.self) { index in
                let angle = Double(index) * 4.2 - Double(letters.count - 1) * 2.1
                Text(String(letters[index])).font(.novaMono(max(10, diameter * 0.06)))
                    .offset(y: -diameter * 0.55)
                    .rotationEffect(.degrees(angle))
            }
        }
    }
}

/// The dial's mode lights. The lit light is the theme's `ledColor` — it used to
/// be a hard-coded green, so the strip ignored the theme entirely; the unlit
/// wells follow the knob skin, since a black well is invisible on a pale face.
struct RotaryLEDs: View {
    let labels: [String]
    let selected: Int
    let size: CGFloat
    var color: Color = .white
    var onLightSkin: Bool = false

    private var unlit: Color { onLightSkin ? Color(white: 0.72) : Color(white: 0.15) }

    var body: some View {
        HStack(alignment: .top, spacing: size * 0.045) {
            ForEach(labels.indices, id: \.self) { index in
                VStack(spacing: 4) {
                    Capsule().fill(index == selected ? color : unlit)
                        .overlay(Capsule().stroke(.black.opacity(onLightSkin ? 0.35 : 0.8), lineWidth: 1))
                        .frame(width: max(4, size * 0.027), height: max(9, size * 0.07))
                        .shadow(color: index == selected ? color : .clear, radius: 7)
                    if labels.count <= 3 {
                        Text(labels[index].uppercased()).font(.novaMono(max(7, size * 0.032)))
                            .foregroundStyle(Color(white: onLightSkin ? 0.3 : 0.7))
                    }
                }
            }
        }
    }
}

/// A number on the knob face, as the web prints the temperature knob's: in
/// `22.5`, `22` full size and `.5` half size with its top level with the digits'
/// (nova-ha-dashboard `specs/temperature-encoder.md`, "Face"). A whole number or
/// `--` prints as it is.
struct RotaryFaceText: View {
    let text: String
    let size: CGFloat
    var decimals = true

    var body: some View {
        let parts = text.split(separator: ".", maxSplits: 1)
        if decimals, parts.count == 2 {
            HStack(alignment: .top, spacing: 0) {
                Text(parts[0]).font(.novaDisplay(size))
                Text("." + parts[1]).font(.novaDisplay(size * 0.5))
                    .padding(.top, size * 0.12)
            }
            .lineLimit(1).minimumScaleFactor(0.5)
        } else {
            Text(text).font(.novaDisplay(size)).lineLimit(1).minimumScaleFactor(0.5)
        }
    }
}
