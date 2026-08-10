import SwiftUI

struct WorkspaceNavigationRail: View {
    let features: WorkspaceFeatures
    @ObservedObject var routeState: WorkspaceRouteState
    @ObservedObject var transitionCoordinator: WorkspaceRouteTransitionCoordinator
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(WorkspaceRoute.visibleRoutes(features)) { route in
                routeButton(route)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.horizontal, 8)
        .frame(width: WorkspaceWindowLayout.railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.elevatedSurface)
        // An overlay is inside the rail's fixed width; it must not change the
        // 64 + 980 window calculation.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.separator)
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("工作空间导航")
    }

    private func routeButton(_ route: WorkspaceRoute) -> some View {
        let metadata = route.railMetadata
        let isSelected = routeState.route == route
        return Button {
            Task { _ = await transitionCoordinator.requestActivation(route) }
        } label: {
            Image(systemName: metadata.symbolName)
                .font(.system(size: 17, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                .frame(width: 40, height: 40)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(theme.rangePreviewFill)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(metadata.help)
        .accessibilityLabel(metadata.accessibilityLabel)
        .accessibilityValue(isSelected ? WorkspaceRailAppearance.selectedAccessibilityValue : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("workspace-route-\(route.rawValue)")
    }
}
