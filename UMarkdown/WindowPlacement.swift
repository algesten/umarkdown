import Cocoa
import ColorSync

/// Saves window geometry in points relative to a display's usable top-left
/// corner, so rearranging displays does not move the window to another screen.
final class WindowPlacementStore {
    struct Screen: Equatable {
        let id: String
        let visibleFrame: NSRect

        init(id: String, visibleFrame: NSRect) {
            self.id = id
            self.visibleFrame = visibleFrame
        }

        init?(_ screen: NSScreen) {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = number.uint32Value
            if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                id = CFUUIDCreateString(nil, uuid) as String
            } else {
                id = "display-\(displayID)"
            }
            visibleFrame = screen.visibleFrame
        }

        static var current: [Screen] { NSScreen.screens.compactMap(Screen.init) }
        static var mainID: String? { NSScreen.main.flatMap(Screen.init)?.id }
    }

    private struct Placement: Codable {
        let left: CGFloat
        let top: CGFloat
        let width: CGFloat
        let height: CGFloat

        var isValid: Bool {
            [left, top, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
        }
    }

    private struct State: Codable {
        var lastScreenID: String?
        var placements: [String: Placement] = [:]
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "PreviewWindowPlacement") {
        self.defaults = defaults
        self.key = key
    }

    private var state: State {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    func save(frame: NSRect, on screen: Screen) {
        let placement = Placement(left: frame.minX - screen.visibleFrame.minX,
                                  top: screen.visibleFrame.maxY - frame.maxY,
                                  width: frame.width, height: frame.height)
        guard placement.isValid else { return }
        // Read the latest state so different document windows retain each
        // other's display records rather than replacing them with stale data.
        var state = self.state
        state.placements[screen.id] = placement
        state.lastScreenID = screen.id
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
    }

    func activate(frame: NSRect, on screen: Screen) {
        var state = self.state
        guard state.placements[screen.id] != nil else {
            save(frame: frame, on: screen)
            return
        }
        state.lastScreenID = screen.id
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
    }

    func restore(screens: [Screen], preferredScreenID: String?, fallbackSize: NSSize,
                 minimumSize: NSSize, useLastScreen: Bool = true) -> (screen: Screen, frame: NSRect)? {
        let state = self.state
        guard let screen = (useLastScreen ? screens.first { $0.id == state.lastScreenID } : nil)
            ?? screens.first(where: { $0.id == preferredScreenID }) ?? screens.first else { return nil }
        let saved = state.placements[screen.id].flatMap { $0.isValid ? $0 : nil }
        let last = state.lastScreenID.flatMap { state.placements[$0] }.flatMap { $0.isValid ? $0 : nil }
        let visible = screen.visibleFrame
        let width = min(visible.width, max(minimumSize.width, saved?.width ?? last?.width ?? fallbackSize.width))
        let height = min(visible.height, max(minimumSize.height, saved?.height ?? last?.height ?? fallbackSize.height))
        let left = saved?.left ?? (visible.width - width) / 2
        let top = saved?.top ?? (visible.height - height) / 2
        let x = min(max(visible.minX + left, visible.minX), visible.maxX - width)
        let y = min(max(visible.maxY - top - height, visible.minY), visible.maxY - height)
        return (screen, NSRect(x: x, y: y, width: width, height: height))
    }
}

/// Observes only the standalone document window; Finder owns Quick Look's
/// window geometry. Automatic display adjustments never replace saved sizes.
final class WindowPlacement: NSObject {
    private weak var window: NSWindow?
    private let store: WindowPlacementStore
    private var screens = WindowPlacementStore.Screen.current
    private var screenID: String?
    private var adjusting = false
    private var screenChangePending = false
    private var fullScreenTransition = false
    private var restoredFrame: NSRect?

    init(window: NSWindow, store: WindowPlacementStore = WindowPlacementStore()) {
        self.window = window
        self.store = store
        super.init()
        restore(useLastScreen: true)
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification] {
            center.addObserver(self, selector: #selector(save), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(activate), name: NSWindow.didBecomeMainNotification, object: window)
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(beginFullScreenTransition), name: name, object: window)
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(endFullScreenTransition), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(screensChanged),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func save() {
        guard let window, window.isVisible, !window.isMiniaturized,
              !adjusting, !fullScreenTransition, !window.styleMask.contains(.fullScreen) else { return }
        // AppKit may move windows before posting the display notification.
        // Detect that here too, before recording the automatic fallback frame.
        guard screens == WindowPlacementStore.Screen.current else {
            screensChanged()
            return
        }
        guard !screenChangePending, window.frame != restoredFrame,
              let screen = window.screen.flatMap(WindowPlacementStore.Screen.init) else { return }
        restoredFrame = nil
        screenID = screen.id
        store.save(frame: window.frame, on: screen)
    }

    @objc private func activate() {
        guard let window, !adjusting, !screenChangePending, !fullScreenTransition,
              !window.styleMask.contains(.fullScreen),
              screens == WindowPlacementStore.Screen.current,
              let screen = window.screen.flatMap(WindowPlacementStore.Screen.init) else { return }
        screenID = screen.id
        store.activate(frame: window.frame, on: screen)
    }

    private func restore(useLastScreen: Bool) {
        guard let window,
              let placement = store.restore(screens: screens,
                                            preferredScreenID: screens.contains(where: { $0.id == screenID })
                                                ? screenID : WindowPlacementStore.Screen.mainID,
                                            fallbackSize: window.frame.size, minimumSize: window.minSize,
                                            useLastScreen: useLastScreen) else { return }
        adjusting = true
        window.setFrame(placement.frame, display: window.isVisible)
        restoredFrame = window.frame
        screenID = placement.screen.id
        adjusting = false
    }

    @objc private func screensChanged() {
        guard !screenChangePending else { return }
        screenChangePending = true
        // Coalesce AppKit's move/resize/display notifications and wait until
        // its own relocation has finished before applying the saved geometry.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.screenChangePending = false
            guard !self.fullScreenTransition, let window = self.window,
                  !window.styleMask.contains(.fullScreen) else { return }
            let screens = WindowPlacementStore.Screen.current
            guard self.screens != screens else { return }
            self.screens = screens
            self.restore(useLastScreen: false)
        }
    }

    @objc private func beginFullScreenTransition() {
        save()
        fullScreenTransition = true
    }

    @objc func endFullScreenTransition() {
        fullScreenTransition = false
        screensChanged()
    }
}
