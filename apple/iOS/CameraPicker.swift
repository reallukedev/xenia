import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The camera, for a photo or a video to send. SwiftUI has no camera of its own, so this is
/// UIKit's, as Messages presents it: full screen, photo or video.
struct CameraPicker: UIViewControllerRepresentable {
    /// What was taken, ready to be saved to a file and sent.
    enum Capture {
        case photo(UIImage)
        case video(PickedMedia)

        /// The photo is encoded here, off the main thread, as part of sending it.
        func file() async throws -> PickedMedia {
            switch self {
            case .photo(let image): try await PickedMedia.saving(image)
            case .video(let movie): movie
            }
        }
    }

    let onCapture: (Capture) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Not in the simulator, and not where the camera is restricted (Screen Time, a managed
    /// iPhone): there, nothing in Settings could turn it on.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
            && AVCaptureDevice.authorizationStatus(for: .video) != .restricted
    }

    /// Xenia was refused the camera, and only Settings can change that.
    static var isDenied: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .denied
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let movie = info[.mediaURL] as? URL {
                // The picker's file can go once it closes: keep a copy of our own.
                if let kept = try? PickedMedia.keeping(movie, named: String(localized: "Video")) {
                    parent.onCapture(.video(kept))
                }
            } else if let image = info[.originalImage] as? UIImage {
                parent.onCapture(.photo(image))
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

extension PickedMedia {
    /// A photo just taken, as a JPEG that keeps which way up it was held.
    @concurrent
    static func saving(_ image: UIImage) async throws -> PickedMedia {
        guard let data = image.jpegData(compressionQuality: 0.9) else { throw CocoaError(.fileWriteUnknown) }
        let file = try newFile(named: String(localized: "Photo"), extension: "jpeg")
        try data.write(to: file)
        return PickedMedia(url: file)
    }

    static func keeping(_ movie: URL, named name: String) throws -> PickedMedia {
        let file = try newFile(named: name, extension: movie.pathExtension)
        try FileManager.default.copyItem(at: movie, to: file)
        return PickedMedia(url: file)
    }

    private nonisolated static func newFile(named name: String, extension ext: String) throws -> URL {
        let folder = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: ext.isEmpty ? name : "\(name).\(ext)")
    }
}
