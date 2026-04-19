import SwiftUI
import SceneKit
import UIKit

// MARK: - Palette (match CoursePickerView)

private enum EnginePalette {
    static let background = Color.black
    static let card = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let accent = Color(red: 0.114, green: 0.725, blue: 0.329)
    static let primaryText = Color.white
    static let secondaryText = Color(white: 0.7)
    static let muted = Color(white: 0.5)
}

// MARK: - Data models

struct EngineEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let iconSystemName: String
    let modelResource: String
    let partsResource: String
    let hasShoppableParts: Bool

    static let jetta = EngineEntry(
        id: "jetta_25_i5",
        title: "2011 Volkswagen Jetta 2.5L Inline-5",
        subtitle: "Transverse-mounted 07K / CBTA. Tap any part for OEM and aftermarket sourcing.",
        iconSystemName: "gearshape.2.fill",
        modelResource: "jetta_25_i5",
        partsResource: "jetta_25_i5.parts",
        hasShoppableParts: true
    )

    static let civic = EngineEntry(
        id: "civic_18_i4",
        title: "2007 Honda Civic 1.8L Inline-4",
        subtitle: "R18A1 SOHC i-VTEC. Tap any part for OEM and aftermarket sourcing.",
        iconSystemName: "gearshape.fill",
        modelResource: "civic_18_i4",
        partsResource: "civic_18_i4.parts",
        hasShoppableParts: true
    )

    static let v8HotRod = EngineEntry(
        id: "v8-hot-rod",
        title: "American Pushrod V8",
        subtitle: "Classic naturally-aspirated V8. Reference model.",
        iconSystemName: "flame.fill",
        modelResource: "v8-hot-rod",
        partsResource: "v8-hot-rod.parts",
        hasShoppableParts: false
    )

    static let dieselInline6 = EngineEntry(
        id: "diesel-inline-6",
        title: "Heavy-Duty Diesel Inline-6",
        subtitle: "Commercial-duty straight-six diesel. Reference model.",
        iconSystemName: "fuelpump.fill",
        modelResource: "diesel-inline-6",
        partsResource: "diesel-inline-6.parts",
        hasShoppableParts: false
    )

    static let rb26det = EngineEntry(
        id: "rb26det",
        title: "Nissan RB26DETT 2.6L Inline-6",
        subtitle: "Twin-turbocharged inline-6 (Skyline GT-R R32–R34). Reference model.",
        iconSystemName: "bolt.fill",
        modelResource: "rb26det",
        partsResource: "rb26det.parts",
        hasShoppableParts: false
    )

    static let v12 = EngineEntry(
        id: "v12",
        title: "Aston Martin DB11 5.2L V12",
        subtitle: "Twin-turbocharged 5.2L V12. Reference model.",
        iconSystemName: "crown.fill",
        modelResource: "v12",
        partsResource: "v12.parts",
        hasShoppableParts: false
    )

    static let v8Block = EngineEntry(
        id: "v8-block-disassembled",
        title: "V8 Block — Disassembled View",
        subtitle: "Block and rotating assembly exploded for inspection. Reference model.",
        iconSystemName: "wrench.and.screwdriver.fill",
        modelResource: "v8-block-disassembled",
        partsResource: "v8-block-disassembled.parts",
        hasShoppableParts: false
    )

    static let all: [EngineEntry] = [
        .jetta, .civic, .v8HotRod, .dieselInline6, .rb26det, .v12, .v8Block
    ]
}

struct PartsManifest: Decodable {
    let engine: String
    let parts: [EnginePart]
}

struct EnginePart: Decodable, Identifiable, Hashable {
    let id: String
    let display: String
    let sub: String
    let aliases: [String]
    let buy: PartBuy?

    static func == (lhs: EnginePart, rhs: EnginePart) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct PartBuy: Decodable, Hashable {
    let displayName: String?
    let category: String?
    let purchasable: Bool?
    let oemPn: String?
    let aftermarketPn: String?
    let typicalPriceUsd: String?
    let replacementUrgency: String?
    let links: [PartLink]

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case category
        case purchasable
        case oemPn = "oem_pn"
        case aftermarketPn = "aftermarket_pn"
        case typicalPriceUsd = "typical_price_usd"
        case replacementUrgency = "replacement_urgency"
        case links
    }
}

