import SwiftUI

private let bottomAnchorID = "bottom-anchor"

struct ChatDetailView: View {
    let model: AppModel
    let chat: ChatItem
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(buildMessageListEntries(model.messages)) { entry in
                            switch entry {
                            case .dayMarker(_, let label):
                                DayMarkerView(label: label)
                            case .message(let message, let showAuthor):
                                MessageBubbleView(message: message, showAuthor: showAuthor)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .onAppear {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: model.messages) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
                .onChange(of: chat.id) {
                    draft = ""
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }

            Divider()
            composer
        }
        .navigationTitle(chat.name)
        .navigationSubtitle(chat.isContactRequest ? "Contact request" : "")
    }

    @ViewBuilder
    private var composer: some View {
        if chat.isContactRequest {
            Text("This is a contact request. Accept/block is not part of this prototype.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 8) {
                TextField("Message \(chat.name)…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit(sendDraft)
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await model.send(text) }
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

struct MessageBubbleView: View {
    let message: MessageItem
    let showAuthor: Bool

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
                bubble
            }
        } else {
            HStack(alignment: .bottom) {
                bubble
                Spacer(minLength: 80)
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
            Text(message.text)
                .textSelection(.enabled)
                .foregroundStyle(message.isOutgoing ? .white : .primary)
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
    return ScrollView {
        LazyVStack(spacing: 6) {
            DayMarkerView(label: "Today")
            MessageBubbleView(
                message: MessageItem(
                    id: 1, chatId: 1, text: "You added member Carol.", timestamp: now - 4000,
                    isOutgoing: false, isInfo: true, senderName: "", senderColor: "#999999",
                    state: .noState),
                showAuthor: false)
            MessageBubbleView(
                message: MessageItem(
                    id: 2, chatId: 1, text: "Hey! Did you see the native prototype?",
                    timestamp: now - 3600, isOutgoing: false, isInfo: false,
                    senderName: "Alice", senderColor: "#e56555", state: .noState),
                showAuthor: true)
            MessageBubbleView(
                message: MessageItem(
                    id: 3, chatId: 1, text: "Yes! SwiftUI over a Rust core.",
                    timestamp: now - 3500, isOutgoing: true, isInfo: false,
                    senderName: "Me", senderColor: "#2f9e44", state: .read),
                showAuthor: false)
            MessageBubbleView(
                message: MessageItem(
                    id: 4, chatId: 1, text: "Still sending this one…",
                    timestamp: now - 30, isOutgoing: true, isInfo: false,
                    senderName: "Me", senderColor: "#2f9e44", state: .pending),
                showAuthor: false)
        }
        .padding(16)
    }
    .frame(width: 420, height: 380)
}
