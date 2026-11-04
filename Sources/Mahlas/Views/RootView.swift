import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var introDone = false
    @State private var flashOut = false

    var body: some View {
        ZStack {
            if introDone {
                MainView()
                    .transition(.opacity)
            } else {
                IntroView {
                    introDone = true
                    flashOut = true
                    withAnimation(.easeOut(duration: 0.8)) { flashOut = false }
                }
            }
            // The intro ends on a white frame; fade it out over the app.
            Color(hex: 0xFFF5F5)
                .opacity(flashOut ? 1 : 0)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        .background(Theme.bg)
    }
}
