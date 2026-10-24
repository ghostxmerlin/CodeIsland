import Foundation
import IOKit.hid

/// The Mac's "ready" to the Tab5: toggle the Scroll Lock LED (HID LED page 0x08, usage 0x03) of the Tab5 keyboard.
/// The Tab5 reads it from the keyboard's LED output report. Matches VID 0x303A / PID 0x4D4C; for the bench, the
/// defaults `meilingLedVendorID` / `meilingLedProductID` point it at another keyboard (e.g. the Chain DualKey).
final class MeilingLedAck {
    static let vendorID = 0x303A, productID = 0x4D4C
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var state: [IOHIDElement: Int] = [:]
    private(set) var lastError: String?

    init() {
        let defaults = UserDefaults.standard
        let vid = defaults.integer(forKey: "meilingLedVendorID")
        let pid = defaults.integer(forKey: "meilingLedProductID")
        let match: [String: Any] = [kIOHIDVendorIDKey: vid > 0 ? vid : Self.vendorID,
                                    kIOHIDProductIDKey: pid > 0 ? pid : Self.productID]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        // The Tab5 enumerates as 303A:4D4C only while the 美玲 page is open, long after aism started: the manager
        // must run on a run loop to see devices that arrive (and leave) later (review C3).
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess { lastError = String(format: "IOHIDManagerOpen 0x%08x", opened) }
    }

    private func ledElements() -> [(IOHIDDevice, IOHIDElement)] {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        var out: [(IOHIDDevice, IOHIDElement)] = []
        let match: [String: Any] = [kIOHIDElementUsagePageKey: kHIDPage_LEDs, kIOHIDElementUsageKey: kHIDUsage_LED_ScrollLock]
        for device in devices {
            guard let elements = IOHIDDeviceCopyMatchingElements(device, match as CFDictionary,
                                                                IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]
            else { continue }
            out += elements.map { (device, $0) }
        }
        return out
    }

    var deviceConnected: Bool { !(IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).isEmpty }

    /// Flips the LED on every matching keyboard. Returns false when there is none or macOS refuses the write.
    @discardableResult
    func toggle() -> Bool {
        let leds = ledElements()
        guard !leds.isEmpty else {
            state.removeAll()
            lastError = "no Tab5 keyboard LED"
            return false
        }
        var ok = true
        for (device, element) in leds {
            var current = state[element] ?? 0
            var value = Unmanaged<IOHIDValue>.passUnretained(IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0))
            if IOHIDDeviceGetValue(device, element, &value) == kIOReturnSuccess {
                current = IOHIDValueGetIntegerValue(value.takeUnretainedValue())
            }
            let next = current == 0 ? 1 : 0
            let result = IOHIDDeviceSetValue(device, element,
                                             IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, next))
            if result == kIOReturnSuccess {
                state[element] = next
            } else {
                ok = false
                lastError = String(format: "IOHIDDeviceSetValue 0x%08x", result)
            }
        }
        return ok
    }

    /// Bench report: each matching LED's value before and after one toggle.
    func selfTest() -> String {
        let before = ledElements().map(read)
        let ok = toggle()
        let after = ledElements().map(read)
        return "leds=\(before.count) before=\(before) after=\(after) ok=\(ok) error=\(lastError ?? "-")"
    }

    private func read(_ pair: (IOHIDDevice, IOHIDElement)) -> Int {
        var value = Unmanaged<IOHIDValue>.passUnretained(IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, pair.1, 0, -1))
        guard IOHIDDeviceGetValue(pair.0, pair.1, &value) == kIOReturnSuccess else { return -1 }
        return IOHIDValueGetIntegerValue(value.takeUnretainedValue())
    }
}
