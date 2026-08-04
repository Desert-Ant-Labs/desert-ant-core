import Emo
import SwiftUI

// One shared suggester, reused across the app. Construction is cheap and the
// model loads (downloading on demand) on first use.
private let emo = Emo()


struct Todo: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var emoji: String
}


@MainActor
@Observable
final class TodoStore {

    init() {
        load()
    }


    var todos: [Todo] = [] {
        didSet { save() }
    }

    func add(_ todo: Todo) {
        todos.append(todo)
    }

    func remove(_ todo: Todo) {
        todos.removeAll { $0.id == todo.id }
    }


    private let key = "todos"

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([Todo].self, from: data)
        else { return }
        todos = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(todos) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}


struct ContentView: View {

    var body: some View {
        NavigationStack {
            Group {
                if store.todos.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Todo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Todo", systemImage: "plus") {
                        showingAdd = true
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddTodoView { todo in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        store.add(todo)
                    }
                }
            }
        }
    }


    @State private var store = TodoStore()
    @State private var showingAdd = false

    private var list: some View {
        List {
            ForEach(store.todos) { todo in
                TodoRow(todo: todo) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        store.remove(todo)
                    }
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("✨")
                .font(.system(size: 64))
                .opacity(0.4)
            Text("No todos yet")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Tap + to add one")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
        }
    }
}


struct TodoRow: View {

    let todo: Todo
    let onComplete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(todo.emoji)
                .font(.system(size: 30))
                .frame(width: 40)
                .scaleEffect(completing ? 0.7 : 1)
                .opacity(completing ? 0 : 1)

            Text(todo.title)
                .font(.system(size: 17))
                .strikethrough(completing, color: .secondary)
                .foregroundStyle(completing ? .secondary : .primary)

            Spacer(minLength: 8)

            Button(action: complete) {
                ZStack {
                    Circle()
                        .strokeBorder(.secondary.opacity(0.6), lineWidth: 1.5)
                        .opacity(completing ? 0 : 1)

                    Circle()
                        .fill(Color.accentColor)
                        .scaleEffect(completing ? 1 : 0.01)
                        .opacity(completing ? 1 : 0)

                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .scaleEffect(completing ? 1 : 0.2)
                        .opacity(completing ? 1 : 0)
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .opacity(completing ? 0.6 : 1)
        .sensoryFeedback(.success, trigger: completing)
        .transition(.asymmetric(
            insertion: .opacity,
            removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .trailing))
        ))
    }


    @State private var completing = false

    private func complete() {
        guard !completing else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            completing = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            onComplete()
        }
    }
}


struct AddTodoView: View {

    let onSave: (Todo) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                Spacer()

                emojiBadge

                TextField("What's on your list?", text: $title)
                    .focused($focused)
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 22)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.thinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 24)

                Spacer()
                Spacer()
            }
            .navigationTitle("New Todo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(trimmedTitle.isEmpty)
                }
            }
            .sensoryFeedback(.selection, trigger: emoji)
            .onChange(of: title) { _, newValue in
                updateEmoji(for: newValue)
            }
            .onAppear { focused = true }
        }
    }


    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var emoji = "✨"
    @State private var predictionTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emojiBadge: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            .accentColor.opacity(0.22),
                            .accentColor.opacity(0.06),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                .frame(width: 168, height: 168)
                .shadow(color: .accentColor.opacity(0.18), radius: 24, y: 12)

            Text(emoji)
                .font(.system(size: 92))
                .id(emoji)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
                .opacity(trimmedTitle.isEmpty ? 0.5 : 1)
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.62), value: emoji)
    }

    private func updateEmoji(for text: String) {
        predictionTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            emoji = "✨"
            return
        }

        predictionTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            let next = (try? await emo.suggestions(for: trimmed, limit: 1))?.first?.emoji
            guard !Task.isCancelled, let next else { return }

            await MainActor.run {
                emoji = next
            }
        }
    }

    private func save() {
        let title = trimmedTitle
        guard !title.isEmpty else { return }

        predictionTask?.cancel()
        Task {
            let predicted = (try? await emo.suggestions(for: title, limit: 1))?.first?.emoji
            onSave(Todo(title: title, emoji: predicted ?? emoji))
            dismiss()
        }
    }
}

#Preview {
    ContentView()
}
