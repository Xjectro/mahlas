import SwiftUI
import AppKit

@main
struct MahlasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var session = SessionManager()

    init() {
        Fonts.register()
    }

    var body: some Scene {
        WindowGroup("Mahlas") {
            RootView()
                .environmentObject(session)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
                .onAppear { delegate.session = session }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Oturum") {
                Button("Yeni Kimlikle Başlat") { Task { await session.newIdentity() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!session.isReadyToLaunch || session.phase.isBusy)
                Button("Oturumu Kapat") { Task { await session.stopSession() } }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!session.phase.hasMachine)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var session: SessionManager?
    private var terminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Snapshot.runIfRequested() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Never leave a VM (and its disk) behind: shut everything down first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session, !terminating else { return .terminateNow }
        let active = MainActor.assumeIsolated { session.phase.hasMachine }
        guard active else { return .terminateNow }
        terminating = true
        Task { @MainActor in
            await session.stopSession()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
