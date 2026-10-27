//
//  QuickTogglesTests.swift
//  umbarTests
//
//  F20 quick toggles: tile mapping, battery parsing, device order, and the
//  store driven by a fake backend. Nothing here touches the real Wi-Fi,
//  Bluetooth, Focus or appearance of the test machine.
//

import Foundation
import Testing

// MARK: - Fake backend

@MainActor
private final class FakeBackend: QuickTogglesBackend {
    var onChange: (() -> Void)?

    var wifi: WiFiPower = .on
    var wifiSetError: QuickToggleError?
    private(set) var wifiSetCalls: [Bool] = []

    var bluetoothConfigured = true
    var btPermission: QuickPermission = .notDetermined
    var permissionAfterRequest: QuickPermission = .granted
    private(set) var permissionRequests = 0
    var btPowered: Bool? = true
    var devices: [QuickBluetoothDevice] = []
    var connectSucceeds = true
    private(set) var connectCalls: [String] = []
    private(set) var disconnectCalls: [String] = []
    private(set) var deviceListReads = 0

    var focusConfigured = true
    var focusPerm: QuickPermission = .granted
    var focused: Bool? = false
    var shortcutError: Error?
    private(set) var shortcutRuns: [String] = []

    var dark = true
    var darkSetError: QuickToggleError?
    private(set) var darkSetCalls: [Bool] = []

    private(set) var openedPanes: [QuickSettingsPane] = []
    private(set) var appSettingsOpened = 0

    func wifiPower() -> WiFiPower { wifi }
    func setWiFiPower(_ on: Bool) throws {
        wifiSetCalls.append(on)
        if let wifiSetError { throw wifiSetError }
        wifi = on ? .on : .off
    }

    func bluetoothPermission() -> QuickPermission { btPermission }
    func requestBluetoothPermission() async -> QuickPermission {
        permissionRequests += 1
        btPermission = permissionAfterRequest
        return btPermission
    }
    func bluetoothPowered() -> Bool? { btPowered }
    func bluetoothDevices() async -> [QuickBluetoothDevice] {
        deviceListReads += 1
        return devices
    }
    func connect(deviceID: String) async -> Bool {
        connectCalls.append(deviceID)
        guard connectSucceeds else { return false }
        devices = devices.map { $0.id == deviceID ? device($0, connected: true) : $0 }
        return true
    }
    func disconnect(deviceID: String) async -> Bool {
        disconnectCalls.append(deviceID)
        devices = devices.map { $0.id == deviceID ? device($0, connected: false) : $0 }
        return true
    }
    private func device(_ d: QuickBluetoothDevice, connected: Bool) -> QuickBluetoothDevice {
        QuickBluetoothDevice(id: d.id, name: d.name, isConnected: connected, isAudio: d.isAudio, battery: d.battery)
    }

    func focusPermission() -> QuickPermission { focusPerm }
    func requestFocusPermission() async -> QuickPermission { focusPerm }
    func focusIsActive() -> Bool? { focusPerm == .granted ? focused : nil }
    func runShortcut(named name: String) async throws {
        shortcutRuns.append(name)
        if let shortcutError { throw shortcutError }
        focused?.toggle()
    }
    func shortcutNames() async -> [String] { [] }

    func isDarkMode() -> Bool { dark }
    func setDarkMode(_ dark: Bool) async throws {
        darkSetCalls.append(dark)
        if let darkSetError { throw darkSetError }
        self.dark = dark
    }

    func open(_ pane: QuickSettingsPane) { openedPanes.append(pane) }
    func openAppSettings() { appSettingsOpened += 1 }
}

private struct SomeError: Error {}

// MARK: - Policy

@Suite("QuickTogglesPolicy", .timeLimit(.minutes(1)))
struct QuickTogglesPolicyTests {
    @Test func wifiOnAndOffToggle() {
        #expect(QuickTogglesPolicy.wifi(power: .on, busy: false, error: nil) == QuickTile(state: .on, action: .toggle))
        #expect(QuickTogglesPolicy.wifi(power: .off, busy: false, error: nil) == QuickTile(state: .off, action: .toggle))
    }

