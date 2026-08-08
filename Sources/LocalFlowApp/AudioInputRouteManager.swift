import CoreAudio
import Foundation

struct AudioInputDeviceDescriptor: Equatable, Sendable {
    var id: AudioDeviceID
    var name: String
    var transportType: UInt32
    var nominalSampleRate: Double
    var hasInputStreams: Bool

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var isBuiltIn: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }
}

enum AudioInputRoutePolicy {
    static func preferredInput(
        current: AudioInputDeviceDescriptor,
        availableDevices: [AudioInputDeviceDescriptor]
    ) -> AudioInputDeviceDescriptor {
        guard current.isBluetooth else {
            return current
        }

        return availableDevices.first(where: {
            $0.hasInputStreams && $0.isBuiltIn
        }) ?? current
    }
}

enum AudioInputRouteError: Error, LocalizedError {
    case defaultInputUnavailable
    case propertyReadFailed(property: String, status: OSStatus)
    case propertyWriteFailed(property: String, status: OSStatus)
    case routeDidNotSettle(deviceName: String)

    var errorDescription: String? {
        switch self {
        case .defaultInputUnavailable:
            return "No usable microphone input is currently available."
        case let .propertyReadFailed(property, status):
            return "LocalFlow could not read the audio route (\(property), CoreAudio \(status))."
        case let .propertyWriteFailed(property, status):
            return "LocalFlow could not select the preferred microphone (\(property), CoreAudio \(status))."
        case let .routeDidNotSettle(deviceName):
            return "The microphone route did not finish switching to \(deviceName). Try reconnecting the headset."
        }
    }
}

struct AudioInputRoutePreparation: Equatable, Sendable {
    var originalDevice: AudioInputDeviceDescriptor
    var selectedDevice: AudioInputDeviceDescriptor

    var didSwitchDevice: Bool {
        originalDevice.id != selectedDevice.id
    }
}

enum AudioInputRouteManager {
    static func preparePreferredInput(
        preferBuiltInForBluetooth: Bool
    ) async throws -> AudioInputRoutePreparation {
        let devices = try CoreAudioInputDevices.availableDevices()
        let currentID = try CoreAudioInputDevices.defaultInputDeviceID()
        guard let current = devices.first(where: { $0.id == currentID }) else {
            throw AudioInputRouteError.defaultInputUnavailable
        }

        let selected = preferBuiltInForBluetooth
            ? AudioInputRoutePolicy.preferredInput(
                current: current,
                availableDevices: devices
            )
            : current

        guard selected.id != current.id else {
            let sampleRate = String(
                format: "%.0f",
                current.nominalSampleRate
            )
            LocalFlowLogger.log(
                "Audio input selected name=\(current.name) transport=\(transportLabel(current.transportType)) sampleRate=\(sampleRate) autoProtected=\(preferBuiltInForBluetooth)"
            )
            return AudioInputRoutePreparation(
                originalDevice: current,
                selectedDevice: selected
            )
        }

        try CoreAudioInputDevices.setDefaultInputDeviceID(selected.id)
        try await waitForDefaultInput(
            selected,
            timeout: .seconds(1.5)
        )
        let originalSampleRate = String(
            format: "%.0f",
            current.nominalSampleRate
        )
        let selectedSampleRate = String(
            format: "%.0f",
            selected.nominalSampleRate
        )
        LocalFlowLogger.log(
            "Audio input rerouted from=\(current.name) to=\(selected.name) reason=protect-bluetooth-output originalSampleRate=\(originalSampleRate) selectedSampleRate=\(selectedSampleRate)"
        )
        return AudioInputRoutePreparation(
            originalDevice: current,
            selectedDevice: selected
        )
    }

    private static func waitForDefaultInput(
        _ selectedDevice: AudioInputDeviceDescriptor,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            try Task.checkCancellation()
            if try CoreAudioInputDevices.defaultInputDeviceID()
                == selectedDevice.id {
                // Let CoreAudio publish the new stream format before creating
                // AVAudioEngine. This keeps an AirPods hands-free transition
                // from leaking its stale 24 kHz format into the next graph.
                try await Task.sleep(for: .milliseconds(120))
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        throw AudioInputRouteError.routeDidNotSettle(
            deviceName: selectedDevice.name
        )
    }

    private static func transportLabel(_ transportType: UInt32) -> String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "built-in"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            return "bluetooth"
        case kAudioDeviceTransportTypeUSB:
            return "usb"
        case kAudioDeviceTransportTypeVirtual:
            return "virtual"
        default:
            return "other"
        }
    }
}

private enum CoreAudioInputDevices {
    static func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr,
              deviceID != kAudioObjectUnknown else {
            throw AudioInputRouteError.propertyReadFailed(
                property: "default input",
                status: status
            )
        }
        return deviceID
    }

    static func setDefaultInputDeviceID(_ deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var selectedID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &selectedID
        )
        guard status == noErr else {
            throw AudioInputRouteError.propertyWriteFailed(
                property: "default input",
                status: status
            )
        }
    }

    static func availableDevices() throws -> [AudioInputDeviceDescriptor] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr else {
            throw AudioInputRouteError.propertyReadFailed(
                property: "device list size",
                status: sizeStatus
            )
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else {
            throw AudioInputRouteError.defaultInputUnavailable
        }
        var deviceIDs = Array(
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: count
        )
        let listStatus = deviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        guard listStatus == noErr else {
            throw AudioInputRouteError.propertyReadFailed(
                property: "device list",
                status: listStatus
            )
        }

        return deviceIDs.compactMap { deviceID in
            guard hasInputStreams(deviceID) else {
                return nil
            }
            return AudioInputDeviceDescriptor(
                id: deviceID,
                name: deviceName(deviceID),
                transportType: transportType(deviceID),
                nominalSampleRate: nominalSampleRate(deviceID),
                hasInputStreams: true
            )
        }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        )
        return status == noErr
            && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        readUInt32(
            deviceID,
            selector: kAudioDevicePropertyTransportType,
            defaultValue: kAudioDeviceTransportTypeUnknown
        )
    }

    private static func nominalSampleRate(
        _ deviceID: AudioDeviceID
    ) -> Double {
        readFloat64(
            deviceID,
            selector: kAudioDevicePropertyNominalSampleRate,
            defaultValue: Float64(0)
        )
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr, let value else {
            return "Microphone \(deviceID)"
        }
        return value.takeUnretainedValue() as String
    }

    private static func readUInt32(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        defaultValue: UInt32
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = defaultValue
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : defaultValue
    }

    private static func readFloat64(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        defaultValue: Float64
    ) -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = defaultValue
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : defaultValue
    }
}
