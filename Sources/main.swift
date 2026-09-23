// TapClick — adds tap-to-click to the Apple Magic Mouse.
//
// Reads raw touch frames from the private MultitouchSupport framework, detects short
// stationary taps on the mouse surface, and posts a synthetic click at the cursor.

import AppKit
import ApplicationServices
import IOKit
import ServiceManagement

let debug = CommandLine.arguments.contains("--debug")

func log(_ message: @autoclosure () -> String) {
    if debug { print("[TapClick] \(message())"); fflush(stdout) }
}

// MARK: - MultitouchSupport bindings (private framework, loaded at runtime)

typealias MTDeviceRef = UnsafeMutableRawPointer
typealias MTContactCallback = @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

enum MT {
    static let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)

    static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    static let createList = symbol("MTDeviceCreateList", as: (@convention(c) () -> Unmanaged<CFArray>?).self)
    static let register = symbol("MTRegisterContactFrameCallback", as: (@convention(c) (MTDeviceRef, MTContactCallback) -> Void).self)
    static let unregister = symbol("MTUnregisterContactFrameCallback", as: (@convention(c) (MTDeviceRef, MTContactCallback) -> Void).self)
    static let start = symbol("MTDeviceStart", as: (@convention(c) (MTDeviceRef, Int32) -> Void).self)
    static let stop = symbol("MTDeviceStop", as: (@convention(c) (MTDeviceRef) -> Void).self)
    static let isBuiltIn = symbol("MTDeviceIsBuiltIn", as: (@convention(c) (MTDeviceRef) -> Bool).self)
    static let familyID = symbol("MTDeviceGetFamilyID", as: (@convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>) -> Int32).self)
    static let sensorSize = symbol("MTDeviceGetSensorSurfaceDimensions",
                                   as: (@convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32).self)
}

// Layout of the framework's per-finger record (96 bytes). Only the fields we need are read.
enum FingerLayout {
    static let stride = 96
    static let identifier = 16 // Int32
    static let state = 20      // Int32
    static let normalizedX = 32 // Float, 0...1
    static let normalizedY = 36 // Float, 0...1
    // States 3...5 cover "make touch", "touching", and "break touch".
    static let touchingStates: ClosedRange<Int32> = 3...5
}

struct Touch {
    let id: Int32
    let position: CGPoint // normalized 0...1 from the framework; millimetres once passed to the engines
}

/// Converts positions to millimetres (the surface isn't square) and feeds the gesture engines. Main thread only.
func handleFrame(device: Int, touches: [Touch]) {
    let size = DeviceManager.sensorSizes[device] ?? DeviceManager.defaultSensorSize
    let scaled = touches.map {
        Touch(id: $0.id, position: CGPoint(x: $0.position.x * size.width, y: $0.position.y * size.height))
    }
    TapEngine.shared.process(device: device, touches: scaled)
    ZoomEngine.shared.process(device: device, touches: scaled)
}

let contactCallback: MTContactCallback = { device, data, count, _, _ in
    guard let device, let data else { return 0 }
    var touches: [Touch] = []
    for i in 0..<Int(count) {
        let finger = data + i * FingerLayout.stride
        let state = finger.load(fromByteOffset: FingerLayout.state, as: Int32.self)
        guard FingerLayout.touchingStates.contains(state) else { continue }
        touches.append(Touch(
            id: finger.load(fromByteOffset: FingerLayout.identifier, as: Int32.self),
            position: CGPoint(x: CGFloat(finger.load(fromByteOffset: FingerLayout.normalizedX, as: Float.self)),
                              y: CGFloat(finger.load(fromByteOffset: FingerLayout.normalizedY, as: Float.self)))))
    }
    let key = Int(bitPattern: device)
    DispatchQueue.main.async { handleFrame(device: key, touches: touches) }
    return 0
}

// MARK: - Settings

enum Settings {
    private static let defaults = UserDefaults.standard

    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    static var twoFingerRightClick: Bool {
        get { defaults.object(forKey: "twoFingerRightClick") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "twoFingerRightClick") }
    }

    static var pinchToZoom: Bool {
        get { defaults.object(forKey: "pinchToZoom") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pinchToZoom") }
    }
}

