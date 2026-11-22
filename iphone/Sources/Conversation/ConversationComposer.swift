import PhotosUI
import SwiftUI

/// The message field and its buttons (docs/design/iphone.md, "A project's hub"): it takes text, dictation (the
/// keyboard's microphone, which needs nothing of the app), photos from the library and from the camera; Stop is where
/// Send was while the agent works, and Send comes back beside it once something is written, to steer or queue.
struct ConversationComposer: View {
    @Bindable var draft: MessageField
    let pictures: ConversationPictures
    let status: ConversationStatus
    @Binding var steer: Bool
    /// Whether the client is connected to the engine: sending waits for it.
    let connected: Bool
    let send: () -> Void
    let stop: () -> Void

    @State private var choosingPhotos = false
    @State private var chosen: [PhotosPickerItem] = []
    @State private var usingCamera = false
    @FocusState private var focused: Bool

    private var hasContent: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pictures.ready.isEmpty
    }

    /// Why the message cannot go as it is, if it cannot: in words under the field.
    private var holdBack: String? {
        if !connected { return "Not connected to your Mac. You can write now, and send once it is back." }
        if status.blindModel != nil, !pictures.entries.isEmpty {
            return "\(status.blindModel ?? "This model") cannot see pictures. Take them off to send."
        }
        if pictures.entries.contains(where: { if case .failed = $0.content { true } else { false } }) {
            return "A picture could not be prepared for sending. Take it off to send."
        }
        return nil
    }

    private var canSend: Bool {
        hasContent && connected && !pictures.isReading && holdBack == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pictures.entries.isEmpty {
                ConversationPictureStrip(pictures: pictures)
            }
            if status.busy {
                Picker("When \(status.agentName) reads it", selection: $steer) {
                    Text("Steer").tag(true)
                    Text("Queue").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .accessibilityHint("Steer: read after its current step. Queue: read once it has answered.")
            }
            field
            if let holdBack {
                Text(holdBack)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $chosen, maxSelectionCount: max(1, ConversationPictureLimits.count - pictures.entries.count), matching: .images)
        .onChange(of: chosen) { _, items in
            guard !items.isEmpty else { return }
            chosen = []
            for (index, item) in items.enumerated() {
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    pictures.add(data, name: "Photo \(index + 1)")
                }
            }
        }
        #if DEBUG
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            if ConversationSample.opensPhotos { choosingPhotos = true }
        }
        #endif
        .fullScreenCover(isPresented: $usingCamera) {
            ConversationCameraPicker { image in
                usingCamera = false
                if let image { pictures.add(image, name: "Photo") }
            }
            .ignoresSafeArea()
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachMenu
            TextField(status.placeholder(steer: steer), text: $draft.text, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.vertical, 7)
                .accessibilityLabel("Message")
            if status.busy {
                Button(action: stop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
                .accessibilityHint("Stops the run and everything it started.")
            }
            if !status.busy || hasContent {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color(uiColor: ConversationColors.onAccent), Color.conversationAccent)
                        .opacity(canSend ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(status.busy ? (steer ? "Send to steer" : "Send to the queue") : "Send")
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(focused ? Color.conversationAccent.opacity(0.6) : Color(uiColor: .separator)))
        .padding(.horizontal, 12)
    }

    private var attachMenu: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { choosingPhotos = true }
                .disabled(pictures.isFull)
            let camera = ConversationCamera.availability
            Button {
                usingCamera = true
            } label: {
                if let reason = camera.reason {
                    Label { Text("Take Photo"); Text(reason) } icon: { Image(systemName: "camera") }
                } else {
                    Label("Take Photo", systemImage: "camera")
                }
            }
            .disabled(camera != .available || pictures.isFull)
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Attach")
        .accessibilityHint("Adds photos from your library or the camera.")
    }
}

/// The pictures waiting to go with the next message, each with a way to take it off.
struct ConversationPictureStrip: View {
    let pictures: ConversationPictures

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pictures.entries) { entry in
                    ZStack(alignment: .topTrailing) {
                        thumbnail(entry)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button {
                            pictures.remove(entry.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .frame(width: 30, height: 30)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 8, y: -8)
                        .accessibilityLabel("Take off \(entry.name)")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(label(entry))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func thumbnail(_ entry: ConversationPictures.Entry) -> some View {
        switch entry.content {
        case .reading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.fill.tertiary)
        case .ready(let picture):
            if let image = UIImage(data: picture.thumbnail) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.fill.tertiary)
        }
    }

    private func label(_ entry: ConversationPictures.Entry) -> String {
        switch entry.content {
        case .reading: "\(entry.name), being prepared"
        case .ready: entry.name
        case .failed(let why): "\(entry.name): \(why)"
        }
    }
}
