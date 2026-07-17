import SwiftUI
import AppKit

@main
struct DeltaAppMain: App {
    @State private var model = AppModel(service: ServiceFactory.make())
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Running via `swift run` (no .app bundle): become a regular,
        // focusable app with a Dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup(EstuaryTheme.appName) {
            RootView(model: model)
                // Estuary accent for all system controls (selection,
                // buttons, toggles); explicit brand colors come straight
                // from EstuaryTheme.
                .tint(EstuaryTheme.accent)
                .task {
                    NSApp.activate(ignoringOtherApps: true)
                    await model.bootstrap()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Wake from sleep / regained focus: fetch immediately
                    // instead of waiting for the next poll interval.
                    if phase == .active {
                        Task {
                            try? await model.service.maybeNetwork()
                            // Mark the visible chat read now that the user
                            // can actually see it (never while inactive).
                            await model.appDidBecomeActive()
                        }
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { model.showNewChat = true }
                    .keyboardShortcut("n")
                    .disabled(model.screen != .main)
                Button("New Group") { model.showNewGroup = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.screen != .main)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Profile Settings…") { model.showSettings = true }
                    .keyboardShortcut(",")
                    .disabled(model.screen != .main)
            }
            CommandMenu("Chats") {
                Button(model.showingArchive ? "Show Chats" : "Show Archived Chats") {
                    Task { await model.toggleArchive() }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.screen != .main)
            }
        }
    }
}

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.screen {
        case .loading:
            ProgressView()
                .frame(minWidth: 460, minHeight: 480)
        case .onboarding:
            OnboardingView(model: model)
        case .main:
            MainView(model: model)
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}
