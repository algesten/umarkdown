import Cocoa

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

@main
struct WindowPlacementTests {
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        do {
            try run()
            print("All window placement tests passed.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func run() throws {
        typealias Screen = WindowPlacementStore.Screen
        let domain = "WindowPlacementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        func store() -> WindowPlacementStore { WindowPlacementStore(defaults: defaults) }
        let laptop = Screen(id: "laptop-uuid", visibleFrame: NSRect(x: 0, y: 40, width: 1440, height: 830))
        let external = Screen(id: "external-uuid", visibleFrame: NSRect(x: -2560, y: 0, width: 2560, height: 1410))
        let laptopFrame = NSRect(x: 130, y: 120, width: 850, height: 700)
        let externalFrame = NSRect(x: -2400, y: 300, width: 1400, height: 1000)
        func restore(_ screens: [Screen], preferred: String? = nil, minimum: NSSize = NSSize(width: 400, height: 250)) -> NSRect {
            store().restore(screens: screens, preferredScreenID: preferred,
                            fallbackSize: NSSize(width: 850, height: 700), minimumSize: minimum)!.frame
        }

        let first = restore([laptop, external], preferred: external.id)
        try check(first.size == NSSize(width: 850, height: 700) && external.visibleFrame.contains(first),
                  "First launch must use the preferred screen and fit its visible area")
        store().save(frame: laptopFrame, on: laptop)
        store().save(frame: externalFrame, on: external)
        try check(restore([laptop, external]) == externalFrame, "A fresh store must restore the last-used display and frame")
        try check(restore([laptop]) == laptopFrame, "Disconnecting a display must restore the remaining display's own placement")
        try check(restore([laptop, external]) == externalFrame, "Fallback must retain the disconnected display's placement")
        print("PASS: Persistent display records, last-used display, and disconnected-display fallback")

        let rearranged = Screen(id: external.id, visibleFrame: NSRect(x: 1440, y: -600, width: 2560, height: 1410))
        let moved = restore([laptop, rearranged])
        try check(moved == NSRect(x: 1600, y: -300, width: 1400, height: 1000),
                  "Display rearrangement must preserve the window's relative top-left position")
        let smaller = Screen(id: external.id, visibleFrame: NSRect(x: -900, y: 30, width: 900, height: 600))
        let fitted = restore([smaller])
        try check(fitted == smaller.visibleFrame, "Lower resolutions must fit the whole window, including its title bar")
        try check(restore([external]) == externalFrame, "Temporary fitting must not overwrite the saved size")
        let newScreen = Screen(id: "new-display", visibleFrame: NSRect(x: 80, y: 60, width: 700, height: 500))
        try check(restore([newScreen]) == newScreen.visibleFrame, "An unseen display must fit the last window size")
        print("PASS: Rearrangement, resolution changes, and unfamiliar displays")

        store().save(frame: NSRect(x: -4000, y: 1600, width: 150, height: 100), on: external)
        let corrected = restore([external])
        try check(corrected.size == NSSize(width: 400, height: 250) && external.visibleFrame.contains(corrected),
                  "Offscreen and undersized placements must restore within the usable screen")
        let tiny = Screen(id: "tiny", visibleFrame: NSRect(x: 0, y: 0, width: 320, height: 200))
        try check(restore([tiny]) == tiny.visibleFrame, "A display smaller than the minimum window size must remain usable")
        try check(store().restore(screens: [], preferredScreenID: nil, fallbackSize: .zero, minimumSize: .zero) == nil,
                  "No connected display must be handled without a crash")
        defaults.set(Data("invalid".utf8), forKey: "PreviewWindowPlacement")
        try check(laptop.visibleFrame.contains(restore([laptop])), "Malformed preferences must fall back to a usable default")
        print("PASS: Offscreen recovery, minimum sizes, no displays, and invalid preferences")

        let a = store()
        let b = store()
        a.save(frame: laptopFrame, on: laptop)
        b.save(frame: externalFrame, on: external)
        a.activate(frame: laptopFrame, on: laptop)
        try check(restore([laptop, external]) == laptopFrame, "Activating a window must select its screen")
        try check(restore([external]) == externalFrame, "Multiple windows must retain each other's screen records")
        let constrained = Screen(id: laptop.id, visibleFrame: NSRect(x: 0, y: 40, width: 500, height: 400))
        a.activate(frame: restore([constrained]), on: constrained)
        try check(restore([laptop]) == laptopFrame, "Activating an automatically fitted window must retain its original size")
        print("PASS: Multiple-window updates and activation preserve per-display sizes")

        defaults.removeObject(forKey: "PreviewWindowPlacement")
        guard let liveScreen = Screen.current.first else { throw Failure(description: "No macOS display available for AppKit checks") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 250)
        let observer = WindowPlacement(window: window, store: store())
        window.makeKeyAndOrderFront(nil)
        let target = NSRect(x: liveScreen.visibleFrame.minX + 80, y: liveScreen.visibleFrame.minY + 70,
                            width: min(650, liveScreen.visibleFrame.width - 100), height: min(450, liveScreen.visibleFrame.height - 100))
        window.setFrame(target, display: true)
        // AppKit posts geometry notifications on the run loop as well as
        // synchronously, depending on the window server's current state.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        try check(restore(Screen.current) == window.frame, "Real AppKit move/resize notifications must save geometry")
        let normal = window.frame
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.setFrame(liveScreen.visibleFrame, display: true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        try check(restore(Screen.current) == normal, "Full-screen transitions must not overwrite normal geometry")
        window.setFrame(normal, display: true)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        window.close()
        withExtendedLifetime(observer) {}
        let reopened = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 700),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let restoredObserver = WindowPlacement(window: reopened, store: store())
        try check(reopened.frame == normal, "A recreated AppKit window must restore its saved placement")
        withExtendedLifetime(restoredObserver) {}
        print("PASS: Real AppKit move/resize, full-screen exclusion, and window recreation")
    }
}
