import SwiftUI
import AppKit

/// Remote body metrics. Corner radii are concentric with the controls in each corner:
/// home and power keys (r 20) at the top, the large keys (r 40) at the bottom, both inset by `inset`.
private enum M {
    static let width: CGFloat = 215
    static let inset: CGFloat = 10
    static let key: CGFloat = 80
    static let power: CGFloat = 40
    static let topRadius = power / 2 + inset
    static let bottomRadius = key / 2 + inset
    static let cardRadius: CGFloat = 18
}

struct RemoteView: View {
    @ObservedObject var tv: TVClient
    @ObservedObject var ui: UIState
    @FocusState private var textFocused: Bool
    @State private var text = ""
    @State private var code = ""
    @State private var prefilling = false // text set from the TV, not typed
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            if tv.state == .choosing { chooserCard }
            if tv.state == .confirmOnTV { confirmCard }
            if tv.state == .enterCode || tv.state == .pairing { pairingCard }
            if ui.keyboardOpen && tv.state == .connected { keyboardCard }
            remote
        }
        .frame(width: M.width)
        .fixedSize()
        .onChange(of: textFocused) { _, f in ui.typing = f }
        .onChange(of: ui.keyboardOpen) { _, open in
            textFocused = open
            let start = open ? tv.tvText : ""
            if start != text { prefilling = true; text = start }
        }
    }

    // MARK: remote body

    private var remote: some View {
        VStack(spacing: 14) {
            // Home and power mirror each other in the top corners; status sits between them.
            HStack(spacing: 6) {
                RoundKey(size: M.power, label: "Головний екран", hint: "Головний екран (H)",
                         action: { tv.send(.home) }) {
                    Image(systemName: "house.fill").font(.system(size: 15))
                }
                status.frame(maxWidth: .infinity)
                RoundKey(size: M.power, label: "Живлення", hint: "Увімкнути або вимкнути TV",
                         action: { tv.send(.power) }) {
                    Image(systemName: "power").font(.system(size: 17))
                }
            }
            DPad(send: tv.send)
            HStack(alignment: .top) {
                VStack(spacing: 12) {
                    RoundKey(size: M.key, label: "Назад", hint: "Назад (⌫)", action: { tv.send(.back) }) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 26, weight: .light))
                    }
                    RoundKey(size: M.key, label: "Відтворення/пауза", hint: "Відтворення / пауза (пробіл)",
                             action: { tv.send(.playPause) }) {
                        Image(systemName: "playpause.fill").font(.system(size: 22))
                    }
                    RoundKey(size: M.key, label: "Без звуку", hint: "Без звуку (M)", action: { tv.send(.mute) }) {
                        Image(systemName: "speaker.slash.fill").font(.system(size: 20))
                    }
                }
                Spacer()
                VStack(spacing: 12) {
                    RoundKey(size: M.key, label: "Клавіатура", hint: "Ввести текст (K)",
                             highlighted: ui.keyboardOpen, action: { ui.keyboardOpen.toggle() }) {
                        Image(systemName: "keyboard").font(.system(size: 28, weight: .light))
                    }
                    VolumeRocker(up: { tv.send(.volumeUp) }, down: { tv.send(.volumeDown) })
                }
            }
        }
        .padding(M.inset)
        .background(bodyShape.fill(bodyFill))
        .overlay(bodyShape.strokeBorder(bodyEdge, lineWidth: 1))
        .clipShape(bodyShape)
    }

    private var bodyShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: M.topRadius, bottomLeadingRadius: M.bottomRadius,
                               bottomTrailingRadius: M.bottomRadius, topTrailingRadius: M.topRadius,
                               style: .continuous)
    }

    // Aluminium in light mode, space grey in dark mode.
    private var bodyFill: LinearGradient {
        let colors = scheme == .dark
            ? [Color(white: 0.38), Color(white: 0.22)]
            : [Color(white: 0.93), Color(white: 0.68)]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var bodyEdge: LinearGradient {
        LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.25 : 0.7), .white.opacity(0.05)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var status: some View {
        let (color, label): (Color, String) = {
            switch tv.state {
            case .connected: return (.green, tv.tvName)
            case .connecting: return (.orange, "Підключення…")
            case .searching: return (.orange, "Пошук TV…")
            case .pairing, .enterCode, .confirmOnTV: return (.blue, "Сполучення")
            case .choosing: return (.blue, "Оберіть телевізор")
            case .idle: return (.gray, tv.tvName)
            case .offline(let msg): return (.red, msg)
            }
        }()
        return VStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(scheme == .dark ? Color(white: 0.85) : Color(white: 0.25))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .contentShape(Rectangle())
        .onTapGesture { if case .offline = tv.state { tv.connect() } }
        .help(label)
        .accessibilityElement(children: .combine)
    }

    // MARK: cards

    private var keyboardCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard").foregroundStyle(.secondary)
            TextField("Текст для TV…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($textFocused)
                .onChange(of: text) { old, t in
                    if prefilling { prefilling = false } else { tv.editText(from: old, to: t) }
                }
                .onSubmit { tv.submitText() }
                .onExitCommand { ui.keyboardOpen = false }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Очистити поле на TV")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .card()
    }

    private var chooserCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Телевізори в мережі")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ForEach(tv.devices, id: \.self) { d in
                DeviceRow(device: d, current: d.id == tv.device?.id) { tv.select(d) }
            }
            Divider().padding(.vertical, 4)
            Button { tv.scan(choose: true) } label: {
                Label("Шукати знову", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .padding(8)
        .card()
    }

    private var confirmCard: some View {
        Label {
            Text("Натисніть «Дозволити» на телевізорі")
                .font(.system(size: 12, weight: .semibold))
        } icon: {
            Image(systemName: "hand.tap")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(tv.state == .pairing ? "Запит на сполучення…" : "Введіть код з екрана TV",
                  systemImage: "link")
                .font(.system(size: 12, weight: .semibold))
            if tv.state == .enterCode {
                HStack(spacing: 6) {
                    TextField("A1B2C3", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($textFocused)
                        .onSubmit { tv.submitCode(code) }
                        .onAppear { textFocused = true }
                    Button("OK") { tv.submitCode(code) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            if let err = tv.pairingError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct DeviceRow: View {
    let device: TVDevice
    let current: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "tv").frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(device.kind == .samsung ? "Samsung Tizen · \(device.host)" : "Android TV · \(device.host)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if current { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Shared between the view and the app delegate's keyboard handling.
final class UIState: ObservableObject {
    @Published var keyboardOpen = false
    @Published var typing = false
}

// MARK: - Native material

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

private extension View {
    func card() -> some View {
        let shape = RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous)
        return background(VisualEffect().clipShape(shape))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

// MARK: - Controls

private let keyFill = RadialGradient(colors: [Color(white: 0.2), Color(white: 0.11)],
                                     center: .init(x: 0.5, y: 0.75), startRadius: 0, endRadius: 60)

/// Fires once on press, then repeats while held (volume, arrows).
private final class Repeater {
    private var timer: Timer?
    func start(_ action: @escaping () -> Void) {
        action()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in action() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
}

struct RoundKey<Content: View>: View {
    let size: CGFloat
    let label: String
    let hint: String
    var highlighted = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .foregroundStyle(highlighted ? Color.accentColor : .white)
                .frame(width: size, height: size)
        }
        .buttonStyle(DarkStyle(shape: Circle()))
        .help(hint)
        .accessibilityLabel(label)
    }
}

struct DarkStyle<S: Shape>: ButtonStyle {
    let shape: S
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(shape.fill(keyFill))
            .overlay(shape.fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0)))
            .contentShape(shape)
            .shadow(color: .black.opacity(0.35), radius: configuration.isPressed ? 1 : 3, y: 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct VolumeRocker: View {
    let up: () -> Void
    let down: () -> Void
    @State private var pressed: Bool? // true = up half
    @State private var repeater = Repeater()
    private let half: CGFloat = 86

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "plus").frame(width: M.key, height: half)
                .background(Color.white.opacity(pressed == true ? 0.12 : 0))
            Image(systemName: "minus").frame(width: M.key, height: half)
                .background(Color.white.opacity(pressed == false ? 0.12 : 0))
        }
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.white)
        .background(Capsule().fill(keyFill))
        .clipShape(Capsule())
        .contentShape(Capsule())
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard pressed == nil else { return }
                    let isUp = v.startLocation.y < half
                    pressed = isUp
                    repeater.start(isUp ? up : down)
                }
                .onEnded { _ in pressed = nil; repeater.stop() }
        )
        .help("Гучність (+ / −), утримуйте для повтору")
        .accessibilityElement()
        .accessibilityLabel("Гучність")
        .accessibilityAdjustableAction { $0 == .increment ? up() : down() }
    }
}

struct DPad: View {
    let send: (Key) -> Void
    @State private var pressed: Key?
    @State private var repeater = Repeater()
    private let size: CGFloat = 195
    private let inner: CGFloat = 108

    var body: some View {
        ZStack {
            Circle().fill(keyFill)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            if let p = pressed, p != .center {
                Circle().fill(Color.white.opacity(0.10)).mask(wedge(p))
            }
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.2), Color(white: 0.13)],
                                     center: .init(x: 0.5, y: 0.8), startRadius: 0, endRadius: 60))
                .overlay(Circle().fill(Color.white.opacity(pressed == .center ? 0.12 : 0)))
                .overlay(Circle().strokeBorder(Color(white: 0.28), lineWidth: 1))
                .frame(width: inner, height: inner)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            Text("OK").font(.system(size: 24))
            arrow("chevron.up").offset(y: -75)
            arrow("chevron.down").offset(y: 75)
            arrow("chevron.left").offset(x: -75)
            arrow("chevron.right").offset(x: 75)
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard pressed == nil, let k = key(at: v.startLocation) else { return }
                    pressed = k
                    if k == .center { send(k) } else { repeater.start { send(k) } }
                }
                .onEnded { _ in pressed = nil; repeater.stop() }
        )
        .help("Навігація: стрілки, OK — Enter")
        .accessibilityElement()
        .accessibilityLabel("Навігація")
        .accessibilityAction(named: "Вгору") { send(.up) }
        .accessibilityAction(named: "Вниз") { send(.down) }
        .accessibilityAction(named: "Вліво") { send(.left) }
        .accessibilityAction(named: "Вправо") { send(.right) }
        .accessibilityAction(named: "OK") { send(.center) }
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16, weight: .medium))
    }

    private func key(at p: CGPoint) -> Key? {
        let dx = p.x - size / 2, dy = p.y - size / 2
        let r = (dx * dx + dy * dy).squareRoot()
        if r > size / 2 { return nil }
        if r < inner / 2 { return .center }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    private func wedge(_ k: Key) -> some View {
        let start: Double = [Key.right: -45, .down: 45, .left: 135, .up: 225][k] ?? 0
        return Path { p in
            let c = CGPoint(x: size / 2, y: size / 2)
            p.move(to: c)
            p.addArc(center: c, radius: size / 2, startAngle: .degrees(start),
                     endAngle: .degrees(start + 90), clockwise: false)
            p.closeSubpath()
        }
    }
}
