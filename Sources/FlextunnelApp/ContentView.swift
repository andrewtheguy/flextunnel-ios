import SwiftUI

struct ContentView: View {
    @StateObject private var proxy = ProxyController()

    @State private var serverNodeID = ""
    @State private var authToken = ""
    @State private var relayURLs = ""
    @State private var urlString = "https://example.com"

    /// The URL to load once the proxy is running and the field parses.
    private var loadURL: URL? {
        guard proxy.socksPort != nil else { return nil }
        return URL(string: urlString.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server node id", text: $serverNodeID)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Auth token", text: $authToken)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Relay URLs (comma-separated, optional)", text: $relayURLs)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }

                Section("Status") {
                    LabeledContent("State", value: proxy.status)
                    if proxy.socksPort != nil {
                        LabeledContent("Health") {
                            Label(proxy.healthy ? "alive" : "down",
                                  systemImage: proxy.healthy
                                      ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(proxy.healthy ? .green : .red)
                        }
                    }
                    if let err = proxy.lastError {
                        Text(err).foregroundStyle(.red).font(.footnote)
                    }
                }

                Section {
                    Button("Start proxy") {
                        proxy.start(currentSettings())
                    }
                    .disabled(serverNodeID.isEmpty || authToken.isEmpty)

                    Button("Stop", role: .destructive) {
                        proxy.stop()
                    }
                    .disabled(proxy.socksPort == nil)
                }

                if proxy.socksPort != nil {
                    Section("Browse (through SOCKS5)") {
                        TextField("URL", text: $urlString)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        if let url = loadURL {
                            NavigationLink("Open in proxied WebView") {
                                ProxyWebView(socksPort: proxy.socksPort!, url: url)
                                    .ignoresSafeArea(edges: .bottom)
                                    .navigationTitle(url.host() ?? "Web")
                                    .navigationBarTitleDisplayMode(.inline)
                            }
                        }
                    }
                }
            }
            .navigationTitle("flextunnel")
        }
    }

    private func currentSettings() -> ProxyController.Settings {
        ProxyController.Settings(
            serverNodeID: serverNodeID.trimmingCharacters(in: .whitespaces),
            authToken: authToken.trimmingCharacters(in: .whitespaces),
            relayURLs: splitCSV(relayURLs)
        )
    }

    private func splitCSV(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

#Preview {
    ContentView()
}