// MARK: - Tap detection and click synthesis

final class TapEngine {
    static let shared = TapEngine()

    // Tuning
    let maxTapDuration: TimeInterval = 0.22   // longer touches are rests/holds, not taps
    let maxFingerTravel: CGFloat = 2          // mm; more is a scroll/swipe/pinch
    let maxCursorTravel: CGFloat = 8          // points; more means the mouse was being moved
    let decisionDelay: TimeInterval = 0.05    // lets a physical click event arrive before deciding
    static let syntheticTag: Int64 = 0x7A9C_11C4

    private struct Session {
        let start: TimeInterval
        let cursorStart: CGPoint
        var origins: [Int32: CGPoint] = [:]
        var maxFingers = 0
        var moved = false
    }

    private var sessions: [Int: Session] = [:]
    private var lastPhysicalClick: TimeInterval = -1
    private var lastClick: (time: TimeInterval, location: CGPoint, button: CGMouseButton, count: Int64)?

    func physicalClickOccurred(at time: TimeInterval) {
        lastPhysicalClick = time
        lastClick = nil
    }

    func process(device: Int, touches: [Touch]) {
        let now = ProcessInfo.processInfo.systemUptime

        if touches.isEmpty {
            if let session = sessions.removeValue(forKey: device) {
                evaluate(session, end: now)
            }
            return
        }

        var session = sessions[device] ?? Session(start: now, cursorStart: cursorLocation())
        for touch in touches {
            if let origin = session.origins[touch.id] {
                if hypot(touch.position.x - origin.x, touch.position.y - origin.y) > maxFingerTravel {
                    session.moved = true
                }
            } else {
                session.origins[touch.id] = touch.position
            }
        }
        session.maxFingers = max(session.maxFingers, touches.count)
        sessions[device] = session
    }

    private func evaluate(_ session: Session, end: TimeInterval) {
        let duration = end - session.start
        log(String(format: "touch ended: fingers=%d duration=%.3fs moved=%@",
                   session.maxFingers, duration, session.moved ? "yes" : "no"))

        guard Settings.enabled, duration <= maxTapDuration, !session.moved else { return }

        let button: CGMouseButton
        switch session.maxFingers {
        case 1: button = .left
        case 2 where Settings.twoFingerRightClick: button = .right
        default: return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + decisionDelay) { [self] in
            // A real button press during the touch means this was a physical click, not a tap.
            guard lastPhysicalClick < session.start - 0.05 else { return log("skipped: physical click") }
            guard !CGEventSource.buttonState(.combinedSessionState, button: .left),
                  !CGEventSource.buttonState(.combinedSessionState, button: .right) else { return log("skipped: button held") }

            let location = cursorLocation()
            guard hypot(location.x - session.cursorStart.x, location.y - session.cursorStart.y) <= maxCursorTravel else {
                return log("skipped: mouse moved")
            }
            postClick(button, at: location, time: end)
        }
    }

    private func postClick(_ button: CGMouseButton, at location: CGPoint, time: TimeInterval) {
        var count: Int64 = 1
        if let last = lastClick, last.button == button,
           time - last.time <= NSEvent.doubleClickInterval,
           hypot(location.x - last.location.x, location.y - last.location.y) <= 4 {
            count = last.count + 1
        }
        lastClick = (time, location, button, count)

        let (downType, upType): (CGEventType, CGEventType) =
            button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [downType, upType] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: location, mouseButton: button) else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: count)
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            event.post(tap: .cghidEventTap)
        }
        log("\(button == .left ? "left" : "right") click x\(count) at \(location)")
    }

    private func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}

// MARK: - Pinch to zoom

final class ZoomEngine {
    static let shared = ZoomEngine()

    // Tuning
    let startThreshold: CGFloat = 4               // mm the finger spread must change before a pinch starts
    let sensitivity: CGFloat = 0.03               // magnification per mm of spread change
    let scrollMuteAfterZoom: TimeInterval = 0.4   // the mouse keeps sending momentum scrolls after lift-off