struct PartLink: Decodable, Hashable, Identifiable {
    var id: String { url }
    let retailer: String
    let url: String
    let note: String?
    let verification: LinkVerification?
}

struct LinkVerification: Decodable, Hashable {
    let verdict: String?
    let confidence: Double?
    let reasoning: String?
}

// MARK: - Parts loader

final class PartsStore {
    let manifest: PartsManifest
    let byID: [String: EnginePart]

    init(manifest: PartsManifest) {
        self.manifest = manifest
        self.byID = Dictionary(uniqueKeysWithValues: manifest.parts.map { ($0.id, $0) })
    }

    static func load(resource: String) -> PartsStore? {
        let url = Bundle.main.url(forResource: resource, withExtension: "json")
            ?? Bundle.main.url(forResource: resource, withExtension: "json", subdirectory: "EngineAssets")
        guard let url else {
            print("PartsStore: missing \(resource).json in bundle")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(PartsManifest.self, from: data)
            return PartsStore(manifest: manifest)
        } catch {
            print("PartsStore decode error: \(error)")
            return nil
        }
    }

    func part(for nodeName: String) -> EnginePart? {
        if let hit = byID[nodeName] { return hit }
        let stripped = Self.stripSuffixes(nodeName)
        return byID[stripped]
    }

    private static func stripSuffixes(_ s: String) -> String {
        var name = s
        for suffix in ["_mesh", "_curve"] {
            if name.hasSuffix(suffix) {
                name.removeLast(suffix.count)
                break
            }
        }
        return name
    }
}

// MARK: - Picker (embeddable — used inside Otto/ExplodedView)

struct EnginesPicker: View {
    @State private var activeEngine: EngineEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(EngineEntry.all) { engine in
                    Button { activeEngine = engine } label: {
                        engineCard(engine)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .fullScreenCover(item: $activeEngine) { engine in
            EngineDetailView(engine: engine)
        }
    }

    private func engineCard(_ engine: EngineEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OttoColor.accent.opacity(0.18))
                    .frame(width: 52, height: 52)
                Image(systemName: engine.iconSystemName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(OttoColor.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OttoColor.ink)
                Text(engine.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(OttoColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OttoColor.ink4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(OttoColor.fog2.opacity(0.22), lineWidth: 1)
                )
        )
    }
}

// MARK: - Detail (3D) view

struct EngineDetailView: View {
    let engine: EngineEntry
    @Environment(\.dismiss) private var dismiss

    @State private var store: PartsStore?
    @State private var selectedPart: EnginePart?
    @State private var highlightedNodeName: String?
    @State private var isExploded: Bool = false

