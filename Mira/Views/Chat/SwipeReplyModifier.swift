import SwiftUI

/// A horizontal gesture coexists with vertical scrolling and the system back gesture.
struct SwipeReplyModifier: ViewModifier {
    let enabled: Bool
    let onReply: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var armed = false

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                if offset < -12 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(armed ? Color.iMessageBlue : Color.secondary)
                        .frame(width: 36, height: 36)
                        .background(Color(.secondarySystemBackground), in: Circle())
                        .opacity(min(1, Double(-offset / 52)))
                        .accessibilityHidden(true)
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 24)
                .onChanged { value in
                    guard enabled, value.translation.width < 0,
                          abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    offset = max(-72, value.translation.width * 0.75)
                    let crossed = offset <= -52
                    if crossed && !armed { Haptics.tap() }
                    armed = crossed
                }
                .onEnded { value in
                    let shouldReply = enabled && armed && value.translation.width < -52
                        && abs(value.translation.width) > abs(value.translation.height) * 1.5
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                        offset = 0
                        armed = false
                    }
                    if shouldReply { onReply() }
                })
            .accessibilityActions {
                if enabled {
                    Button("回复", action: onReply)
                }
            }
    }
}