    @Test func wifiWithoutInterfaceIsUnavailable() {
        #expect(QuickTogglesPolicy.wifi(power: .noInterface, busy: false, error: nil)
            == QuickTile(state: .unavailable, action: .openSettings(.wifi)))
    }

    @Test func wifiAdminRequirementSendsToSettings() {
        #expect(QuickTogglesPolicy.wifi(power: .on, busy: false, error: .notPermitted)
            == QuickTile(state: .denied, action: .openSettings(.wifi)))
        #expect(QuickTogglesPolicy.wifi(power: .on, busy: false, error: .failed)
            == QuickTile(state: .failed, action: .toggle))
    }

    @Test func busyTilesTakeNoTap() {
        #expect(QuickTogglesPolicy.wifi(power: .on, busy: true, error: nil).action == .none)
        #expect(QuickTogglesPolicy.appearance(isDark: true, busy: true, error: nil).action == .none)
        #expect(QuickTogglesPolicy.focus(shortcut: "DND", isFocused: nil, running: true, failed: false).action == .none)
    }

    @Test func bluetoothWithoutPlistKeyIsUnavailable() {
        // Without NSBluetoothAlwaysUsageDescription TCC kills the process on
        // first IOBluetooth use, so the tile must never offer a request.
        #expect(QuickTogglesPolicy.bluetooth(configured: false, permission: .notDetermined, powered: nil)
            == QuickTile(state: .unavailable, action: .openSettings(.bluetooth)))
    }

    @Test func bluetoothPermissionStates() {
        #expect(QuickTogglesPolicy.bluetooth(configured: true, permission: .notDetermined, powered: nil)
            == QuickTile(state: .askPermission, action: .requestPermission))
        #expect(QuickTogglesPolicy.bluetooth(configured: true, permission: .denied, powered: nil)
            == QuickTile(state: .denied, action: .openSettings(.bluetoothPrivacy)))
        #expect(QuickTogglesPolicy.bluetooth(configured: true, permission: .restricted, powered: nil)
            == QuickTile(state: .denied, action: .openSettings(.bluetoothPrivacy)))
    }

    @Test func bluetoothOffDeepLinksBecauseThereIsNoPublicPowerSetter() {
        #expect(QuickTogglesPolicy.bluetooth(configured: true, permission: .granted, powered: false)
            == QuickTile(state: .off, action: .openSettings(.bluetooth)))
        #expect(QuickTogglesPolicy.bluetooth(configured: true, permission: .granted, powered: true)
            == QuickTile(state: .on, action: .showDevices))
        #expect(QuickTogglesPolicy.bluetooth(configured: true, permission: .granted, powered: nil)
            == QuickTile(state: .unknown, action: .showDevices))
    }

    @Test(arguments: ["", "   ", "\n"])
    func focusWithoutShortcutNeedsSetup(_ name: String) {
        #expect(QuickTogglesPolicy.focus(shortcut: name, isFocused: true, running: false, failed: false)
            == QuickTile(state: .needsSetup, action: .openAppSettings))
    }

    @Test func focusStateFollowsReadableStatus() {
        #expect(QuickTogglesPolicy.focus(shortcut: "DND", isFocused: true, running: false, failed: false).state == .on)
        #expect(QuickTogglesPolicy.focus(shortcut: "DND", isFocused: false, running: false, failed: false).state == .off)
        #expect(QuickTogglesPolicy.focus(shortcut: "DND", isFocused: nil, running: false, failed: false)
            == QuickTile(state: .unknown, action: .runShortcut))
        #expect(QuickTogglesPolicy.focus(shortcut: "DND", isFocused: true, running: false, failed: true)
            == QuickTile(state: .failed, action: .runShortcut))
    }

    @Test func appearanceStates() {
        #expect(QuickTogglesPolicy.appearance(isDark: true, busy: false, error: nil) == QuickTile(state: .on, action: .toggle))
        #expect(QuickTogglesPolicy.appearance(isDark: false, busy: false, error: nil) == QuickTile(state: .off, action: .toggle))
        #expect(QuickTogglesPolicy.appearance(isDark: false, busy: false, error: .automationDenied)
            == QuickTile(state: .denied, action: .openSettings(.automationPrivacy)))
        #expect(QuickTogglesPolicy.appearance(isDark: false, busy: false, error: .failed)
            == QuickTile(state: .failed, action: .toggle))
    }
}

// MARK: - Parsing and ordering

@Suite("QuickToggles parsing", .timeLimit(.minutes(1)))
struct QuickTogglesParsingTests {
    @Test func addressesFromBothSourcesMatch() {
        #expect(QuickBluetoothAddress.normalize("aa-bb-cc-01-02-03") == "AABBCC010203")
        #expect(QuickBluetoothAddress.normalize("AA:BB:CC:01:02:03") == "AABBCC010203")
    }

    @Test(arguments: [("%74", 74), ("74%", 74), ("100 %", 100), ("0%", 0)])
    func percentIgnoresLocalisedSignPosition(_ text: String, _ expected: Int) {
        #expect(QuickBatteryParser.percent(text) == expected)
    }

    @Test(arguments: ["", "%", "abc", "%101"])
    func percentRejectsGarbage(_ text: String) {
        #expect(QuickBatteryParser.percent(text) == nil)
    }

