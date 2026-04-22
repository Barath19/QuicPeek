import SwiftUI

@main
struct QuicPeekApp: App {
    var body: some Scene {
        MenuBarExtra {
            PopoverView()
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
        }
        .menuBarExtraStyle(.window)
    }
}
