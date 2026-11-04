import SwiftUI
import Virtualization

struct DesktopView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var captureKeys = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                Color.black
                if let vm = session.macVM {
                    VMScreen(vm: vm, captureSystemKeys: captureKeys)
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.red.opacity(0.35)))
            .shadow(color: Theme.red.opacity(0.2), radius: 24)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                SectionLabel(text: session.phase == .firstSetup ? "İlk açılış" : "Masaüstü")
                Text(session.phase == .firstSetup ? "Altın imaj kurulumu" : (session.identity?.computerName ?? "Mac"))
                    .font(Theme.display(18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            if let id = session.identity, session.phase == .running {
                Text("\(id.location.flag) \(id.location.displayName)")
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.05)))
                TunnelPill()
            }
            Spacer()
            Toggle(isOn: $captureKeys) { Text("⌘ tuşlarını yakala").font(Theme.body(12)) }
                .toggleStyle(.checkbox)
                .help("Açıkken ⌘Tab, ⌘Space gibi kısayollar sanal Mac'e gider")
            if session.phase.hasMachine {
                Button { Task { await session.stopSession() } } label: {
                    Label(session.phase == .firstSetup ? "Kapat" : "Kapat ve Sil", systemImage: "power")
                }
                .buttonStyle(RedButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 16)
    }

    private var placeholder: some View {
        VStack(spacing: 16) {
            if session.phase.isBusy {
                ProgressView().controlSize(.large).tint(Theme.red)
                Text(statusText)
                    .font(Theme.display(18, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Ağ geçidi tüneli kurduktan sonra Mac burada açılacak.")
                    .font(Theme.body(13)).foregroundStyle(Theme.dim)
            } else {
                LogoMark().frame(width: 64, height: 64).opacity(0.85)
                Text("Çalışan bir oturum yok")
                    .font(Theme.display(18, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Yeni bir kimlikle temiz bir Mac başlat.")
                    .font(Theme.body(13)).foregroundStyle(Theme.dim)
                if session.isReadyToLaunch {
                    Button { Task { await session.startSession() } } label: { Label("Yeni Kimlikle Başlat", systemImage: "bolt.fill") }
                        .buttonStyle(RedButtonStyle())
                        .padding(.top, 6)
                }
            }
        }
    }

    private var statusText: String {
        if case .working(let s) = session.phase { return s }
        return "Hazırlanıyor…"
    }
}

struct TunnelPill: View {
    @EnvironmentObject private var session: SessionManager
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: session.tunnelUp ? "lock.shield.fill" : "lock.trianglebadge.exclamationmark")
            Text(session.tunnelUp ? (session.exit?.ip ?? "Şifreli") : "Tünel doğrulanıyor")
        }
        .font(Theme.mono(11, weight: .medium))
        .foregroundStyle(session.tunnelUp ? Theme.ok : Theme.warn)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill((session.tunnelUp ? Theme.ok : Theme.warn).opacity(0.1)))
    }
}

/// Apple's native VM display — keyboard, trackpad and retina scaling included.
struct VMScreen: NSViewRepresentable {
    let vm: VZVirtualMachine
    let captureSystemKeys: Bool

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = captureSystemKeys
        // Keep the session's randomized resolution (part of its fingerprint).
        view.automaticallyReconfiguresDisplay = false
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== vm { view.virtualMachine = vm }
        view.capturesSystemKeys = captureSystemKeys
    }
}
