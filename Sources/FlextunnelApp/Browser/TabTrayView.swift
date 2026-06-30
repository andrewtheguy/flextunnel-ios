import SwiftUI
import WebKit

/// Firefox iOS / Onion Browser style tab tray: a grid of open tabs as title/URL
/// cards. Tap a card to switch, the close button to drop a tab, and "+" to open a
/// new one. Presented full-screen from the bottom toolbar's tab button.
struct TabTrayView: View {
    @Bindable var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.tabs) { tab in
                        TabCard(
                            tab: tab,
                            isSelected: tab.id == model.selectedID,
                            showClose: model.tabs.count > 1,
                            onSelect: {
                                model.select(tab)
                                dismiss()
                            },
                            onClose: { model.closeTab(tab) })
                    }
                }
                .padding(16)
            }
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.addTab()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!model.proxyIsAvailable)
                    .accessibilityLabel("New tab")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct TabCard: View {
    let tab: BrowserTab
    let isSelected: Bool
    let showClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text(tab.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if showClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close tab")
                    }
                }

                Text(tab.page.url?.host() ?? "New Tab")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