    @Test func percentRejectsNonStrings() {
        #expect(QuickBatteryParser.percent(74) == nil)
        #expect(QuickBatteryParser.percent(nil) == nil)
    }

    @Test func parsesAirPodsAndSingleBatteryDevices() throws {
        let json = """
        {"SPBluetoothDataType":[{
          "controller_properties":{},
          "device_connected":[
            {"AirPods":{"device_address":"AA:BB:CC:01:02:03","device_batteryLevelCase":"%74",
                        "device_batteryLevelLeft":"%100","device_batteryLevelRight":"%90",
                        "device_minorType":"Headphones"}}
          ],
          "device_not_connected":[
            {"Mouse":{"device_address":"11:22:33:44:55:66","device_batteryLevelMain":"55%"}},
            {"Speaker":{"device_address":"99:88:77:66:55:44"}}
          ]
        }]}
        """
        let result = QuickBatteryParser.parse(Data(json.utf8))
        #expect(result.count == 2)
        let pods = try #require(result["AABBCC010203"])
        #expect(pods.left == 100 && pods.right == 90 && pods.caseLevel == 74)
        #expect(pods.headline == 90)
        #expect(result["112233445566"] == QuickBattery(single: 55))
        #expect(result["998877665544"] == nil)
    }

    @Test(arguments: ["", "not json", "{}", "{\"SPBluetoothDataType\":{}}", "[]"])
    func unexpectedShapesGiveNoBatteries(_ text: String) {
        #expect(QuickBatteryParser.parse(Data(text.utf8)).isEmpty)
    }

    @Test func connectedFirstThenAudioThenName() {
        let mouse = QuickBluetoothDevice(id: "1", name: "Mouse", isConnected: false, isAudio: false)
        let pods = QuickBluetoothDevice(id: "2", name: "AirPods", isConnected: false, isAudio: true)
        let keyboard = QuickBluetoothDevice(id: "3", name: "Keyboard", isConnected: true, isAudio: false)
        let beats = QuickBluetoothDevice(id: "4", name: "Beats", isConnected: false, isAudio: true)
        #expect(QuickDeviceOrdering.sorted([mouse, pods, keyboard, beats]).map(\.id) == ["3", "2", "4", "1"])
    }
}

// MARK: - Store

@Suite("QuickTogglesStore", .timeLimit(.minutes(1)))
@MainActor
struct QuickTogglesStoreTests {
    private func makeStore(_ backend: FakeBackend, shortcut: String = "DND") -> QuickTogglesStore {
        QuickTogglesStore(backend: backend, focusShortcut: { shortcut })
    }

    @Test func initialRefreshNeverRequestsPermissionsOrListsDevices() {
        let backend = FakeBackend()
        let store = makeStore(backend)
        #expect(backend.permissionRequests == 0)
        #expect(backend.deviceListReads == 0)
        #expect(store.bluetoothTile.state == .askPermission)
    }

    @Test func wifiTapFlipsPower() async {
        let backend = FakeBackend()
        let store = makeStore(backend)
        await store.activate(.wifi)
        #expect(backend.wifiSetCalls == [false])
        #expect(store.wifiTile.state == .off)
        await store.activate(.wifi)
        #expect(backend.wifiSetCalls == [false, true])
        #expect(store.wifiTile.state == .on)
    }

    @Test func wifiAdminRefusalShowsDeniedThenOpensSettings() async {
        let backend = FakeBackend()
        backend.wifiSetError = .notPermitted
        let store = makeStore(backend)
        await store.activate(.wifi)
        #expect(store.wifiTile.state == .denied)
        await store.activate(.wifi)
        #expect(backend.openedPanes == [.wifi])
        #expect(backend.wifiSetCalls.count == 1)
    }

    @Test func bluetoothTapAsksOnceThenListsDevices() async {
        let backend = FakeBackend()
        backend.devices = [
            QuickBluetoothDevice(id: "M", name: "Mouse", isConnected: false, isAudio: false),
            QuickBluetoothDevice(id: "P", name: "AirPods", isConnected: false, isAudio: true),
        ]
        let store = makeStore(backend)
        await store.activate(.bluetooth)
        #expect(backend.permissionRequests == 1)
        #expect(store.showingDevices)
        #expect(store.devices.map(\.id) == ["P", "M"])
        #expect(store.bluetoothTile.state == .on)
    }

    @Test func bluetoothDeclinedShowsDeniedAndNoDevices() async {
        let backend = FakeBackend()
        backend.permissionAfterRequest = .denied
        let store = makeStore(backend)
        await store.activate(.bluetooth)
        #expect(store.bluetoothTile == QuickTile(state: .denied, action: .openSettings(.bluetoothPrivacy)))
        #expect(!store.showingDevices)
        #expect(backend.deviceListReads == 0)
    }

