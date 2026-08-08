import CoreAudio
import XCTest
@testable import LocalFlowApp

final class AudioInputRouteManagerTests: XCTestCase {
    func testBluetoothInputPrefersBuiltInMicrophone() {
        let airPods = makeDevice(
            id: 10,
            name: "AirPods",
            transport: kAudioDeviceTransportTypeBluetooth,
            sampleRate: 24_000
        )
        let builtIn = makeDevice(
            id: 20,
            name: "MacBook Microphone",
            transport: kAudioDeviceTransportTypeBuiltIn,
            sampleRate: 48_000
        )

        let selected = AudioInputRoutePolicy.preferredInput(
            current: airPods,
            availableDevices: [airPods, builtIn]
        )

        XCTAssertEqual(selected, builtIn)
    }

    func testBluetoothLEInputAlsoPrefersBuiltInMicrophone() {
        let bluetoothLE = makeDevice(
            id: 11,
            name: "Wireless Headset",
            transport: kAudioDeviceTransportTypeBluetoothLE,
            sampleRate: 24_000
        )
        let builtIn = makeDevice(
            id: 21,
            name: "MacBook Microphone",
            transport: kAudioDeviceTransportTypeBuiltIn,
            sampleRate: 44_100
        )

        let selected = AudioInputRoutePolicy.preferredInput(
            current: bluetoothLE,
            availableDevices: [bluetoothLE, builtIn]
        )

        XCTAssertEqual(selected.id, builtIn.id)
    }

    func testNonBluetoothInputIsNeverOverridden() {
        let usb = makeDevice(
            id: 30,
            name: "USB Interface",
            transport: kAudioDeviceTransportTypeUSB,
            sampleRate: 48_000
        )
        let builtIn = makeDevice(
            id: 20,
            name: "MacBook Microphone",
            transport: kAudioDeviceTransportTypeBuiltIn,
            sampleRate: 44_100
        )

        let selected = AudioInputRoutePolicy.preferredInput(
            current: usb,
            availableDevices: [usb, builtIn]
        )

        XCTAssertEqual(selected, usb)
    }

    func testBluetoothInputRemainsSelectedWithoutBuiltInAlternative() {
        let airPods = makeDevice(
            id: 10,
            name: "AirPods",
            transport: kAudioDeviceTransportTypeBluetooth,
            sampleRate: 24_000
        )
        let virtual = makeDevice(
            id: 40,
            name: "Virtual Input",
            transport: kAudioDeviceTransportTypeVirtual,
            sampleRate: 48_000
        )

        let selected = AudioInputRoutePolicy.preferredInput(
            current: airPods,
            availableDevices: [airPods, virtual]
        )

        XCTAssertEqual(selected, airPods)
    }

    private func makeDevice(
        id: AudioDeviceID,
        name: String,
        transport: UInt32,
        sampleRate: Double
    ) -> AudioInputDeviceDescriptor {
        AudioInputDeviceDescriptor(
            id: id,
            name: name,
            transportType: transport,
            nominalSampleRate: sampleRate,
            hasInputStreams: true
        )
    }
}
