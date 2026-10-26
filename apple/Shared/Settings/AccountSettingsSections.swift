import ImageIO
import PhotosUI
import XeniaCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Blocked people

/// People whose messages and invitations don't reach you, with Unblock.
struct BlockedPeopleSections: View {
    @Environment(AppModel.self) private var model
    @State private var people: [Person]?
    @State private var failed = false
    @State private var unblocking: String?
    @State private var error: String?

    var body: some View {
        Section {
            if let people {
                if people.isEmpty {
                    Text("No one is blocked.")
                        .foregroundStyle(.secondary)
                }
                ForEach(people, id: \.userId) { person in
                    HStack {
                        PersonRow(person: person, isWorking: unblocking == person.userId)
                        if unblocking != person.userId {
                            Button("Unblock") { unblock(person) }
                                #if os(macOS)
                                .buttonStyle(.bordered)
                                #else
                                .buttonStyle(.borderless)
                                #endif
                        }
                    }
                }
            } else {
                HStack {
                    Text(failed ? "Couldn’t load blocked people." : "Loading…").foregroundStyle(.secondary)
                    Spacer()
                    if !failed { ProgressView().controlSize(.small) }
                }
            }
        } header: {
            Text("Blocked")
        } footer: {
            Text("Blocked people can’t message or invite you. They aren’t notified.")
        }
        .task { await load() }
        .errorAlert("Couldn’t Unblock", message: $error)
    }

    private func load() async {
        do {
            people = try await model.client.blockedPeople()
            model.blockedCount = people?.count
        } catch {
            failed = true
        }
    }

    private func unblock(_ person: Person) {
        unblocking = person.userId
        Task {
            defer { unblocking = nil }
            do {
                try await model.client.unblock(userId: person.userId)
                withAnimation(Theme.Motion.row) { people?.removeAll { $0.userId == person.userId } }
                model.blockedCount = people?.count
            } catch {
                self.error = Copy.error(error)
            }
        }
    }
}

// MARK: - Keywords

/// Words that notify like a mention. They live in the account's push rules, so every device
/// (and every Matrix app) follows them.
struct KeywordsSection: View {
    @Environment(AppModel.self) private var model
    @State private var keywords: [String]?
    @State private var newWord = ""
    @State private var error: String?
    @FocusState private var adding: Bool

    var body: some View {
        Section {
            ForEach(keywords ?? [], id: \.self) { word in
                HStack {
                    Text(word)
                    #if os(macOS)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle.fill") { remove(word) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove “\(word)”")
                    #endif
                }
            }
            #if os(iOS)
            .onDelete { offsets in
                // Words first: removing changes the indices.
                let words = offsets.compactMap { keywords?.indices.contains($0) == true ? keywords?[$0] : nil }
                words.forEach(remove)
            }
            #endif
            TextField("New Keyword", text: $newWord, prompt: Text("Add a Keyword"))
                .labelsHidden()
                .focused($adding)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                #endif
                .onSubmit(add)
        } header: {
            Text("Keywords")
        } footer: {
            Text("Get notified when a message contains these words.")
        }
        .task {
            keywords = (try? await model.client.notificationKeywords()) ?? []
        }
        .errorAlert("Couldn’t Change Keywords", message: $error)
    }

    private func add() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !(keywords ?? []).contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else {
            newWord = ""
            return
        }
        newWord = ""
        withAnimation(Theme.Motion.row) { keywords = ((keywords ?? []) + [word]).sorted { $0.lowercased() < $1.lowercased() } }
        adding = true
        Task {
            do { try await model.client.addNotificationKeyword(keyword: word) } catch {
                withAnimation(Theme.Motion.row) { keywords?.removeAll { $0 == word } }
                self.error = Copy.error(error)
            }
        }
    }

    private func remove(_ word: String) {
        withAnimation(Theme.Motion.row) { keywords?.removeAll { $0 == word } }
        Task {
            do { try await model.client.removeNotificationKeyword(keyword: word) } catch {
                self.error = Copy.error(error)
                keywords = try? await model.client.notificationKeywords()
            }
        }
    }
}

// MARK: - Storage

/// The space downloaded photos and files take, and clearing it.
struct StorageSection: View {
    @Environment(AppModel.self) private var model
    @State private var clearing = false
    @State private var cleared = false
    @State private var error: String?

