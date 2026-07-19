import Foundation

enum RecordingMode: Equatable {
    case hold
    case toggle
}

enum AppStatus: Equatable {
    case idle
    case recording(TimeInterval, RecordingMode)
    case processing
    case done(String)
    case error(String)

    var title: String {
        switch self {
        case .idle:
            return "Ready"
        case .recording(_, .hold):
            return "Listening"
        case .recording(_, .toggle):
            return "Hands-free"
        case .processing:
            return "Refining your words"
        case .done:
            return "Pasted successfully"
        case .error:
            return "Something went wrong"
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