    private enum Phase: Int64 { case began = 1, changed = 2, ended = 4 } // IOHIDEventPhaseBits

    private var fingerIDs: Set<Int32> = []
    private var startSpread: CGFloat = 0
    private var startCenter: CGPoint = .zero
    private var lastSpread: CGFloat = 0
    private var zoomingDevice: Int?
    private var muteScrollUntil: TimeInterval = 0
    private var scrollTap: CFMachPort?

    var isZooming: Bool { zoomingDevice != nil }

    func process(device: Int, touches: [Touch]) {
        if let zoomingDevice, zoomingDevice != device { return }
        guard Settings.pinchToZoom, touches.count == 2 else {
            finish()
            fingerIDs = []
            return
        }

        let (a, b) = (touches[0].position, touches[1].position)
        let spread = hypot(a.x - b.x, a.y - b.y)
        let center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)

        let ids = Set(touches.map(\.id))
        if ids != fingerIDs { // a new pair of fingers: take a fresh baseline
            finish()
            fingerIDs = ids
            startSpread = spread
            startCenter = center
            return
        }

        if !isZooming {
            let spreadChange = abs(spread - startSpread)
            let drift = hypot(center.x - startCenter.x, center.y - startCenter.y)
            // Fingers moving apart/together, not sliding the same way (which is a swipe).
            guard spreadChange >= startThreshold, spreadChange > drift else { return }
            zoomingDevice = device
            lastSpread = spread
            postMagnify(0, phase: .began)
            log("pinch began")
            return
        }

        postMagnify(Double((spread - lastSpread) * sensitivity), phase: .changed)
        lastSpread = spread
    }

    private func finish() {
        guard isZooming else { return }
        postMagnify(0, phase: .ended)
        zoomingDevice = nil
        muteScrollUntil = ProcessInfo.processInfo.systemUptime + scrollMuteAfterZoom
        log("pinch ended")
    }

    /// Posts the same event a trackpad pinch produces: a gesture event (type 29) with the zoom subtype,
    /// which apps receive as NSEvent.magnify.
    private func postMagnify(_ magnification: Double, phase: Phase) {
        guard let event = CGEvent(source: nil) else { return }
        event.type = unsafeBitCast(UInt32(29), to: CGEventType.self)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8) // kIOHIDEventTypeZoom
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase.rawValue)
        event.setDoubleValueField(CGEventField(rawValue: 113)!, value: magnification)
        event.post(tap: .cghidEventTap)
    }

    /// Swallows the mouse's own scroll events during a pinch so the page doesn't scroll while zooming.
    /// Needs Accessibility access; returns false until it's granted.
    func installScrollFilter() -> Bool {
        if scrollTap != nil { return true }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            ZoomEngine.shared.filter(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                          callback: callback, userInfo: nil) else { return false }
        scrollTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        return true
    }

    private func filter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let scrollTap { CGEvent.tapEnable(tap: scrollTap, enable: true) }
        case .scrollWheel where isZooming || ProcessInfo.processInfo.systemUptime < muteScrollUntil:
            return nil
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Device discovery

final class DeviceManager {
    /// Surface size in millimetres per device, keyed like touch frames. Main thread only.
    static var sensorSizes: [Int: CGSize] = [:]
    static let defaultSensorSize = CGSize(width: 51.5, height: 90.5) // Magic Mouse

    private(set) var mouseCount = 0
    private var deviceList: CFArray?
    private var running: [MTDeviceRef] = []
    private var pendingRestart: DispatchWorkItem?
    private var notificationPort: IONotificationPortRef?

