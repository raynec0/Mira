import SwiftUI

// MARK: - Liquid Glass（iOS 26+ 原生玻璃，旧系统回退到材质）

struct GlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(.secondarySystemBackground), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        } else {
            glassContent(content)
        }
    }

    @ViewBuilder
    private func glassContent(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
    }
}

/// Keep adjacent controls in one native glass rendering pass on newer SDKs.
struct GlassSurfaceGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func glass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(GlassModifier(shape: shape, interactive: interactive))
    }
}

// MARK: - 头像

struct AgentAvatar: View {
    let agent: AgentProfile
    var size: CGFloat = 40

    var body: some View {
        let color = Color(hex: agent.colorHex)
        Circle()
            .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .top, endPoint: .bottom))
            .overlay(Text(agent.emoji.isEmpty ? "🤖" : agent.emoji).font(.system(size: size * 0.48)))
            .frame(width: size, height: size)
    }
}

// MARK: - 气泡

struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: w * 0.05, y: 0))
        p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w * 0.2, y: h * 0.9))
        p.addQuadCurve(to: CGPoint(x: 0, y: h * 0.72), control: CGPoint(x: w * 0.45, y: h * 1.02))
        p.closeSubpath()
        return p
    }
}

struct BubbleView<Content: View>: View {
    let isUser: Bool
    let tail: Bool
    var isError = false
    let content: Content

    init(isUser: Bool, tail: Bool, isError: Bool = false, @ViewBuilder content: () -> Content) {
        self.isUser = isUser
        self.tail = tail
        self.isError = isError
        self.content = content()
    }

    private var fill: Color {
        if isError { return Color.red.opacity(0.85) }
        return isUser ? Color.iMessageBlue : Color.agentBubble
    }

    var body: some View {
        content
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(isUser || isError ? Color.white : Color.primary)
            .tint(isUser ? Color.white : Color.iMessageBlue)
            .background(alignment: isUser ? .bottomTrailing : .bottomLeading) {
                ZStack(alignment: isUser ? .bottomTrailing : .bottomLeading) {
                    RoundedRectangle(cornerRadius: 19, style: .continuous).fill(fill)
                    if tail {
                        BubbleTail()
                            .fill(fill)
                            .frame(width: 15, height: 17)
                            .scaleEffect(x: isUser ? 1 : -1, y: 1)
                            .offset(x: isUser ? 5 : -5, y: 0)
                    }
                }
            }
    }
}

extension View {
    func reactions(_ items: [String], isUser: Bool) -> some View {
        self
            .overlay(alignment: isUser ? .topLeading : .topTrailing) {
                if !items.isEmpty {
                    Text(items.suffix(3).joined())
                        .font(.system(size: 13))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(.systemGray5)))
                        .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 2))
                        .offset(x: isUser ? -12 : 12, y: -14)
                }
            }
            .padding(.top, items.isEmpty ? 0 : 12)
    }
}

// MARK: - 正在输入

struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 8, height: 8)
                        .opacity(reduceMotion ? 0.6 : 0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.8)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(alignment: .bottomLeading) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.agentBubble)
                    Circle().fill(Color.agentBubble).frame(width: 10, height: 10).offset(x: -3, y: 3)
                    Circle().fill(Color.agentBubble).frame(width: 5, height: 5).offset(x: -8, y: 8)
                }
            }
        }
        .padding(.leading, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在输入")
    }
}

// MARK: - 进度环

struct ProgressRing: View {
    let progress: Double
    var color: Color = .blue
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if progress >= 1 {
                Image(systemName: "checkmark").font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 设置风格图标

struct IconTile: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
    }
}
