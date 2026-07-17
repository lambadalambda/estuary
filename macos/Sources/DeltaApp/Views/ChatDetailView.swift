import AVFoundation
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

private let bottomAnchorID = "bottom-anchor"

struct ChatDetailView: View {
    @Bindable var model: AppModel
    let chat: ChatItem
    @State private var draft = ""
    @State private var showAttachPicker = false
    @State private var forwardingMsgId: UInt32?
    @State private var loadingOlder = false
    @State private var quickLookURL: URL?
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if model.hasMoreMessages {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .onAppear { loadOlder(proxy: proxy) }
                        }
                        ForEach(buildMessageListEntries(model.messages)) { entry in
                            switch entry {
                            case .dayMarker(_, let label):
                                DayMarkerView(label: label)
                            case .message(let message, let showAuthor):
                                MessageBubbleView(
                                    model: model, message: message, showAuthor: showAuthor,
                                    onForward: { forwardingMsgId = message.id },
                                    onPreview: { quickLookURL = $0 })
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                // Chat behavior without manual scroll bookkeeping: start at
                // the bottom (after layout, so it can't land mid-chat), and
                // stay pinned there through content growth — new messages,
                // image blobs arriving, bubbles resizing — but only while the
                // user actually is at the bottom. Scrolled-up positions are
                // left alone.
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                // Fresh scroll state per chat; with the initial anchor this
                // is the no-animation snap to the newest message.
                .id(chat.id)
                .onChange(of: chat.id) {
                    draft = ""
                    composerFocused = true
                }
            }

            Divider()
            composer
        }
        .onAppear { composerFocused = true }
        .quickLookPreview($quickLookURL)
        .navigationTitle(chat.name)
        .navigationSubtitle(chat.isContactRequest ? "Contact request" : "")
        .fileImporter(isPresented: $showAttachPicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                sendFile(url: url)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL {
                        Task { @MainActor in sendFile(url: url) }
                    }
                }
            }
            return true
        }
        .sheet(item: $forwardingMsgId) { msgId in
            ForwardSheet(model: model, msgId: msgId)
        }
    }

    /// Fetches one page of history and keeps the previous top message
    /// anchored so the viewport doesn't jump when content is prepended.
    private func loadOlder(proxy: ScrollViewProxy) {
        guard !loadingOlder else { return }
        loadingOlder = true
        Task {
            let anchorId = await model.loadOlderMessages()
            if let anchorId {
                // MessageListEntry ids are "msg-<id>" strings.
                proxy.scrollTo("msg-\(anchorId)", anchor: .top)
            }
            loadingOlder = false
        }
    }

    private func sendFile(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // Core copies the file into its blobdir, so the path only needs to be
        // readable now.
        let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        let path = url.path
        Task { await model.sendAttachment(path: path, caption: caption) }
    }

    @ViewBuilder
    private var composer: some View {
        if chat.isContactRequest {
            HStack(spacing: 12) {
                Button("Accept") {
                    Task { await model.acceptSelectedChat() }
                }
                .buttonStyle(.borderedProminent)
                Button("Block", role: .destructive) {
                    Task { await model.blockSelectedChat() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.bar)
        } else {
            VStack(spacing: 0) {
                if let replyTo = model.replyTo {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(hex: replyTo.senderColor))
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(replyTo.senderName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color(hex: replyTo.senderColor))
                            Text(replyTo.text.isEmpty ? (replyTo.fileName ?? "Attachment") : replyTo.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            model.replyTo = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button {
                        showAttachPicker = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 2)
                    // Grows up to 5 lines; Return sends, Option+Return
                    // inserts a newline.
                    TextField("Message \(chat.name)…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(1 ... 5)
                        .focused($composerFocused)
                        .onSubmit(sendDraft)
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .padding(.bottom, 2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .barBackground()
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        composerFocused = true
        Task { await model.send(text) }
    }
}

extension View {
    /// Liquid Glass where the OS has it; classic bar material otherwise.
    @ViewBuilder
    func barBackground() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect)
        } else {
            self.background(.bar)
        }
    }
}

extension UInt32: @retroactive Identifiable {
    public var id: UInt32 { self }
}

// MARK: - Forward sheet

struct ForwardSheet: View {
    let model: AppModel
    let msgId: UInt32
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Forward to…")
                .font(.title3.bold())
            List(model.chats.filter { !$0.isContactRequest }) { chat in
                Button {
                    dismiss()
                    Task { await model.forwardMessage(msgId: msgId, to: chat.id) }
                } label: {
                    HStack {
                        AvatarView(name: chat.name, colorHex: chat.color, size: 24)
                        Text(chat.name)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Day separator

struct DayMarkerView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

// MARK: - Message bubble

private let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

struct MessageBubbleView: View {
    let model: AppModel
    let message: MessageItem
    let showAuthor: Bool
    var onForward: () -> Void = {}
    /// Quick Look request (space-bar-style preview owned by the chat view).
    var onPreview: (URL) -> Void = { _ in }

    var body: some View {
        if message.isInfo {
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .frame(maxWidth: .infinity)
        } else if message.isOutgoing {
            HStack(alignment: .bottom) {
                Spacer(minLength: 80)
                bubbleWithReactions
            }
        } else {
            HStack(alignment: .bottom) {
                bubbleWithReactions
                Spacer(minLength: 80)
            }
        }
    }

    private var bubbleWithReactions: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            bubble
                .contextMenu { contextMenu }
            if !message.reactions.isEmpty {
                ReactionChipsView(model: model, message: message)
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showAuthor {
                Text(message.senderName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(hex: message.senderColor))
            }
            if let quote = message.quote {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(hex: quote.senderColor))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        if !quote.senderName.isEmpty {
                            Text(quote.senderName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color(hex: quote.senderColor))
                        }
                        Text(quote.text)
                            .font(.caption)
                            .lineLimit(2)
                            .opacity(0.8)
                    }
                }
                .padding(6)
                .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            mediaContent

            if !message.text.isEmpty {
                Text(message.text)
                    .textSelection(.enabled)
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
            }
            HStack(spacing: 4) {
                Text(messageTime(message.timestamp))
                    .font(.caption2)
                if message.isOutgoing {
                    DeliveryStateView(state: message.state)
                }
            }
            .foregroundStyle(message.isOutgoing ? Color.white.opacity(0.75) : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            message.isOutgoing
                ? AnyShapeStyle(Color.accentColor)
                : AnyShapeStyle(.quinary),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Display size derived from core's stored pixel dimensions, so the
    /// bubble has its final size BEFORE the image blob is loaded/downloaded —
    /// no post-hoc growth, no scroll drift.
    private var imageDisplaySize: CGSize? {
        guard message.width > 0, message.height > 0 else { return nil }
        let w = CGFloat(message.width)
        let h = CGFloat(message.height)
        let scale = min(320 / w, 320 / h, 1)
        return CGSize(width: max(w * scale, 40), height: max(h * scale, 40))
    }

    @ViewBuilder
    private var mediaContent: some View {
        switch message.kind {
        case .image, .gif, .sticker:
            let image = message.file.flatMap(ImageCache.load)
            if let size = imageDisplaySize {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        // Blob still downloading: reserve the final size.
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { openFile() }
            } else if let image {
                // Dimensions unknown: size from the decoded image (stable
                // across renders once the file exists).
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { openFile() }
            } else {
                fileRow(icon: "photo")
            }
        case .audio, .voice:
            AudioMessageView(message: message)
        case .video:
            fileRow(icon: "video.fill")
        case .file, .vcard, .webxdc, .unknown:
            if message.file != nil {
                fileRow(icon: message.kind == .webxdc ? "app.gift" : "doc.fill")
            }
        case .text:
            EmptyView()
        }
    }

    private func fileRow(icon: String) -> some View {
        Button(action: openFile) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.fileName ?? "Attachment")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if message.fileSize > 0 {
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(message.fileSize), countStyle: .file))
                            .font(.caption2)
                            .opacity(0.7)
                    }
                }
            }
            .foregroundStyle(message.isOutgoing ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    /// Tap: Quick Look preview in place; "Open in App" lives in the menu.
    private func openFile() {
        if let file = message.file {
            onPreview(URL(fileURLWithPath: file))
        }
    }

    private func openInApp() {
        if let file = message.file {
            NSWorkspace.shared.open(URL(fileURLWithPath: file))
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if !message.text.isEmpty {
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
        }
        Button("Reply") { model.replyTo = message }
        Menu("React") {
            ForEach(quickReactions, id: \.self) { emoji in
                Button(emoji) {
                    Task { await model.toggleReaction(message: message, emoji: emoji) }
                }
            }
            if message.reactions.contains(where: \.isFromSelf) {
                Divider()
                Button("Remove Reaction") {
                    Task { await model.sendReaction(msgId: message.id, emoji: "") }
                }
            }
        }
        Button("Forward…", action: onForward)
        if message.file != nil {
            Button("Quick Look", action: openFile)
            Button("Open in App", action: openInApp)
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { await model.deleteMessage(msgId: message.id) }
        }
    }
}

// MARK: - Image cache

/// Decoded-image cache: bubbles re-render often in a LazyVStack and
/// `NSImage(contentsOfFile:)` hits the disk every time.
@MainActor
enum ImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func load(_ path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) {
            return hit
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

// MARK: - Reactions

struct ReactionChipsView: View {
    let model: AppModel
    let message: MessageItem

    var body: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions, id: \.emoji) { reaction in
                Button {
                    Task { await model.toggleReaction(message: message, emoji: reaction.emoji) }
                } label: {
                    HStack(spacing: 3) {
                        Text(reaction.emoji)
                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .font(.caption2.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        reaction.isFromSelf
                            ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                            : AnyShapeStyle(.quaternary),
                        in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            reaction.isFromSelf ? Color.accentColor : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Audio playback

/// One shared player: starting a message stops the previous one.
@MainActor
final class AudioPlayerController: ObservableObject {
    static let shared = AudioPlayerController()
    @Published var playingPath: String?
    private var player: AVAudioPlayer?

    func toggle(path: String) {
        if playingPath == path {
            player?.stop()
            playingPath = nil
            return
        }
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        player?.play()
        playingPath = player != nil ? path : nil
    }
}

struct AudioMessageView: View {
    let message: MessageItem
    @ObservedObject private var player = AudioPlayerController.shared

    private var isPlaying: Bool { player.playingPath == message.file }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let file = message.file { player.toggle(path: file) }
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.kind == .voice ? "Voice message" : (message.fileName ?? "Audio"))
                    .font(.callout.weight(.medium))
                if message.durationMs > 0 {
                    Text(durationLabel(ms: message.durationMs))
                        .font(.caption2)
                        .opacity(0.7)
                }
            }
        }
        .foregroundStyle(message.isOutgoing ? .white : .primary)
    }

    private func durationLabel(ms: UInt32) -> String {
        let seconds = Int(ms) / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Delivery ticks for outgoing messages: clock = pending, one tick =
/// delivered, two ticks = read, red mark = failed.
struct DeliveryStateView: View {
    let state: MessageState

    var body: some View {
        switch state {
        case .pending:
            Image(systemName: "clock")
                .font(.caption2)
        case .delivered:
            Text("✓")
                .font(.caption2.weight(.semibold))
        case .read:
            Text("✓✓")
                .font(.caption2.weight(.semibold))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        case .noState:
            EmptyView()
        }
    }
}

// MARK: - Previews

#Preview("Bubbles") {
    let now = Int64(Date().timeIntervalSince1970)
    let model = AppModel(service: MockChatService())
    return ScrollView {
        LazyVStack(spacing: 6) {
            DayMarkerView(label: "Today")
            MessageBubbleView(
                model: model,
                message: MessageItem(
                    id: 1, chatId: 1, text: "You added member Carol.", timestamp: now - 4000,
                    isOutgoing: false, isInfo: true, senderName: "", senderColor: "#999999",
                    state: .noState),
                showAuthor: false)
            MessageBubbleView(
                model: model,
                message: MessageItem(
                    id: 2, chatId: 1, text: "Hey! Did you see the native prototype?",
                    timestamp: now - 3600, isOutgoing: false, isInfo: false,
                    senderName: "Alice", senderColor: "#e56555", state: .noState,
                    reactions: [ReactionItem(emoji: "👍", count: 2, isFromSelf: true)]),
                showAuthor: true)
            MessageBubbleView(
                model: model,
                message: MessageItem(
                    id: 3, chatId: 1, text: "Yes! SwiftUI over a Rust core.",
                    timestamp: now - 3500, isOutgoing: true, isInfo: false,
                    senderName: "Me", senderColor: "#2f9e44", state: .read,
                    quote: QuoteInfo(
                        text: "Hey! Did you see the native prototype?",
                        senderName: "Alice", senderColor: "#e56555")),
                showAuthor: false)
            MessageBubbleView(
                model: model,
                message: MessageItem(
                    id: 4, chatId: 1, text: "", timestamp: now - 60,
                    isOutgoing: false, isInfo: false,
                    senderName: "Alice", senderColor: "#e56555", state: .noState,
                    kind: .file, file: "/tmp/nonexistent.pdf",
                    fileName: "report.pdf", fileSize: 48_213),
                showAuthor: false)
        }
        .padding(16)
    }
    .frame(width: 420, height: 480)
}
