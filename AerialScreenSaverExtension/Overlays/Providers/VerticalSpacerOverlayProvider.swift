//
//  VerticalSpacerOverlayProvider.swift
//  AerialScreenSaverExtension
//
//  Provider for vertical spacer overlay type.
//

import SwiftUI

struct VerticalSpacerOverlayProvider: OverlayTypeProvider {
    static let kind: OverlayKind = .verticalSpacer

    static func makeView(instance: OverlayInstance, state: OverlayState) -> AnyView {
        let height = instance.typeSettings["height"]?.asInt ?? 50
        return AnyView(
            Color.clear.frame(height: CGFloat(height))
        )
    }

    static func makeSettingsView(instance: Binding<OverlayInstance>) -> AnyView {
        AnyView(VerticalSpacerSettingsContent(instance: instance))
    }
}

private struct VerticalSpacerSettingsContent: View {
    @Binding var instance: OverlayInstance

    private var height: Int {
        instance.typeSettings["height"]?.asInt ?? 50
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Height (px)")
                Spacer()
                TextField("", value: Binding(
                    get: { height },
                    set: { instance.typeSettings["height"] = .int($0) }
                ), formatter: NumberFormatter())
                .frame(width: 60)
                .textFieldStyle(.roundedBorder)

                Stepper("", value: Binding(
                    get: { height },
                    set: { instance.typeSettings["height"] = .int(min(500, max(10, $0))) }
                ), in: 10...500, step: 10)
                .labelsHidden()
            }
        }
    }
}