    func start() {
        stop()
        Self.sensorSizes = [:]
        guard let createList = MT.createList, let register = MT.register, let startDevice = MT.start,
              let list = createList()?.takeRetainedValue() else {
            log("MultitouchSupport unavailable")
            return
        }
        deviceList = list
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            guard isMagicMouse(device) else { continue }
            register(device, contactCallback)
            startDevice(device, 0)
            running.append(device)
        }
        mouseCount = running.count
        log("listening to \(mouseCount) Magic Mouse device(s)")
    }

    func stop() {
        for device in running {
            MT.unregister?(device, contactCallback)
            MT.stop?(device)
        }
        running = []
        deviceList = nil
    }

    func scheduleRestart(after delay: TimeInterval = 1) {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Restart when multitouch devices connect/disconnect (e.g. the mouse reconnecting over Bluetooth).
    func watchForDeviceChanges() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let callback: IOServiceMatchingCallback = { refcon, iterator in
            drain(iterator)
            guard let refcon else { return }
            Unmanaged<DeviceManager>.fromOpaque(refcon).takeUnretainedValue().scheduleRestart()
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, IOServiceMatching("AppleMultitouchDevice"),
                                             callback, refcon, &iterator)
            drain(iterator) // arms the notification
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRestart(after: 2)
        }
    }

    private func isMagicMouse(_ device: MTDeviceRef) -> Bool {
        var family: Int32 = 0
        _ = MT.familyID?(device, &family)
        var width: Int32 = 0, height: Int32 = 0
        _ = MT.sensorSize?(device, &width, &height)
        let builtIn = MT.isBuiltIn?(device) ?? false
        // Trackpads are landscape; the Magic Mouse surface is portrait.
        let isMouse = !builtIn && (height > width || [112, 113].contains(family))
        log("device family=\(family) sensor=\(width)x\(height) builtIn=\(builtIn) -> \(isMouse ? "Magic Mouse" : "ignored")")
        if isMouse, width > 0, height > 0 { // reported in hundredths of a millimetre
            Self.sensorSizes[Int(bitPattern: device)] = CGSize(width: CGFloat(width) / 100, height: CGFloat(height) / 100)
        }
        return isMouse
    }
}

private func drain(_ iterator: io_iterator_t) {
    var service = IOIteratorNext(iterator)
    while service != 0 {
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let devices = DeviceManager()
    private var statusItem: NSStatusItem!
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        // Remember real button presses so a physical click isn't doubled by a tap.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == TapEngine.syntheticTag { return }
            TapEngine.shared.physicalClickOccurred(at: event.timestamp)
        }

        promptForAccessibility()
        installScrollFilter()
        devices.start()
        devices.watchForDeviceChanges()
    }

    func applicationWillTerminate(_ notification: Notification) {
        devices.stop()
    }

    // Rebuild the menu each time it opens so status lines are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let enabled = NSMenuItem(title: "Tap to Click", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.state = Settings.enabled ? .on : .off
        menu.addItem(enabled)

        let rightClick = NSMenuItem(title: "Two-Finger Tap to Right Click", action: #selector(toggleRightClick), keyEquivalent: "")
        rightClick.state = Settings.twoFingerRightClick ? .on : .off
        menu.addItem(rightClick)

        let zoom = NSMenuItem(title: "Two-Finger Pinch to Zoom", action: #selector(togglePinchToZoom), keyEquivalent: "")
        zoom.state = Settings.pinchToZoom ? .on : .off
        menu.addItem(zoom)

        menu.addItem(.separator())

        let status = devices.mouseCount > 0 ? "Magic Mouse connected" : "No Magic Mouse found"
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Rescan Devices", action: #selector(rescan), keyEquivalent: ""))

        if !AXIsProcessTrusted() {
            menu.addItem(NSMenuItem(title: "⚠︎ Grant Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "Quit TapClick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }

    private func updateIcon() {
        let symbol = Settings.enabled ? "cursorarrow.click" : "cursorarrow"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TapClick")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !Settings.enabled
    }

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            log("Accessibility access not granted yet; clicks can't be posted until it is")
        }
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        updateIcon()
    }

    @objc private func toggleRightClick() {
        Settings.twoFingerRightClick.toggle()
    }

    @objc private func togglePinchToZoom() {
        Settings.pinchToZoom.toggle()
    }

    private func installScrollFilter() {
        guard !ZoomEngine.shared.installScrollFilter() else { return }
        // Needs Accessibility access; keep trying until it's granted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installScrollFilter() }
    }

    @objc private func rescan() {
        devices.start()
    }

    @objc private func openAccessibilitySettings() {
        promptForAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove TapClick.app to /Applications and try again."
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
