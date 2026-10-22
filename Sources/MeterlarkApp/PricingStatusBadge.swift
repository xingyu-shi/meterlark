import AppKit
import SwiftUI

struct PricingStatusBadge: View {
    let snapshot: UsageSnapshot
    let unknownPricingModels: [String]
    let pricingIsStale: Bool
    let pricingComposition: PricingCatalogComposition?
    let pricingProviderDisplayNames: [String: String]
    let onUpdatePricing: (() -> Void)?
    let language: AppLanguage

    @State private var isPresented = false

    private var copy: L10n { L10n(language: language) }

    private var presentation: PricingStatusPresentation? {
        PricingStatusPresentation.make(
            snapshot: snapshot,
            unknownPricingModels: unknownPricingModels,
            pricingIsStale: pricingIsStale,
            pricingComposition: pricingComposition
        )
    }

    @ViewBuilder
    var body: some View {
        if let presentation {
            Button {
                isPresented.toggle()
            } label: {
                Image(systemName: presentation.kind.iconName)
                    .appFont(.icon)
                    .foregroundStyle(presentation.kind.tint)
                    .frame(width: 22, height: 22)
                    .background(presentation.kind.tint.opacity(0.12), in: Circle())
                    .overlay(
                        Circle()
                            .stroke(presentation.kind.tint.opacity(0.42), lineWidth: 0.7)
                    )
            }
            .buttonStyle(.plain)
            .help(copy.pricingStatusTitle(presentation.kind))
            .accessibilityLabel(copy.pricingStatusTitle(presentation.kind))
            .accessibilityValue(copy.pricingStatusModelCount(presentation.models.count))
            .accessibilityHint(isPresented ? copy.pricingStatusCollapseHint : copy.pricingStatusExpandHint)
            .popover(isPresented: $isPresented, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                PricingStatusDetails(
                    presentation: presentation,
                    pricingIsStale: pricingIsStale,
                    language: language,
                    pricingProviderDisplayNames: pricingProviderDisplayNames,
                    onUpdatePricing: onUpdatePricing.map { update in
                        {
                            isPresented = false
                            update()
                        }
                    }
                )
            }
        }
    }
}

private struct PricingStatusDetails: View {
    let presentation: PricingStatusPresentation
    let pricingIsStale: Bool
    let language: AppLanguage
    let pricingProviderDisplayNames: [String: String]
    let onUpdatePricing: (() -> Void)?

    private var copy: L10n { L10n(language: language) }
    private let visibleModelLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: presentation.kind.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(presentation.kind.tint)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.pricingStatusDetails)
                        .appFont(.metadataEmphasis)
                        .foregroundStyle(AppWindowTheme.primary)
                    Text(copy.pricingStatusDescription(
                        presentation.kind,
                        includesMixedSources: presentation.includesMixedSources
                    ))
                        .appFont(.metadata)
                        .foregroundStyle(AppWindowTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if pricingIsStale, let onUpdatePricing {
                Button(action: onUpdatePricing) {
                    Label(copy.updatePricing, systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(presentation.kind.tint)
            }

            Divider().overlay(AppWindowTheme.separator.opacity(0.8))

            if presentation.models.isEmpty {
                Text(copy.pricingStatusNoModelDetails)
                    .appFont(.metadata)
                    .foregroundStyle(AppWindowTheme.secondary)
            } else {
                HStack {
                    Text(copy.pricingStatusModels)
                    Spacer()
                    Text(copy.pricingStatusModelCount(presentation.models.count))
                }
                .appFont(.metadataEmphasis)
                .foregroundStyle(AppWindowTheme.secondary)

                ForEach(Array(presentation.models.prefix(visibleModelLimit))) { model in
                    PricingStatusModelRow(
                        model: model,
                        language: language,
                        pricingProviderDisplayNames: pricingProviderDisplayNames
                    )
                }

                if presentation.models.count > visibleModelLimit {
                    Text(copy.pricingStatusMoreModels(presentation.models.count - visibleModelLimit))
                        .appFont(.metadata)
                        .foregroundStyle(AppWindowTheme.secondary)
                }
            }
        }
        .frame(width: 270, alignment: .leading)
        .padding(10)
        .background(AppSurfacePanelBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppWindowTheme.separator, lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PricingStatusModelRow: View {
    let model: PricingStatusModel
    let language: AppLanguage
    let pricingProviderDisplayNames: [String: String]

    private var copy: L10n { L10n(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .appFont(.metadataEmphasis)
                        .foregroundStyle(AppWindowTheme.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        if !model.agent.isEmpty {
                            Text(model.agent)
                                .appFont(.metadata)
                                .foregroundStyle(AppWindowTheme.tertiary)
                        }
                }
                Spacer(minLength: 4)
                Text(copy.pricingStatusSourceLabel(
                    model.source,
                    providerNames: providerNames
                ))
                    .appFont(.metadata)
                    .foregroundStyle(model.source == .unknown ? PricingStatusKind.unknown.tint : AppWindowTheme.secondary)
                    .lineLimit(1)
            }

            if let selectedThreshold = model.pricingTierThreshold {
                Text(copy.pricingStatusTierLabel(
                    copy.pricingStatusSelectedTier,
                    threshold: NumberFormat.threshold(selectedThreshold)
                ))
                .appFont(.metadata)
                .foregroundStyle(AppWindowTheme.secondary)
            }

            if let backendThreshold = model.pricingBackendThreshold,
               backendThreshold != model.pricingTierThreshold {
                Text(copy.pricingStatusTierLabel(
                    copy.pricingStatusBackendTier,
                    threshold: NumberFormat.threshold(backendThreshold)
                ))
                .appFont(.metadata)
                .foregroundStyle(AppWindowTheme.tertiary)
            }

            if let reason = model.reason {
                Text(copy.pricingStatusReason(
                    reason,
                    missingRateComponents: model.missingRateComponents
                ))
                .appFont(.metadata)
                .foregroundStyle(PricingStatusKind.unknown.tint.opacity(0.9))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(7)
        .background(AppSurfacePanelBackground(opacity: 0.35))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.name), \(copy.pricingStatusSourceLabel(model.source, providerNames: providerNames))")
    }

    private var providerNames: [String] {
        model.pricingProviderIDs.map { pricingProviderDisplayNames[$0] ?? $0 }
    }
}

private extension PricingStatusKind {
    var iconName: String {
        switch self {
        case .stale: return "arrow.triangle.2.circlepath"
        case .approximate: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .mixed: return "circle.lefthalf.filled"
        }
    }

    var tint: Color {
        switch self {
        case .stale:
            return Color(nsColor: NSColor.systemBlue)
        case .approximate, .unknown:
            return Color(nsColor: NSColor.systemOrange)
        case .mixed:
            return AppWindowTheme.secondary
        }
    }
}
