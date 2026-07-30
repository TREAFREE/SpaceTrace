import AppKit
import SwiftUI

enum SpaceTraceDesign {
    static let contentMaxWidth: CGFloat = 1_040
    static let pagePadding: CGFloat = 32
    static let sectionSpacing: CGFloat = 24
    static let panelRadius: CGFloat = 16
    static let compactRadius: CGFloat = 12
}

extension Font {
    static let spaceTraceHero = Font.system(
        .largeTitle,
        design: .rounded,
        weight: .bold
    )
    static let spaceTraceSectionTitle = Font.system(
        .title3,
        design: .rounded,
        weight: .semibold
    )
    static let spaceTraceCardTitle = Font.system(
        .headline,
        design: .rounded,
        weight: .semibold
    )
    static let spaceTraceMetric = Font.system(
        .title3,
        design: .rounded,
        weight: .semibold
    ).monospacedDigit()
}

struct SpaceTracePageHeader: View {
    let eyebrow: LocalizedStringKey
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(eyebrow, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .textCase(.uppercase)
                .accessibilityHidden(true)

            Text(title)
                .font(.spaceTraceHero)
                .accessibilityAddTraits(.isHeader)

            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 720, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SpaceTracePageBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.08),
                    Color.accentColor.opacity(0.025),
                    .clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct SpaceTracePanelGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            configuration.label
                .font(.spaceTraceSectionTitle)
            configuration.content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spaceTracePanel()
    }
}

private struct SpaceTracePanelModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(
                .regularMaterial,
                in: RoundedRectangle(
                    cornerRadius: SpaceTraceDesign.panelRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: SpaceTraceDesign.panelRadius,
                    style: .continuous
                )
                .strokeBorder(
                    Color.primary.opacity(contrast == .increased ? 0.28 : 0.10),
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
            }
            .shadow(
                color: .black.opacity(contrast == .increased ? 0 : 0.06),
                radius: 14,
                y: 6
            )
    }
}

private struct SpaceTraceCompactSurfaceModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.76),
                in: RoundedRectangle(
                    cornerRadius: SpaceTraceDesign.compactRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: SpaceTraceDesign.compactRadius,
                    style: .continuous
                )
                .strokeBorder(
                    Color.primary.opacity(contrast == .increased ? 0.24 : 0.08),
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
            }
    }
}

extension View {
    func spaceTracePanel() -> some View {
        modifier(SpaceTracePanelModifier())
    }

    func spaceTraceCompactSurface() -> some View {
        modifier(SpaceTraceCompactSurfaceModifier())
    }

    func spaceTracePageLayout() -> some View {
        padding(SpaceTraceDesign.pagePadding)
            .frame(
                maxWidth: SpaceTraceDesign.contentMaxWidth,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
