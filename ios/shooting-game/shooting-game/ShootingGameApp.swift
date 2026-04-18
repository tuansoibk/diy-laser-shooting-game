import SwiftUI

@main
struct ShootingGameApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear  { UIApplication.shared.isIdleTimerDisabled = true  }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
}
