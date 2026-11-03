// Renders 1920x1080 promo banners into docs/ using the app's real remote UI.
// Run from the repo root:
//   swiftc -swift-version 5 -parse-as-library -o build/make-banner \
//     $(ls Sources/*.swift | grep -v main.swift) scripts/make-banner.swift && build/make-banner
import SwiftUI
import AppKit

struct Copy {
    let file: String
    let headline: String
    let sub: String
    let features: [(String, String)] // SF Symbol, text
    let footer: String
    let clock: String
}

let copies = [
    Copy(file: "banner-en.png",
         headline: "Your TV remote,\nright in the menu bar.",
         sub: "A tiny native Mac app for Android TV, Google TV\nand Samsung Smart TVs.",
         features: [("menubar.rectangle", "Opens from the menu bar, never steals focus"),
                    ("keyboard", "Type on the TV with your Mac keyboard"),
                    ("arrow.up.arrow.down", "Arrow keys, Enter, Space just work"),
                    ("leaf", "0.6 MB · 0% CPU when idle")],
         footer: "Free on GitHub · github.com/klimasevskiy/MacMote",
         clock: "Tue 9:41"),
    Copy(file: "banner-uk.png",
         headline: "Пульт від телевізора —\nпрямо в рядку меню.",
         sub: "Крихітна нативна програма для Mac:\nAndroid TV, Google TV і Samsung Smart TV.",
         features: [("menubar.rectangle", "Відкривається з рядка меню, не забирає фокус"),
                    ("keyboard", "Пиши на TV з клавіатури Mac"),
                    ("arrow.up.arrow.down", "Стрілки, Enter і пробіл — як на пульті"),
                    ("leaf", "0,6 МБ · 0% CPU у простої")],
         footer: "Безкоштовно на GitHub · github.com/klimasevskiy/MacMote",
         clock: "Вт 9:41"),
]

struct Banner: View {
    let copy: Copy
    let tv: TVClient
    let ui = UIState()

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            HStack(alignment: .center, spacing: 0) {
                text.frame(width: 1000, alignment: .leading)
                Spacer()
            }
            .padding(.leading, 130)
            .frame(maxHeight: .infinity)
            menuBarScene
        }
        .frame(width: 1920, height: 1080)
        .environment(\.colorScheme, .dark)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.10),
                                    Color(red: 0.02, green: 0.02, blue: 0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Soft glow behind the remote, like light from a TV screen
            RadialGradient(colors: [Color(red: 0.25, green: 0.45, blue: 1).opacity(0.35), .clear],
                           center: .init(x: 0.74, y: 0.55), startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Color(red: 0.75, green: 0.3, blue: 1).opacity(0.18), .clear],
                           center: .init(x: 0.95, y: 0.95), startRadius: 0, endRadius: 500)
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 22) {
                Image(nsImage: NSImage(contentsOfFile: "docs/icon.png")!)
                    .resizable().frame(width: 104, height: 104)
                Text("MacMote")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 54)

            Text(copy.headline)
                .font(.system(size: 76, weight: .heavy))
                .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.72)],
                                                startPoint: .top, endPoint: .bottom))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 28)

            Text(copy.sub)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color(white: 0.68))
                .lineSpacing(6)
                .padding(.bottom, 48)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(copy.features, id: \.1) { icon, label in
                    HStack(spacing: 16) {
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color(red: 0.55, green: 0.7, blue: 1))
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                        Text(label)
                            .font(.system(size: 27, weight: .medium))
                            .foregroundStyle(Color(white: 0.9))
                    }
                }
            }
            .padding(.bottom, 56)

            Text(copy.footer)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        }
    }

    // A slice of the macOS menu bar with the remote hanging from its icon.
    private var menuBarScene: some View {
        let scale: CGFloat = 1.55
        let iconX: CGFloat = 1443 // centre of the MacMote icon in the bar
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 34) {
                Spacer()
                Image(systemName: "appletvremote.gen4")
                    .frame(width: 52, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.22)))
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(systemName: "magnifyingglass")
                Image(systemName: "switch.2")
                Text(copy.clock).font(.system(size: 25, weight: .medium))
            }
            .font(.system(size: 25, weight: .medium))
            .foregroundStyle(.white)
            .padding(.trailing, 46)
            .frame(width: 1920, height: 56)
            .background(Color.white.opacity(0.07))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }

            RemoteView(tv: tv, ui: ui)
                .environment(\.colorScheme, .light) // aluminium body pops on the dark backdrop
                .scaleEffect(scale, anchor: .top)
                .shadow(color: .black.opacity(0.6), radius: 40, y: 24)
                .frame(width: 215)
                .offset(x: iconX - 215 / 2 + 1, y: 70)
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
    }
}

@main
struct MakeBanner {
    static func main() {
        MainActor.assumeIsolated {
            // Show a connected TV with a friendly name in the remote's status line.
            let demo = TVDevice(kind: .samsung, name: "Living Room TV", host: "0.0.0.0")
            UserDefaults.standard.set(try! JSONEncoder().encode(demo), forKey: "device")
            for copy in copies {
                let tv = TVClient()
                tv.backend(state: .connected)
                let r = ImageRenderer(content: Banner(copy: copy, tv: tv))
                r.scale = 1
                let rep = NSBitmapImageRep(data: r.nsImage!.tiffRepresentation!)!
                try! rep.representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: "docs/\(copy.file)"))
                print("docs/\(copy.file)", rep.pixelsWide, "x", rep.pixelsHigh)
            }
            UserDefaults.standard.removeObject(forKey: "device")
        }
    }
}
