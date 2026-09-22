import SwiftUI

/// 取自 VoltAgent/awesome-design-md 的 Apple DESIGN.md。
/// 浅色用羊皮纸底和 Action Blue；深色用同一套近黑瓷砖，链接改用 Sky Link Blue。
struct ThemePalette: Equatable {
    var accent: Color
    var accentSoft: Color
    var accentDeep: Color
    var background: Color
    var sidebar: Color
    var chrome: Color
    var surface: Color
    var text: Color
    var text2: Color
    var text3: Color
    var separator: Color
    var icon: Color
    var searchFill: Color
    var waveIdle: Color
    var knob: Color
    var orange: Color
    var green: Color
    var successSoft: Color
    var successInk: Color
    /// 视频画面保持纯黑，浅色和深色都不铺渐变。
    var canvas: Color

    static let light = ThemePalette(
        accent: Color(hex: 0x0066CC),
        accentSoft: Color(hex: 0x0066CC).opacity(0.12),
        accentDeep: Color(hex: 0x0071E3),
        background: Color(hex: 0xFFFFFF),
        sidebar: Color(hex: 0xF5F5F7),
        chrome: Color(hex: 0xF5F5F7),
        surface: Color(hex: 0xFAFAFC),
        text: Color(hex: 0x1D1D1F),
        text2: Color(hex: 0x333333),
        text3: Color(hex: 0x7A7A7A),
        separator: Color(hex: 0xE0E0E0),
        icon: Color(hex: 0x1D1D1F),
        searchFill: Color(hex: 0xF5F5F7),
        waveIdle: Color(hex: 0xE0E0E0),
        knob: Color(hex: 0xFFFFFF),
        orange: Color(hex: 0xFF9F0A),
        green: Color(hex: 0x34C759),
        successSoft: Color(hex: 0x34C759).opacity(0.14),
        successInk: Color(hex: 0x248A3D),
        canvas: Color(hex: 0x000000)
    )

    static let dark = ThemePalette(
        accent: Color(hex: 0x2997FF),
        accentSoft: Color(hex: 0x2997FF).opacity(0.20),
        accentDeep: Color(hex: 0x2997FF),
        background: Color(hex: 0x1D1D1F),
        sidebar: Color(hex: 0x272729),
        chrome: Color(hex: 0x000000),
        surface: Color(hex: 0x2A2A2C),
        text: Color(hex: 0xFFFFFF),
        text2: Color(hex: 0xCCCCCC),
        text3: Color(hex: 0xCCCCCC).opacity(0.62),
        separator: Color.white.opacity(0.12),
        icon: Color(hex: 0xFFFFFF),
        searchFill: Color(hex: 0x2A2A2C),
        waveIdle: Color.white.opacity(0.16),
        knob: Color(hex: 0xF5F5F7),
        orange: Color(hex: 0xFF9F0A),
        green: Color(hex: 0x30D158),
        successSoft: Color(hex: 0x30D158).opacity(0.20),
        successInk: Color(hex: 0x30D158),
        canvas: Color(hex: 0x000000)
    )

    static func resolve(_ mode: AppearanceMode, system: ColorScheme) -> ThemePalette {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .system: return system == .dark ? .dark : .light
        }
    }
}

extension AppearanceMode {
    /// `nil` 表示不要覆盖系统外观。
    var preferred: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue = ThemePalette.light
}

extension EnvironmentValues {
    var theme: ThemePalette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct IconButton: View {
    var systemName: String
    var help: String
    var active = false
    var prominent = false
    var loading = false
    var action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button {
            guard !loading else { return }
            action()
        } label: {
            Group {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(prominent ? .white : theme.icon)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: prominent ? 15 : 13, weight: .semibold))
                }
            }
            .frame(width: prominent ? 40 : 34, height: prominent ? 34 : 30)
            .foregroundStyle(prominent ? Color.white : (active ? theme.accent : theme.icon))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? theme.accent : (active ? theme.accentSoft : (hovering ? theme.sidebar : Color.clear)))
            )
            .overlay(alignment: .bottom) {
                if active && !prominent {
                    Capsule().fill(theme.accent).frame(width: 12, height: 2).offset(y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .overlay(alignment: .top) {
            if hovering {
                HoverTip(text: help)
                    .offset(y: -28)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(hovering ? 4 : 0)
        .accessibilityLabel(help)
    }
}

struct HoverTip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 3
    var centers = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 640
        let rows = rows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        return CGSize(width: maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            if centers {
                x += max(0, (bounds.width - row.width) / 2)
            }
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [(width: CGFloat, height: CGFloat, items: [(index: Int, size: CGSize)])] {
        var result: [(width: CGFloat, height: CGFloat, items: [(index: Int, size: CGSize)])] = []
        var current: [(index: Int, size: CGSize)] = []
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        func flush() {
            guard !current.isEmpty else { return }
            let width = max(0, x - spacing)
            result.append((width, rowHeight, current))
            current = []
            x = 0
            rowHeight = 0
        }
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.isEmpty, x + size.width > maxWidth {
                flush()
            }
            current.append((index, size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        flush()
        return result
    }
}

extension View {
    /// 画面上的字幕没有底衬时，用四向描边保证浅色和深色画面都能读清。
    @ViewBuilder
    func captionOutline(_ enabled: Bool) -> some View {
        if enabled {
            self
                .shadow(color: .black, radius: 0, x: 1.1, y: 1.1)
                .shadow(color: .black, radius: 0, x: -1.1, y: -1.1)
                .shadow(color: .black, radius: 0, x: 1.1, y: -1.1)
                .shadow(color: .black, radius: 0, x: -1.1, y: 1.1)
                .shadow(color: .black.opacity(0.9), radius: 3, y: 1)
        } else {
            self.shadow(color: .black.opacity(0.45), radius: 6, y: 1)
        }
    }
}

struct WordLine: View {
    var text: String
    var fontSize: CGFloat
    var color: Color
    var weight: Font.Weight = .semibold
    var centered = false
    var outlined = false
    var onLookup: (String) -> Void

    var body: some View {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        FlowLayout(spacing: 6, lineSpacing: 4, centers: centered) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                Text(word)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(color)
                    .captionOutline(outlined)
                    .onTapGesture { onLookup(word) }
                    .contextMenu {
                        Button("在欧陆词典中查询") { onLookup(word) }
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
