import SwiftUI
import UIKit

/// Taking a photo for a message with the phone's camera. The camera needs `NSCameraUsageDescription` in the app's
/// Info settings, without which iOS ends the app the moment it is asked for; the settings are the project's (#680), so
/// the camera is offered only once the key is there, and only where there is a camera (the simulator has none).
@MainActor
enum ConversationCamera {
    /// Whether the camera can be offered, and if not, why, in words for the menu.
    static var availability: Availability {
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else { return .notInThisBuild }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return .noCamera }
        return .available
    }

    enum Availability: Equatable {
        case available
        /// The build does not say what the camera is for, so it may not use it.
        case notInThisBuild
        /// This device has no camera, as the simulator has none.
        case noCamera

        var reason: String? {
            switch self {
            case .available: nil
            case .notInThisBuild: "This build cannot use the camera yet."
            case .noCamera: "No camera on this device."
            }
        }
    }
}

/// The system's camera screen, which hands back the photo taken, or nothing when the person cancels.
struct ConversationCameraPicker: UIViewControllerRepresentable {
    let onTaken: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTaken: onTaken) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onTaken: (UIImage?) -> Void

        init(onTaken: @escaping (UIImage?) -> Void) {
            self.onTaken = onTaken
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onTaken(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onTaken(nil)
        }
    }
}
