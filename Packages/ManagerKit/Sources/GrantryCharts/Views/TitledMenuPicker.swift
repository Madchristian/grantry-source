import SwiftUI

/// Auswahlmenü mit sichtbarem Titel daneben, etwa „Takt“ in der Tab-Leiste des Task-Managers. Das Menü trägt den Titel
/// auch als eigene Beschriftung: Über den sichtbaren Text allein (AXTitleUIElement) liest VoiceOver ihn zwar, die UI-Tests
/// der Abnahme sehen aber ein Bedienelement ohne Beschriftung (#566).
public struct TitledMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    public init(_ title: String, selection: Binding<Value>, options: [(value: Value, label: String)]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        Picker(selection: $selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(verbatim: options[index].label).tag(options[index].value)
            }
        } label: {
            Text(verbatim: title)
        }
        .pickerStyle(.menu)
        .accessibilityLabel(Text(verbatim: title))
    }
}
