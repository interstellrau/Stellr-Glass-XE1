// GlassBeacon.swift - a Bluetooth LE advertisement so Glass can find this iPhone for ANCS.
//
// PROTOCOL.md section 10 (phase 2). Glass reads iPhone notifications straight from
// Apple's Notification Center Service (ANCS). KitKat can't advertise, so the iPhone can't
// find Glass; instead this app advertises the StellrGlass service, and Glass connects to the
// iPhone as the LE central, bonds, and subscribes to ANCS. The service has no
// characteristics: no StellrGlass data goes over Bluetooth.
//
// In the background iOS moves advertised service UUIDs to an Apple-only overflow area, so
// Glass finds the iPhone while the app is open. Once connected, the link is iOS's, not ours.
// Main thread only (the manager uses the main queue). Not @MainActor, on purpose.

import Foundation
import CoreBluetooth

final class GlassBeacon: NSObject, CBPeripheralManagerDelegate {
    static let shared = GlassBeacon()
    static let serviceUUID = CBUUID(string: "CD23BFCC-905C-457F-B5E7-180599D5DFD2")

    private var manager: CBPeripheralManager?
    private var serviceState: ServiceState = .none

    private enum ServiceState {
        case none, adding, added
    }

    /// Creates the manager the first time (iOS asks for Bluetooth permission then), and
    /// makes sure the advertisement runs whenever Bluetooth is on.
    func start() {
        if let m = manager {
            advertiseIfReady(m)
            return
        }
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    private func advertiseIfReady(_ m: CBPeripheralManager) {
        guard m.state == .poweredOn else { return }
        switch serviceState {
        case .none:
            serviceState = .adding
            m.removeAllServices()
            m.add(CBMutableService(type: GlassBeacon.serviceUUID, primary: true))
        case .adding:
            break
        case .added:
            if !m.isAdvertising {
                m.startAdvertising([
                    CBAdvertisementDataServiceUUIDsKey: [GlassBeacon.serviceUUID],
                    CBAdvertisementDataLocalNameKey: "StellrGlass",
                ])
            }
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let text: String
        switch peripheral.state {
        case .poweredOn: text = "Bluetooth on: advertising for Glass"
        case .poweredOff: text = "Bluetooth is off: Glass can't get iPhone notifications"
        case .unauthorized: text = "Bluetooth not allowed: Settings › Privacy & Security › Bluetooth › StellrGlass"
        case .unsupported: text = "Bluetooth LE isn't supported here"
        default: text = "Bluetooth state \(peripheral.state.rawValue)"
        }
        GlassLink.shared.log(text)
        if peripheral.state != .poweredOn {
            // A Bluetooth reset drops published services: add ours again when it's back.
            serviceState = .none
        }
        advertiseIfReady(peripheral)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            serviceState = .none
            GlassLink.shared.log("Bluetooth service not added: \(error.localizedDescription)")
            return
        }
        serviceState = .added
        advertiseIfReady(peripheral)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            GlassLink.shared.log("Bluetooth advertising failed: \(error.localizedDescription)")
        }
    }
}
