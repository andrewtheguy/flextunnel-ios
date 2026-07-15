/// Runtime state reported by the Rust core for one server-direct forward.
enum PortForwardState: Equatable {
    case stopped
    case starting
    case listening
    case failed(String)
}
