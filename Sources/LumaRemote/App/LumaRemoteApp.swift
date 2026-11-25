import SwiftUI

@main
struct LumaRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(manager: LightManager.shared)
        }
    }
}
