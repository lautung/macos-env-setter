// PROTOTYPE — throwaway UI prototype for wayfinder ticket #4（UI 原型走查）.
// Plan: three radically different main-window variants of the env-setter app,
// switchable via the floating bottom bar or ←/→ arrow keys (the native analog
// of `?variant=`). In-memory sample data only; not production code.

import SwiftUI
import AppKit

@main
struct EnvSetterPrototypeApp: App {
    var body: some Scene {
        WindowGroup("EnvSetter 原型（用完即弃）") {
            RootView()
                .frame(minWidth: 1020, minHeight: 660)
        }
    }
}

struct RootView: View {
    @StateObject private var store = Store()
    @State private var variant = 0
    @State private var monitor: Any?
    static let names = ["A · 侧栏 + 详情", "B · 密集表格 + 状态栏", "C · 状态看板 + 工具带"]

    var body: some View {
        ZStack {
            switch variant {
            case 0: VariantA()
            case 1: VariantB()
            default: VariantC()
            }
            VStack {
                if let text = store.banner {
                    BannerView(text: text)
                }
                Spacer()
            }
            .padding(.top, 10)
            PrototypeSwitcher(index: $variant, names: Self.names)
        }
        .environmentObject(store)
        .onAppear(perform: installKeyMonitor)
        .onDisappear {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
    }

    private func installKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Don't hijack the arrows while the user is typing in a text field.
            if let responder = event.window?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            switch event.keyCode {
            case 123:
                variant = (variant - 1 + Self.names.count) % Self.names.count
                return nil
            case 124:
                variant = (variant + 1) % Self.names.count
                return nil
            default:
                return event
            }
        }
    }
}

struct BannerView: View {
    @EnvironmentObject var store: Store
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(text).font(.callout)
            Button {
                store.banner = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.gray.opacity(0.25)))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .frame(maxWidth: .infinity, alignment: .top)
        .task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            store.banner = nil
        }
    }
}