    @Test func unconfiguredBluetoothNeverReadsPermission() async {
        let backend = FakeBackend()
        backend.bluetoothConfigured = false
        let store = makeStore(backend)
        await store.activate(.bluetooth)
        #expect(backend.permissionRequests == 0)
        #expect(backend.openedPanes == [.bluetooth])
    }

    @Test func secondBluetoothTapHidesDevices() async {
        let backend = FakeBackend()
        backend.btPermission = .granted
        let store = makeStore(backend)
        await store.activate(.bluetooth)
        #expect(store.showingDevices)
        await store.activate(.bluetooth)
        #expect(!store.showingDevices)
    }

    @Test func deviceTapConnectsAndDisconnects() async {
        let backend = FakeBackend()
        backend.btPermission = .granted
        backend.devices = [QuickBluetoothDevice(id: "P", name: "AirPods", isConnected: false, isAudio: true)]
        let store = makeStore(backend)
        await store.activate(.bluetooth)
        await store.toggleDevice("P")
        #expect(backend.connectCalls == ["P"])
        #expect(store.devices.first?.isConnected == true)
        #expect(store.deviceActivity["P"] == nil)
        await store.toggleDevice("P")
        #expect(backend.disconnectCalls == ["P"])
        #expect(store.devices.first?.isConnected == false)
    }

    @Test func failedConnectIsMarkedOnTheDevice() async {
        let backend = FakeBackend()
        backend.btPermission = .granted
        backend.connectSucceeds = false
        backend.devices = [QuickBluetoothDevice(id: "P", name: "AirPods", isConnected: false, isAudio: true)]
        let store = makeStore(backend)
        await store.activate(.bluetooth)
        await store.toggleDevice("P")
        #expect(store.deviceActivity["P"] == .failed)
    }

    @Test func unknownDeviceIsIgnored() async {
        let backend = FakeBackend()
        let store = makeStore(backend)
        await store.toggleDevice("nope")
        #expect(backend.connectCalls.isEmpty)
    }

    @Test func bluetoothTurningOffCollapsesDevices() async {
        let backend = FakeBackend()
        backend.btPermission = .granted
        let store = makeStore(backend)
        await store.activate(.bluetooth)
        backend.btPowered = false
        backend.onChange?()
        #expect(!store.showingDevices)
        #expect(store.bluetoothTile.state == .off)
    }

    @Test func focusWithoutShortcutOpensAppSettings() async {
        let backend = FakeBackend()
        let store = makeStore(backend, shortcut: "")
        await store.activate(.focus)
        #expect(backend.appSettingsOpened == 1)
        #expect(backend.shortcutRuns.isEmpty)
    }

    @Test func focusRunsTheChosenShortcutAndRereadsState() async {
        let backend = FakeBackend()
        let store = makeStore(backend, shortcut: "Toggle DND")
        #expect(store.focusTile.state == .off)
        await store.activate(.focus)
        #expect(backend.shortcutRuns == ["Toggle DND"])
        #expect(store.focusTile.state == .on)
    }

    @Test func focusStateUnknownWithoutPermission() {
        let backend = FakeBackend()
        backend.focusPerm = .notDetermined
        let store = makeStore(backend)
        #expect(store.focusTile.state == .unknown)
    }

    @Test func focusShortcutFailureShowsRetry() async {
        let backend = FakeBackend()
        backend.shortcutError = SomeError()
        let store = makeStore(backend)
        await store.activate(.focus)
        #expect(store.focusTile.state == .failed)
    }

    @Test func darkModeTapFlipsAppearance() async {
        let backend = FakeBackend()
        let store = makeStore(backend)
        await store.activate(.appearance)
        #expect(backend.darkSetCalls == [false])
        #expect(store.appearanceTile.state == .off)
    }

    @Test func automationDeniedSurvivesRefreshAndClearsAfterSettings() async {
        let backend = FakeBackend()
        backend.darkSetError = .automationDenied
        let store = makeStore(backend)
        await store.activate(.appearance)
        store.refresh()
        #expect(store.appearanceTile.state == .denied)
        await store.activate(.appearance)
        #expect(backend.openedPanes == [.automationPrivacy])
        #expect(store.appearanceTile.state == .on)
        #expect(backend.darkSetCalls.count == 1)
    }

    @Test func systemChangeNotificationRefreshes() {
        let backend = FakeBackend()
        let store = makeStore(backend)
        backend.dark = false
        backend.wifi = .off
        backend.onChange?()
        #expect(store.appearanceTile.state == .off)
        #expect(store.wifiTile.state == .off)
    }
}
