import Foundation

enum AppStatus: Equatable {
    case idle
    case recording(TimeInterval)
    case processing
    case done(String)
    case error(String)

    var title: String {
        switch self {
        case .idle:
            return "Ready"
        case let .recording(duration):
            return String(format: "Recording %.1fs", duration)
        case .processing:
            return "Processing"
        case .done:
            return "Pasted"
        case .error:
            return "Error"
        }
    }

    var detail: String? {
        switch self {
        case let .done(text):
            return text
        case let .error(message):
            return message
        default:
            return nil
        }
    }

    var shouldShowFloatingBar: Bool {
        switch self {
        case .idle:
            return false
        case .recording, .processing, .done, .error:
            return true
        }
    }
}
