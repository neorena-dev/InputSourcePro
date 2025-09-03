import AppKit
import Carbon
import Combine
import IOKit
import os

@MainActor
class PunctuationService: ObservableObject {
    private let logger = ISPLogger(category: String(describing: PunctuationService.self))
    
    private var isEnabled = false
    private var eventTap: CFMachPort?
    private weak var preferencesVM: PreferencesVM?
    
    private var cachedInputSource: InputSource?
    private var inputSourceCacheTime: TimeInterval = 0
    private let inputSourceCacheTimeout: TimeInterval = 0.5
    
    private let cjkvToEnglishPunctuationMap: [UInt16: String] = [
        43: ",",    
        47: ".",    
        41: ";",    
        39: "'",    
        42: "\"",   
        33: "[",    
        30: "]",    
        49: " ",    
    ]
    
    init(preferencesVM: PreferencesVM) {
        self.preferencesVM = preferencesVM
    }
    
    deinit {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
    }
    
    func enable() {
        guard !isEnabled else { return }
        
        let hasPermission = PermissionsVM.checkInputMonitoring(prompt: false)
        
        if !hasPermission {
            logger.debug { "Input Monitoring permission check failed, attempting fallback activation" }
        } else {
            logger.debug { "Input Monitoring permission verified" }
        }
        
        logger.debug { "Enabling English punctuation service for app-aware switching" }
        let success = startMonitoring()
        
        if success {
            isEnabled = true
            logger.debug { "English punctuation service started successfully" }
        } else {
            logger.debug { "Failed to start English punctuation service - Input Monitoring permission required" }
        }
    }
    
    func disable() {
        guard isEnabled else { return }
        
        logger.debug { "Disabling English punctuation service" }
        stopMonitoring()
        isEnabled = false
    }
    
    @discardableResult
    private func startMonitoring() -> Bool {
        stopMonitoring()
        
        logger.debug { "Starting event tap creation (skipping preflight checks)" }
        
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon,
                  let service = Unmanaged<PunctuationService>.fromOpaque(refcon).takeUnretainedValue() as? PunctuationService
            else { 
                return Unmanaged.passUnretained(event) 
            }
            
            return service.handleKeyEvent(proxy: proxy, type: type, event: event)
        }
        
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPointer
        ) else {
            logger.debug { "Failed to create event tap - insufficient permissions" }
            return false
        }
        
        eventTap = tap
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        CGEvent.tapEnable(tap: tap, enable: true)
        
        logger.debug { "Event tap created and enabled successfully" }
        return true
    }
    
    private func stopMonitoring() {
        guard let eventTap = eventTap else { return }
        
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        
        logger.debug { "Event tap stopped and invalidated" }
    }
    
    private nonisolated func handleKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        
        guard let englishReplacement = cjkvToEnglishPunctuationMap[UInt16(keyCode)] else {
            return Unmanaged.passUnretained(event)
        }
        
        let currentInputSource = getCachedCurrentInputSource()
        guard currentInputSource.isCJKVR else {
            return Unmanaged.passUnretained(event)
        }
        
        logger.debug { "🎯 Intercepting punctuation key: \(keyCode) ('\(englishReplacement)') in CJKV input method: \(currentInputSource.name ?? "unknown")" }
        
        if let newEvent = createEnglishPunctuationEvent(originalEvent: event, replacement: englishReplacement) {
            logger.debug { "✅ Successfully created replacement event, returning new event" }
            return Unmanaged.passRetained(newEvent)
        } else {
            logger.debug { "❌ Failed to create replacement event, passing through original" }
            return Unmanaged.passUnretained(event)
        }
    }
    
    private func createEnglishPunctuationEvent(originalEvent: CGEvent, replacement: String) -> CGEvent? {
        let originalKeyCode = CGKeyCode(originalEvent.getIntegerValueField(.keyboardEventKeycode))
        
        guard let source = CGEventSource(stateID: .privateState),
              let newEvent = CGEvent(keyboardEventSource: source, virtualKey: originalKeyCode, keyDown: true)
        else { 
            logger.debug { "Failed to create CGEventSource or CGEvent with keyCode: \(originalKeyCode)" }
            return nil 
        }
        
        let unicodeString = Array(replacement.utf16)
        newEvent.keyboardSetUnicodeString(stringLength: unicodeString.count, unicodeString: unicodeString)
        
        newEvent.timestamp = originalEvent.timestamp
        newEvent.flags = []
        
        logger.debug { "Created ASCII replacement event for: '\(replacement)' using original keyCode: \(originalKeyCode)" }
        
        return newEvent
    }
    
    func shouldEnableForApp(_ app: NSRunningApplication) -> Bool {
        guard let preferencesVM = preferencesVM else { return false }
        
        let appRule = preferencesVM.getAppCustomization(app: app)
        return appRule?.shouldForceEnglishPunctuation == true
    }
    
    private func getCachedCurrentInputSource() -> InputSource {
        let currentTime = CACurrentMediaTime()
        
        if let cached = cachedInputSource, 
           currentTime - inputSourceCacheTime < inputSourceCacheTimeout {
            return cached
        }
        
        let currentInputSource = InputSource.getCurrentInputSource()
        cachedInputSource = currentInputSource
        inputSourceCacheTime = currentTime
        
        return currentInputSource
    }
    
    func checkServiceStatus() {
        let permissionViaIOHID = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        let permissionViaCGEvent = PermissionsVM.checkInputMonitoring(prompt: false)
        let accessibilityEnabled = PermissionsVM.checkAccessibility(prompt: false)
        let currentInputSource = InputSource.getCurrentInputSource()
        
        logger.debug { """
            🔍 English Punctuation Service Diagnostic:
            - Service Enabled: \(isEnabled)
            - Event Tap Active: \(eventTap != nil)
            - IOHIDCheckAccess (Input Monitoring): \(permissionViaIOHID ? "✅ Granted" : "❌ Denied")
            - CGEvent Permission Check: \(permissionViaCGEvent ? "✅ Passed" : "❌ Failed")  
            - Accessibility Permission: \(accessibilityEnabled ? "✅ Granted" : "❌ Denied")
            - Current Input Source: \(currentInputSource.name ?? "unknown") (CJKV: \(currentInputSource.isCJKVR))
            - Monitored Keys: \(cjkvToEnglishPunctuationMap.map { "\($0.key)→'\($0.value)'" }.joined(separator: ", "))
            """ }
    }
}