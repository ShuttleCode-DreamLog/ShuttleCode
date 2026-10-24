import SwiftUI
import Observation

@MainActor @Observable
final class DiscussionModel {
    let dreamId: String
    var conversation: Conversation?
    var pending: PendingTurn?
    var streamingText = ""
    var contextRestarted = false
    var turnError: APIError?
    var error: String?
    var isRestarting = false
    var answeredOffers: Set<String> = []
    private var epoch: Int?
    private var changes = 0
    private var turn: Task<Void, Never>?
    init(dreamId: String) { self.dreamId = dreamId }
    var turnInProgress: Bool { pending?.state == .sending }
    var discussionOff: Bool { turnError?.code == "not_permitted" }
    var canRestart: Bool { !turnInProgress && !isRestarting && conversation?.messages.contains { $0.state == .ok } == true }
    // A last message the user wrote whose reply was removed or never sent after a restart cannot be requested again (discussion logic 1).
    var replyRemoved: Bool { conversation?.messages.last.map { $0.role == .user && $0.state == .stale } ?? false }
    private func current(_ app: AppModel) -> Bool { epoch == app.journalEpoch && !app.deleting && app.noticeSeen }

    func load(_ app: AppModel) async {
        guard !turnInProgress, !isRestarting, app.noticeSeen, !app.deleting, let client = app.client else { return }
        epoch = app.journalEpoch
        answeredOffers = app.answeredOffers
        let started = changes
        let result = await client.loadConversation(dreamId)
        // A read that started before the last change is dropped, so it cannot replace that change's result (wiki 4.4.6, rule 6).
        guard current(app), started == changes, !turnInProgress else { return }
        switch result {
        case let .success(value):
            conversation = value; error = nil
            // A message whose reply never arrived, also after the app was closed, can be requested again (discussion logic 1).
            pending = value.messages.last.flatMap { $0.role == .user && $0.state == .ok ? PendingTurn(messageId: $0.id, text: $0.text, state: .failed) : nil }
        case let .failure(failure): error = failure.message
        }
    }
    func send(_ app: AppModel, text: String) async { await start(app, messageID: newID(), text: text) }
    func requestAgain(_ app: AppModel) async {
        guard let pending, pending.state != .sending else { return }
        await start(app, messageID: pending.messageId, text: pending.text)
    }
    // Leaving the screen ends the request; nothing of the reply is saved and the message can be requested again (discussion logic 4).
    func cancel() { turn?.cancel() }
    // The turn runs in its own task, so leaving the screen can cancel it while a caller still waits for its end.
    private func start(_ app: AppModel, messageID: String, text: String) async {
        guard !turnInProgress, !isRestarting, let client = app.client else { return }
        if epoch == nil { epoch = app.journalEpoch }
        changes += 1
        pending = PendingTurn(messageId: messageID, text: text, state: .sending)
        streamingText = ""; turnError = nil; contextRestarted = false
        turn = Task {
            app.streamInProgress = true
            defer { app.streamInProgress = false }
            for await event in client.sendTurn(dreamId, messageID: messageID, text: text) {
                guard current(app) else { return }
                switch event {
                case let .start(restarted): contextRestarted = restarted
                case let .delta(piece): streamingText += piece
                case let .done(value): receive(value); pending = nil
                case let .failed(failure):
                    streamingText = ""
                    if failure.code == "turn_in_progress" { pending?.state = .stillWorking } else { pending?.state = .failed; turnError = failure }
                }
            }
            if pending?.state == .sending { pending?.state = .failed; turnError = .interrupted; streamingText = "" }
        }
        await turn?.value
    }
    private func receive(_ value: TurnDone) {
        // After Request again the user's message is already listed, so a returned message replaces its own ID, never adds twice.
        var messages = conversation?.messages ?? []
        for message in [value.userMessage, value.message] {
            if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message } else { messages.append(message) }
        }
        conversation = Conversation(dreamId: dreamId, goal: conversation?.goal, messages: messages, corrections: conversation?.corrections ?? [], analysisWithheld: conversation?.analysisWithheld ?? false)
        streamingText = ""
    }
    func restart(_ app: AppModel) async {
        guard canRestart, let client = app.client else { return }
        if epoch == nil { epoch = app.journalEpoch }
        isRestarting = true; changes += 1
        defer { isRestarting = false }
        let result = await client.restartConversation(dreamId)
        guard current(app) else { return }
        switch result {
        case let .success(value): conversation = value; pending = nil; contextRestarted = false; error = nil
        case let .failure(failure): error = failure.message
        }
    }
    // The newest reply in use points at one action on the message it answers, until that hint is taken or dismissed (discussion logic 6).
    var offer: (messageId: String, offer: Offer, replyId: String)? {
        guard let reply = conversation?.messages.last(where: { $0.role == .assistant }), reply.state == .ok, let offer = reply.offer, offer != .unknown,
              let messageId = reply.replyTo, !answeredOffers.contains(reply.id) else { return nil }
        return (messageId, offer, reply.id)
    }
    func answerOffer(_ app: AppModel, replyId: String) {
        app.answerOffer(replyId)
        answeredOffers.insert(replyId)
    }
}