    var body: some View {
        let bytes = model.storage?.mediaBytes
        Section {
            #if os(macOS)
            SettingsDetailRow(
                title: Text("Photos and Files"),
                detail: Text("They download again when opened. Messages stay.")
            ) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(bytes.map(SettingsCopy.bytes) ?? "…")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Button(cleared ? "Cleared" : "Clear") { clear() }
                        .disabled(clearing || cleared || bytes == 0)
                }
            }
            #else
            LabeledContent("Photos and Files") {
                Text(bytes.map(SettingsCopy.bytes) ?? "…")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Button(action: clear) {
                WorkingLabel(title: cleared ? "Cleared" : "Clear Photos and Files", working: clearing)
            }
            .disabled(clearing || cleared || bytes == 0)
            #endif
        } header: {
            Text("Storage")
        } footer: {
            #if os(iOS)
            Text("Photos and files download again when opened. Messages stay.")
            #endif
        }
        // The size rolls down once cleared; when it first loads, it's simply there.
        .animation(cleared ? Theme.Motion.flip : nil, value: bytes)
        .sensoryFeedback(.success, trigger: cleared) { _, new in new }
        .task { await model.refreshStorage() }
        .errorAlert("Couldn’t Clear Storage", message: $error)
    }

    private func clear() {
        clearing = true
        Task {
            defer { clearing = false }
            do {
                try await model.client.clearMediaCache()
                model.media.clear()
                model.linkPreviews.clear()
                cleared = true
                await model.refreshStorage()
            } catch {
                self.error = Copy.error(error)
            }
        }
    }
}

// MARK: - Profile photo

/// Your photo, with Choose Photo and Remove Photo. The chosen image is cropped square and scaled
/// to 512 px before it's sent.
struct ProfilePhotoButton: View {
    let size: CGFloat
    @Environment(AppModel.self) private var model
    @State private var picking = false
    @State private var importing = false
    @State private var item: PhotosPickerItem?
    @State private var uploading = false
    @State private var error: String?

    var body: some View {
        if let account = model.account {
            Menu {
                #if os(iOS)
                Button("Choose Photo…", systemImage: "photo.on.rectangle") { picking = true }
                #else
                Button("Choose Photo…", systemImage: "photo.on.rectangle") { importing = true }
                #endif
                if account.avatarUrl != nil {
                    Button("Remove Photo", systemImage: "trash", role: .destructive, action: remove)
                }
            } label: {
                AvatarView(name: account.displayName ?? account.userId, seed: account.userId, url: account.avatarUrl, size: size)
                    .overlay {
                        if uploading {
                            Circle().fill(.black.opacity(0.35))
                            ProgressView().tint(.white)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: size * 0.14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(size * 0.07)
                            .background(.tint, in: .circle)
                            .overlay { Circle().strokeBorder(.background, lineWidth: 2) }
                            .accessibilityHidden(true)
                    }
                    .contentShape(.circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(uploading)
            .accessibilityLabel(Text("Profile Photo"))
            .accessibilityHint(Text("Choose or remove your photo"))
            #if os(iOS)
            .photosPicker(isPresented: $picking, selection: $item, matching: .images)
            #endif
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result { Task { await upload(fileURL: url) } }
            }
            .onChange(of: item) { _, new in
                guard let new else { return }
                item = nil
                Task {
                    uploading = true
                    defer { uploading = false }
                    // As a file: the original can be large, and only a small copy is needed.
                    guard let picked = try? await new.loadTransferable(type: PickedMedia.self) else {
                        error = String(localized: "Xenia couldn’t read that image.")
                        return
                    }
                    await upload(fileURL: picked.url)
                    picked.remove()
                }
            }
            .errorAlert("Couldn’t Change Your Photo", message: $error)
        }
    }

    private func upload(fileURL: URL) async {
        uploading = true
        defer { uploading = false }
        let access = fileURL.startAccessingSecurityScopedResource()
        let jpeg = await ProfilePhoto.squareJPEG(contentsOf: fileURL)
        if access { fileURL.stopAccessingSecurityScopedResource() }
        guard let jpeg else {
            error = String(localized: "Xenia couldn’t read that image.")
            return
        }
        do { try await model.client.setAvatar(data: jpeg, mimetype: "image/jpeg") } catch { self.error = Copy.error(error) }
    }

    private func remove() {
        uploading = true
        Task {
            defer { uploading = false }
            do { try await model.client.removeAvatar() } catch { self.error = Copy.error(error) }
        }
    }
}

/// Center-cropped to a square, scaled to at most 512 px, as JPEG. The original is only ever
/// decoded at twice that size, off the main thread.
nonisolated enum ProfilePhoto {
    @concurrent
    static func squareJPEG(contentsOf url: URL, side: CGFloat = 512) async -> Data? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { squareJPEG(source: $0, side: side) }
    }

    @concurrent
    static func squareJPEG(from data: Data, side: CGFloat = 512) async -> Data? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { squareJPEG(source: $0, side: side) }
    }

    private static func squareJPEG(source: CGImageSource, side: CGFloat) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side * 2,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let edge = min(image.width, image.height)
        let crop = CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2, width: edge, height: edge)
        guard let square = image.cropping(to: crop) else { return nil }
        let target = Int(min(side, CGFloat(edge)))
        guard let context = CGContext(
            data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