    var body: some View {
        ZStack {
            EnginePalette.background.ignoresSafeArea()

            if let store {
                EngineSceneView(
                    modelResource: engine.modelResource,
                    highlightedNodeName: highlightedNodeName,
                    isExploded: isExploded,
                    onTap: { nodeName in
                        guard engine.hasShoppableParts,
                              let part = store.part(for: nodeName) else { return }
                        highlightedNodeName = nodeName
                        selectedPart = part
                    }
                )
                .ignoresSafeArea()
            } else {
                ProgressView().tint(EnginePalette.accent)
            }

            VStack {
                topBar
                Spacer()
                if store != nil {
                    VStack(spacing: 10) {
                        explodeToggle
                        hintBar
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            store = PartsStore.load(resource: engine.partsResource)
        }
        .sheet(item: $selectedPart, onDismiss: { highlightedNodeName = nil }) { part in
            PartSheetView(part: part)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(EnginePalette.primaryText)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(engine.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(EnginePalette.primaryText)
                if let count = store?.manifest.parts.count {
                    Text("\(count) parts")
                        .font(.system(size: 11))
                        .foregroundStyle(EnginePalette.muted)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var hintBar: some View {
        Text(engine.hasShoppableParts
             ? "Pinch to zoom · drag to rotate · tap a part"
             : "Pinch to zoom · drag to rotate")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(EnginePalette.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .padding(.bottom, 24)
    }

    private var explodeToggle: some View {
        Button {
            isExploded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExploded
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .bold))
                Text(isExploded ? "Assembled View" : "Exploded View")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(OttoColor.navyDeep)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(Capsule().fill(OttoColor.orange))
            .shadow(color: OttoColor.orange.opacity(0.45), radius: 14, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Part sheet

struct PartSheetView: View {
    let part: EnginePart
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            EnginePalette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let buy = part.buy {
                        metaRow(buy)
                        if buy.links.isEmpty {
                            Text("No buy links available.")
                                .font(.footnote)
                                .foregroundStyle(EnginePalette.muted)
                        } else {
                            linksSection(buy.links)
                        }
                        if buy.purchasable == false {
                            Text("This is typically a diagnostic-only part — not commonly replaced directly.")
                                .font(.footnote)
                                .foregroundStyle(EnginePalette.muted)
                                .padding(.top, 4)
                        }
                    } else {
                        Text("No purchase data available for this part.")
                            .font(.footnote)
                            .foregroundStyle(EnginePalette.muted)
                    }
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(part.buy?.displayName ?? part.display)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(EnginePalette.primaryText)
            Text(part.sub)
                .font(.footnote)
                .foregroundStyle(EnginePalette.secondaryText)
        }
    }

    private func metaRow(_ buy: PartBuy) -> some View {
        let chips: [(String, String)] = [
            buy.typicalPriceUsd.map { ("dollarsign.circle", $0) },
            buy.oemPn.map { ("number", "OEM \($0)") },
            buy.aftermarketPn.map { ("number", "A/M \($0)") },
            buy.replacementUrgency.map { ("exclamationmark.triangle", $0) },
        ].compactMap { $0 }

        return FlowLayout(spacing: 8) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 6) {
                    Image(systemName: pair.0).font(.system(size: 10, weight: .bold))
                    Text(pair.1).font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(EnginePalette.card))
                .foregroundStyle(EnginePalette.secondaryText)
            }
        }
    }

    private func linksSection(_ links: [PartLink]) -> some View {
        let sorted = links.sorted { a, b in
            let va = (a.verification?.verdict ?? "zzz")
            let vb = (b.verification?.verdict ?? "zzz")
            let wa = va == "match" ? 0 : va == "uncertain" ? 1 : 2
            let wb = vb == "match" ? 0 : vb == "uncertain" ? 1 : 2
            return wa < wb
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("RETAILERS")
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.5)
                .foregroundStyle(EnginePalette.muted)
                .padding(.top, 8)
            ForEach(sorted) { link in
                Button {
                    if let url = URL(string: link.url) { openURL(url) }
                } label: {
                    linkRow(link)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func linkRow(_ link: PartLink) -> some View {
        HStack(alignment: .center, spacing: 12) {
            verdictBadge(link.verification?.verdict)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.retailer)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(EnginePalette.primaryText)
                if let note = link.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(EnginePalette.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(EnginePalette.accent)
        }
        .padding(14)
        .background(EnginePalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func verdictBadge(_ verdict: String?) -> some View {
        let color: Color = {
            switch verdict {
            case "match": return EnginePalette.accent
            case "mismatch": return Color(red: 0.85, green: 0.3, blue: 0.3)
            case "uncertain": return Color.orange
            default: return EnginePalette.muted
            }
        }()
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

// MARK: - Simple flow layout for chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var rowW: CGFloat = 0
        var totalH: CGFloat = 0
        var rowH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if rowW + sz.width > maxW && rowW > 0 {
                totalH += rowH + spacing
                rowW = 0
                rowH = 0
            }
            rowW += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        totalH += rowH
        return CGSize(width: maxW == .infinity ? rowW : maxW, height: totalH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
