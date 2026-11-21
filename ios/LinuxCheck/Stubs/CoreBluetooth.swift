// Linux stand-in for CoreBluetooth, used only by ios/LinuxCheck. Just the peripheral-manager
// surface GlassBeacon uses; signatures follow the iOS SDK. Behaviour: the state stays
// .unknown, so the app never adds a service or advertises in the simulation.

import Foundation

public enum CBManagerState: Int {
    case unknown = 0
    case resetting = 1
    case unsupported = 2
    case unauthorized = 3
    case poweredOff = 4
    case poweredOn = 5
}

open class CBUUID: NSObject {
    public let uuidString: String
    public init(string theString: String) {
        uuidString = theString
    }
}

open class CBAttribute: NSObject {
    open var uuid: CBUUID { return CBUUID(string: "") }
}

open class CBService: CBAttribute {}

open class CBMutableService: CBService {
    private let type: CBUUID
    public init(type UUID: CBUUID, primary isPrimary: Bool) {
        type = UUID
    }
    open override var uuid: CBUUID { return type }
}

public let CBAdvertisementDataServiceUUIDsKey: String = "kCBAdvDataServiceUUIDs"
public let CBAdvertisementDataLocalNameKey: String = "kCBAdvDataLocalName"

public protocol CBPeripheralManagerDelegate: NSObjectProtocol {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager)
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?)
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?)
}

extension CBPeripheralManagerDelegate {
    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {}
    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {}
}

open class CBPeripheralManager: NSObject {
    open weak var delegate: CBPeripheralManagerDelegate?
    open private(set) var state: CBManagerState = .unknown
    open private(set) var isAdvertising: Bool = false

    public init(delegate: CBPeripheralManagerDelegate?, queue: DispatchQueue?) {
        self.delegate = delegate
    }

    open func add(_ service: CBMutableService) {}
    open func removeAllServices() {}
    open func startAdvertising(_ advertisementData: [String: Any]?) {}
    open func stopAdvertising() {}
}