// A message the user wrote, handed to the life-note editor or the dream editor; nothing is saved until that editor saves.
struct Handoff: Identifiable {
    let id = newID()
    let text: String
    let toDream: Bool
}

// The prototype's conversation screen: "Reflect together", the thread, and the composer "Ask about this dream…".
struct DiscussionView: View {
    @Environment(AppModel.self) private var app
    @State private var model: DiscussionModel
    @State private var message = ""
    @State private var confirmingRestart = false
    @State private var handoff: Handoff?
    @State private var dreamTitle: String
    let dreamId: String

    init(dreamId: String, title: String) {
        self.dreamId = dreamId
        _model = State(initialValue: DiscussionModel(dreamId: dreamId))
        _dreamTitle = State(initialValue: title)
    }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Eyebrow("Reflect together")
                    if let error = model.error { ErrorCard(error) { Task { await model.load(app) } } }
                    if model.conversation?.analysisWithheld == true { Hint("This dream's analysis is not given to the AI in this discussion.") }
                    if model.conversation?.messages.contains(where: { $0.state == .stale }) == true { Hint("Dimmed messages are no longer sent to the AI.") }
                    Bubble(text: "What would you like to explore about this dream?", user: false)
                    ForEach(model.conversation?.messages ?? []) { row($0) }
                    if let pending = model.pending, model.conversation?.messages.contains(where: { $0.id == pending.messageId }) != true {
                        Bubble(text: pending.text, user: true)
                    }
                    if model.contextRestarted { Hint("This reply starts afresh: earlier messages were not sent.") }
                    if !model.streamingText.isEmpty { Bubble(text: model.streamingText, user: false) }
                    pendingBlock
                    if model.replyRemoved { Hint("The reply to this message is no longer available.") }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .onChange(of: model.streamingText) { reader.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.conversation?.messages.count) { reader.scrollTo("end", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .dreamPage()
        .page(Header(dreamTitle, leading: { BackButton() }, trailing: {
            if model.canRestart { Button("Start afresh") { confirmingRestart = true }.buttonStyle(.quiet) }
            HomeButton()
        }), aboveBar: false)
        .task { await model.load(app) }
        .reloadable { await model.load(app) }
        .onChange(of: app.refreshes) { Task { await model.load(app) } }
        .onDisappear { model.cancel() }
        .confirmationDialog("Earlier messages stay on this screen and are no longer sent to the AI service.", isPresented: $confirmingRestart, titleVisibility: .visible) {
            Button("Start afresh") { Task { await model.restart(app) } }
        }
        .sheet(item: $handoff, onDismiss: { app.refreshes += 1 }) { handoff in
            NavigationStack {
                if handoff.toDream { DreamEditorView(id: dreamId, presented: true, appending: handoff.text) }
                else { NoteEditorView(id: handoff.id, newEntry: true, text: handoff.text) }
            }
        }
    }

    @ViewBuilder private func row(_ message: Message) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            Bubble(text: message.text, user: message.role == .user).opacity(message.state == .stale ? 0.55 : 1)
            if message.role == .user { actions(message) }
            else if !message.context.isEmpty {
                DisclosureGroup("Sources") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(message.context) { entry in Hint(entry.available ? entry.name : "\(entry.name) · changed since") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption).foregroundStyle(Color.muted).padding(.trailing, 25)
            }
        }.frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    // Both actions on every message the user wrote (wiki 4.6.6, rule 2); the model's offer only points at one of them.
    @ViewBuilder private func actions(_ message: Message) -> some View {
        let offered = model.offer.flatMap { $0.messageId == message.id ? $0 : nil }
        HStack(spacing: 14) {
            Button("Remember in profile") { take(message, toDream: false, offered: offered) }
                .buttonStyle(.quiet).fontWeight(offered?.offer == .rememberInProfile ? .semibold : .regular)
            Button("Add to dream") { take(message, toDream: true, offered: offered) }
                .buttonStyle(.quiet).fontWeight(offered?.offer == .addToDream ? .semibold : .regular)
        }.font(.caption)
        if let offered {
            HStack(spacing: 10) {
                Hint(offered.offer == .rememberInProfile ? "This sounds like something from your life. Keep it as a life note?" : "This sounds like a detail of the dream. Add it to the dream?")
                Button("Not now") { model.answerOffer(app, replyId: offered.replyId) }.buttonStyle(.quiet).font(.caption)
            }
        }
    }
    private func take(_ message: Message, toDream: Bool, offered: (messageId: String, offer: Offer, replyId: String)?) {
        if let offered { model.answerOffer(app, replyId: offered.replyId) }
        handoff = Handoff(text: message.text, toDream: toDream)
    }

