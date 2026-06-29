import SwiftUI
import WebKit

/// Full-screen browser chrome over the proxied `WebPage`s: a lightweight tab
/// strip, the web view with a thin progress bar, and a bottom toolbar with
/// back/forward, reload-or-stop, and the address bar.
struct BrowserView: View {
    @State var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            TabStripView(model: model)
            Divider()

            let tab = model.selectedTab
            WebView(tab.page)
                .webViewBackForwardNavigationGestures(.enabled)
                .overlay(alignment: .top) { progressBar(for: tab.page) }
                .overlay(alignment: .bottom) { errorBanner(for: tab) }
                // Follow the selected tab: restart the navigation observer when it changes.
                .task(id: tab.id) { await tab.observeNavigations() }

            Divider()
            BottomToolbarView(model: model)
        }
    }

    @ViewBuilder
    private func progressBar(for page: WebPage) -> some View {
        if page.isLoading && page.estimatedProgress < 1 {
            ProgressView(value: page.estimatedProgress)
                .progressViewStyle(.linear)
        }
    }

    @ViewBuilder
    private func errorBanner(for tab: BrowserTab) -> some View {
        if let error = tab.lastError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error).font(.footnote).lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    tab.lastError = nil
                } label: {
                    Image(systemName: "xmark")
                }
            }
            .padding(10)
            .background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}

/// Horizontal strip of tab chips with a trailing "+" to open a new tab.
private struct TabStripView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { tab in
                    TabChip(
                        tab: tab,
                        isSelected: tab.id == model.selectedID,
                        onSelect: { model.select(tab) },
                        onClose: { model.closeTab(tab) },
                        showClose: model.tabs.count > 1)
                }
                Button(action: model.addTab) {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 28)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

private struct TabChip: View {
    let tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let showClose: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.displayTitle)
                .font(.footnote)
                .lineLimit(1)
                .frame(maxWidth: 140)
            if showClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? Color.accentColor : .clear))
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
    }
}

/// Back / forward / reload-or-stop controls plus the address bar.
private struct BottomToolbarView: View {
    @Bindable var model: BrowserModel
    @State private var editText = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        let tab = model.selectedTab
        HStack(spacing: 12) {
            Button { tab.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
            Button { tab.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
            Button {
                if tab.page.isLoading { tab.stop() } else { tab.reload() }
            } label: {
                Image(systemName: tab.page.isLoading ? "xmark" : "arrow.clockwise")
            }

            TextField("Search or enter address", text: $editText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    model.navigate(editText)
                    addressFocused = false
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        // Reflect the active tab's URL when not editing; show the raw URL while editing.
        .onChange(of: model.selectedID) { syncAddress(tab.page.url) }
        .onChange(of: tab.page.url) { if !addressFocused { syncAddress(tab.page.url) } }
        .onChange(of: addressFocused) { if addressFocused { editText = tab.page.url?.absoluteString ?? editText } }
        .onAppear { syncAddress(tab.page.url) }
    }

    private func syncAddress(_ url: URL?) {
        editText = url?.absoluteString ?? ""
    }
}
