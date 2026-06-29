import SwiftUI
import UIKit

/// Resigns first responder app-wide, dismissing the keyboard from any focused
/// field without needing a per-view `@FocusState` binding.
@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct ContentView: View {
    @StateObject private var proxy = ProxyController()

    @State private var serverNodeID = ""
    @State private var authToken = ""
    @State private var relayURLs = ""

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

                if let socksPort = proxy.socksPort {
                    Section("Browse (through SOCKS5)") {
                        NavigationLink("Open browser") {
                            BrowserView(model: BrowserModel(socksPort: socksPort))
                                .navigationTitle("Browser")
                                .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                }
            }
            .navigationTitle("flextunnel")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                }
            }
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
