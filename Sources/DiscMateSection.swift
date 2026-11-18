import SwiftUI

/// A titled card with an explicit, simple accessibility hierarchy.
/// Native GroupBox currently crashes the tested Sky accessibility reader even
/// with a single Text child; keep the section title and content as siblings.
struct DiscMateSection<Content: View>: View {
    let title: String
    private let tip: String?
    private let content: Content
    @State private var showingTip = false

    init(_ title: String, tip: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tip = tip
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .accessibilityAddTraits(.isHeader)
                if let tip {
                    Button { showingTip.toggle() } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("查看\(title)提示")
                    .help("查看提示")
                    .popover(isPresented: $showingTip, arrowEdge: .bottom) {
                        Text(tip)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 310, alignment: .leading)
                            .padding(14)
                    }
                }
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