    @ViewBuilder private var pendingBlock: some View {
        if let pending = model.pending {
            switch pending.state {
            case .sending: if model.streamingText.isEmpty { ProgressView().padding(.vertical, 4) }
            case .stillWorking:
                Hint("A reply to this message is still being written.")
                Button("Check again") { Task { await model.load(app) } }.buttonStyle(.secondary)
            case .failed:
                Text(model.turnError.map(turnFailureText) ?? "No reply arrived for this message.").font(.callout)
                if !model.discussionOff { Button("Request again") { Task { await model.requestAgain(app) } }.buttonStyle(.secondary) }
                Hint(dangerLine)
            }
        }
    }

    private var composer: some View {
        let length = message.unicodeScalars.count
        let blank = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            if model.discussionOff { Hint("Discussion is off for this dream.") } else {
                HStack(alignment: .bottom, spacing: 7) {
                    TextField("Ask about this dream…", text: $message, axis: .vertical).lineLimit(1...5).field().accessibilityLabel("Message")
                    Button { let text = message; message = ""; Task { await model.send(app, text: text) } } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.primary).accessibilityLabel("Send message")
                        .disabled(blank || length > app.limits.maxMessageChars || model.turnInProgress || model.isRestarting || model.pending?.state == .stillWorking)
                }
                if length > app.limits.maxMessageChars { Hint("\(length) / \(app.limits.maxMessageChars) characters") }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        // The shell's bar does not inset pages inside a NavigationStack, so the composer sits above it itself.
        .padding(.bottom, app.barHeight)
        .background(Color.paper.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
    }
}

// The prototype's chat bubbles: the AI's on the left in soft green, the user's indented on the right.
struct Bubble: View {
    let text: String
    let user: Bool
    var body: some View {
        Text(text).font(.callout).textSelection(.enabled)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(user ? Color.line : Color.soft, in: RoundedRectangle(cornerRadius: 18))
            .padding(user ? .leading : .trailing, user ? 40 : 25)
            .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
    }
}
