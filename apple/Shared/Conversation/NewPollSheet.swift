import XeniaCore
import SwiftUI

/// New Poll: a question and its answers, typed in place. Return moves to the next answer and
/// makes a new one at the end, so a poll is typed without reaching for a button.
struct NewPollSheet: View {
    @Environment(ConversationModel.self) private var conversation
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answers: [Answer] = [Answer(), Answer()]
    @State private var allowsMultiple = false
    @State private var showsResults = true
    @State private var isSending = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private static let maxAnswers = 20

    struct Answer: Identifiable, Equatable {
        let id = UUID()
        var text = ""
    }

    enum Field: Hashable {
        case question
        case answer(UUID)
    }

    private var filledAnswers: [String] {
        answers.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filledAnswers.count >= 2 && !isSending
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text("New Poll")
                .font(.title2.bold())
                .padding([.horizontal, .top], Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.s)
            form
                .formStyle(.grouped)
                .frame(minHeight: 320, maxHeight: 460)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: 440)
        .errorAlert("Couldn’t Send the Poll", message: $error)
        #else
        NavigationStack {
            form
                .navigationTitle("New Poll")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send", role: .confirm, action: send)
                            .disabled(!canSend)
                    }
                }
        }
        .interactiveDismissDisabled(!question.isEmpty || !filledAnswers.isEmpty)
        .errorAlert("Couldn’t Send the Poll", message: $error)
        #endif
    }

    private var form: some View {
        Form {
            Section("Question") {
                questionField
                    .labelsHidden()
                    .focused($focus, equals: .question)
                    .submitLabel(.next)
            }
            Section("Answers") {
                ForEach($answers) { $answer in
                    HStack {
                        TextField("Answer", text: $answer.text, prompt: Text("Answer"))
                            .labelsHidden()
                            .focused($focus, equals: .answer(answer.id))
                            .submitLabel(.next)
                            .onSubmit { advance(from: answer.id) }
                        #if os(macOS)
                        // The Mac has no swipe to delete.
                        if answers.count > 2 {
                            Button("Remove Answer", systemImage: "minus.circle.fill") {
                                withAnimation(Theme.Motion.row) { answers.removeAll { $0.id == answer.id } }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove Answer")
                        }
                        #endif
                    }
                }
                .onDelete { offsets in
                    answers.remove(atOffsets: offsets)
                    while answers.count < 2 { answers.append(Answer()) }
                }
                if answers.count < Self.maxAnswers {
                    Button("Add Answer", systemImage: "plus.circle.fill") {
                        withAnimation(Theme.Motion.row, addAnswer)
                    }
                        #if os(macOS)
                        .buttonStyle(.borderless)
                        #endif
                }
            }
            Section {
                Toggle("Allow Multiple Answers", isOn: $allowsMultiple)
                Toggle("Show Results While Voting", isOn: $showsResults.animation(Theme.Motion.row))
            } footer: {
                if !showsResults {
                    Text("Votes stay hidden until you end the poll.")
                }
            }
        }
        .onAppear { focus = .question }
    }

    @ViewBuilder
    private var questionField: some View {
        #if os(iOS)
        // Wraps long questions; Return still moves on to the answers.
        TextField("Question", text: $question, prompt: Text("Ask a Question"), axis: .vertical)
            .lineLimit(1...4)
            .onChange(of: question) { _, typed in
                guard typed.contains("\n") else { return }
                question = typed.replacingOccurrences(of: "\n", with: "")
                focus = answers.first.map { .answer($0.id) }
            }
        #else
        TextField("Question", text: $question, prompt: Text("Ask a Question"))
            .onSubmit { focus = answers.first.map { .answer($0.id) } }
        #endif
    }

    private func addAnswer() {
        let answer = Answer()
        answers.append(answer)
        focus = .answer(answer.id)
    }

    private func advance(from id: UUID) {
        guard let index = answers.firstIndex(where: { $0.id == id }) else { return }
        if index + 1 < answers.count {
            focus = .answer(answers[index + 1].id)
        } else if !answers[index].text.trimmingCharacters(in: .whitespaces).isEmpty, answers.count < Self.maxAnswers {
            addAnswer()
        } else if canSend {
            // Return on the empty last answer: the poll is done.
            send()
        }
    }

    private func send() {
        guard canSend else { return }
        isSending = true
        Task {
            do {
                try await conversation.createPoll(
                    question: question, answers: answers.map(\.text),
                    allowsMultiple: allowsMultiple, showsResults: showsResults
                )
                dismiss()
            } catch {
                isSending = false
                self.error = Copy.error(error)
            }
        }
    }
}
