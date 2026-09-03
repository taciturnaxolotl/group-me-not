import SwiftUI

/// One row of the menu under a pressed message.
nonisolated struct MessageAction: Identifiable {
    var id: String { title }
    var title: String
    var symbol: String
    var isDestructive: Bool = false
    var perform: () -> Void

    init(_ title: String, symbol: String, isDestructive: Bool = false,
         perform: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.isDestructive = isDestructive
        self.perform = perform
    }
}

/// What a long press puts on screen: a floating row of reactions above the
/// message, and a menu card below it.
///
/// Two separate pieces rather than one popover, which is the shape Messages
/// uses and the reason it reads so well: the bubble stays exactly where it was,
/// visible between them, so there is never a moment of wondering which message
/// is being acted on. A popover puts a box with an arrow *over* the transcript
/// and answers that question with a pointer instead.
///
/// The backdrop is a dim rather than a blur for the same reason. Blurring hides
/// the one thing worth keeping legible.
struct MessageActionsOverlay: View {
    /// The pressed row's frame, in global coordinates.
    let anchor: CGRect
    /// The five glyphs the quick row offers.
    let glyphs: [String]
    /// The glyph this user already holds, drawn as selected. Picking it again
    /// clears the reaction.
    let selected: String?
    let actions: [MessageAction]
    var onPick: (String) -> Void
    var onMore: () -> Void
    var onDismiss: () -> Void

    @ScaledMetric(relativeTo: .title2) private var glyphSlot: CGFloat = 38

    /// Measured rather than guessed, because both pieces are positioned by
    /// their centres and a centre needs a height.
    @State private var pillSize: CGSize = .zero
    @State private var cardSize: CGSize = .zero
    @State private var hasAppeared = false

    /// Room between the bubble and each floating piece.
    private static let gap: CGFloat = 10
    private static let margin: CGFloat = 12
    /// How far the undimmed hole runs past the bubble.
    private static let halo: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                backdrop(in: geo)

                pill
                    .onGeometryChange(for: CGSize.self, of: \.size) { pillSize = $0 }
                    .position(
                        x: clampedX(pillSize.width, in: geo),
                        y: pillY(in: geo))

                if !actions.isEmpty {
                    card
                        .onGeometryChange(for: CGSize.self, of: \.size) { cardSize = $0 }
                        .position(
                            x: clampedX(cardSize.width, in: geo),
                            y: cardY(in: geo))
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.94, anchor: anchorPoint(in: geo))
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { hasAppeared = true }
        }
    }

    // MARK: Pieces

    /// One shape rather than a rectangle with a hole blended out of it: an
    /// even-odd fill *is* a rectangle with a hole in it, and it lands in the
    /// same coordinates the pill and card are placed in.
    ///
    /// Dimming the one bubble the menu is about would be dimming the answer to
    /// "which message is this?", so the message keeps its brightness and, from
    /// the row's own side, its swell. The hole runs past the bubble by `halo`
    /// to leave the swell somewhere to go.
    private func backdrop(in geo: GeometryProxy) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: geo.size))
            path.addRoundedRect(
                in: anchor.insetBy(dx: -Self.halo, dy: -Self.halo),
                cornerSize: CGSize(width: 22, height: 22),
                style: .continuous)
        }
        .fill(.black.opacity(0.28), style: FillStyle(eoFill: true))
        .contentShape(.rect)
        .onTapGesture(perform: onDismiss)
        .accessibilityLabel("Dismiss")
        .accessibilityAddTraits(.isButton)
    }

    /// Five glyphs and a More button, all visible at once. Nothing scrolls, so
    /// nothing is hiding.
    private var pill: some View {
        HStack(spacing: 2) {
            ForEach(glyphs, id: \.self) { glyph in
                Button { onPick(glyph) } label: {
                    ReactionGlyph(glyph: glyph, size: glyphSlot * 0.66)
                        .frame(width: glyphSlot, height: glyphSlot)
                        .background {
                            if glyph == selected {
                                Circle().fill(Color.accentColor.opacity(0.28))
                            }
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(glyph)
                .accessibilityAddTraits(glyph == selected ? [.isSelected] : [])
            }

            Button(action: onMore) {
                Image(systemName: "plus")
                    .font(.system(size: glyphSlot * 0.4, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: glyphSlot, height: glyphSlot)
                    .background(Circle().fill(.quaternary))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More reactions")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    /// Icon first, then the word. That is the order in the system menus this is
    /// modelled on, and it gives the eye a column of symbols to scan.
    private var card: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 {
                    Divider().padding(.leading, 52)
                }
                Button(action: action.perform) {
                    HStack(spacing: 14) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 17))
                            .frame(width: 22)
                        Text(action.title)
                            .font(.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(action.isDestructive ? AnyShapeStyle(Color.red)
                                                          : AnyShapeStyle(.primary))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 250)
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    // MARK: Placement

    /// Horizontally centred on the message, then pushed back inside the screen.
    /// Following the bubble rather than sitting in the middle is what ties the
    /// controls to the thing they act on.
    private func clampedX(_ width: CGFloat, in geo: GeometryProxy) -> CGFloat {
        guard width > 0 else { return anchor.midX }
        let half = width / 2
        return min(max(anchor.midX, half + Self.margin), geo.size.width - half - Self.margin)
    }

    /// Above the message, unless there is no room up there.
    private func pillY(in geo: GeometryProxy) -> CGFloat {
        let half = pillSize.height / 2
        let wanted = anchor.minY - Self.gap - half
        let ceiling = geo.safeAreaInsets.top + Self.margin + half
        return max(wanted, ceiling)
    }

    /// Below the message, unless there is no room down there. Clamped last so a
    /// message near the foot of the screen keeps its whole menu on screen rather
    /// than half of it under the composer.
    private func cardY(in geo: GeometryProxy) -> CGFloat {
        let half = cardSize.height / 2
        let wanted = anchor.maxY + Self.gap + half
        let floor = geo.size.height - geo.safeAreaInsets.bottom - Self.margin - half
        return min(wanted, floor)
    }

    /// Grow out of the message rather than out of the middle of the screen.
    private func anchorPoint(in geo: GeometryProxy) -> UnitPoint {
        guard geo.size.width > 0, geo.size.height > 0 else { return .center }
        return UnitPoint(x: anchor.midX / geo.size.width, y: anchor.midY / geo.size.height)
    }
}
