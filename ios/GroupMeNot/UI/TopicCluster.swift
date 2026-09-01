import SwiftUI

/// A group and its topics as one face: small bubbles packed into a circle.
///
/// The arrangement is Vogel's model, the same phyllotaxis the seeds of a
/// sunflower use. Each bubble sits one golden angle round from the last at a
/// radius proportional to the square root of its index, which is the one
/// arrangement that never forms rows: any rational fraction of a turn lines the
/// points up into spokes, and the golden ratio is precisely the number that is
/// hardest to approximate with a fraction. So the pattern reads as an even
/// scatter at every count, from three bubbles to a dozen, with no spacing to
/// hand-tune per case.
///
/// The group's own picture takes the centre, since index zero has radius zero
/// and the middle of a cluster is where the eye starts.
struct TopicCluster: View {
    /// Centre first, then outwards.
    let faces: [ConversationRow]
    let size: CGFloat

    /// Past this the bubbles are too small to be pictures of anything.
    private static let limit = 7

    /// π(3 − √5). The angle between consecutive seeds.
    private static let goldenAngle: CGFloat = .pi * (3 - sqrt(5))

    var body: some View {
        let shown = Array(faces.prefix(Self.limit))
        let count = max(shown.count, 1)
        // Each bubble gets its share of the disc, plus a little for the gaps.
        let bubble = size / (sqrt(CGFloat(count)) + 1.1)
        // The band the centres may occupy, so the outermost bubble stops at the
        // rim rather than hanging over it.
        let band = (size - bubble) / 2

        ZStack {
            Circle().fill(Color(.tertiarySystemFill))
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, face in
                let radius = band * sqrt(CGFloat(index) / CGFloat(count))
                let angle = CGFloat(index) * Self.goldenAngle
                Avatar(
                    url: face.avatarURL,
                    name: face.name,
                    size: bubble,
                    isGroup: face.isGroup
                )
                .offset(x: radius * cos(angle), y: radius * sin(angle))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}
