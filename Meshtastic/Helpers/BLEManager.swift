import Foundation
import CoreData
import CoreBluetooth
import SwiftUI
import MapKit

// ---------------------------------------------------------------------------------------
// Meshtastic BLE Device Manager
// ---------------------------------------------------------------------------------------
class BLEManager: NSObject, CBPeripheralDelegate, ObservableObject {

	private static var documentsFolder: URL {
		do {
			return try FileManager.default.url(for: .documentDirectory,	in: .userDomainMask, appropriateFor: nil, create: true)
		} catch {
			fatalError("Can't find documents directory.")
		}
	}

	var context: NSManagedObjectContext?
	var userSettings: UserSettings?
	private var centralManager: CBCentralManager!

	@Published var peripherals: [Peripheral] = []
	@Published var connectedPeripheral: Peripheral!
	@Published var lastConnectionError: String
	@Published var invalidVersion = false
	@Published var preferredPeripheral = false
	@Published var isSwitchedOn: Bool = false
	
	public var minimumVersion = "1.3.48"
	public var connectedVersion: String
	public var isConnecting: Bool = false
	public var isConnected: Bool = false
	public var isSubscribed: Bool = false
	private var configNonce: UInt32 = 1

	var timeoutTimer: Timer?
	var timeoutTimerCount = 0
	var timeoutTimerRuns = 0
	var positionTimer: Timer?
	let emptyNodeNum: UInt32 = 4294967295

	/* Meshtastic Service Details */
	var TORADIO_characteristic: CBCharacteristic!
	var FROMRADIO_characteristic: CBCharacteristic!
	var FROMNUM_characteristic: CBCharacteristic!

	let meshtasticServiceCBUUID = CBUUID(string: "0x6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
	let TORADIO_UUID = CBUUID(string: "0xF75C76D2-129E-4DAD-A1DD-7866124401E7")
	let FROMRADIO_UUID = CBUUID(string: "0x2C55E69E-4993-11ED-B878-0242AC120002")
	let EOL_FROMRADIO_UUID = CBUUID(string: "0x8BA2BCC2-EE02-4A55-A531-C525C5E454D5")
	let FROMNUM_UUID = CBUUID(string: "0xED9DA18C-A800-4F66-A670-AA7547E34453")

	//private var meshLoggingEnabled: Bool = true
	let meshLog = documentsFolder.appendingPathComponent("meshlog.txt")

	// MARK: init BLEManager
	override init() {
		self.lastConnectionError = ""
		self.connectedVersion = "0.0.0"
		super.init()
		centralManager = CBCentralManager(delegate: self, queue: nil)
	}

	// MARK: Scanning for BLE Devices
	// Scan for nearby BLE devices using the Meshtastic BLE service ID
	func startScanning() {
		if isSwitchedOn {
			centralManager.scanForPeripherals(withServices: [meshtasticServiceCBUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
			print("✅ Scanning Started")
		}
	}

	// Stop Scanning For BLE Devices
	func stopScanning() {
		if centralManager.isScanning {
			centralManager.stopScan()
			print("🛑 Stopped Scanning")
		}
	}

	// MARK: BLE Connect functions
	/// The action after the timeout-timer has fired
	///
	/// - Parameters:
	///     - timer: The time that fired the event
	///
	@objc func timeoutTimerFired(timer: Timer) {
		guard let timerContext = timer.userInfo as? [String: String] else { return }
		let name: String = timerContext["name", default: "Unknown"]

		self.timeoutTimerCount += 1
		self.lastConnectionError = ""

		if timeoutTimerCount == 10 {
			if connectedPeripheral != nil {
				self.centralManager?.cancelPeripheralConnection(connectedPeripheral.peripheral)
			}
			connectedPeripheral = nil
			if self.timeoutTimer != nil {
				
				self.timeoutTimer!.invalidate()
			}
			self.isConnected = false
			self.isConnecting = false
			self.lastConnectionError = "🚨 Connection failed after \(timeoutTimerCount) attempts to connect to \(name). You may need to forget your device under Settings > Bluetooth."
			MeshLogger.log(lastConnectionError)
			self.timeoutTimerCount = 0
			self.timeoutTimerRuns += 1
			self.startScanning()
		} else {
			MeshLogger.log("🚨 BLE Connecting 2 Second Timeout Timer Fired \(timeoutTimerCount) Time(s): \(name)")
		}
	}

	// Connect to a specific peripheral
	func connectTo(peripheral: CBPeripheral) {
		stopScanning()
		DispatchQueue.main.async {
			self.isConnecting = true
			self.lastConnectionError = ""
		}
		if connectedPeripheral != nil {
			MeshLogger.log("ℹ️ BLE Disconnecting from: \(connectedPeripheral.name) to connect to \(peripheral.name ?? "Unknown")")
			disconnectPeripheral()
		}
		centralManager?.connect(peripheral)
		// Invalidate any existing timer
		if timeoutTimer != nil {
			timeoutTimer!.invalidate()
		}
		// Use a timer to keep track of connecting peripherals, context to pass the radio name with the timer and the RunLoop to prevent
		// the timer from running on the main UI thread
		let context = ["name": "\(peripheral.name ?? "Unknown")"]
		timeoutTimer = Timer.scheduledTimer(timeInterval: 1.5, target: self, selector: #selector(timeoutTimerFired), userInfo: context, repeats: true)
		RunLoop.current.add(timeoutTimer!, forMode: .common)
		MeshLogger.log("ℹ️ BLE Connecting: \(peripheral.name ?? "Unknown")")
	}

	// Disconnect Connected Peripheral
	func disconnectPeripheral() {

		guard let connectedPeripheral = connectedPeripheral else { return }
		centralManager?.cancelPeripheralConnection(connectedPeripheral.peripheral)
		FROMRADIO_characteristic = nil
		isConnected = false
		isSubscribed = false
		invalidVersion = false
		connectedVersion = "0.0.0"
		startScanning()
	}

	// Called each time a peripheral is discovered
	func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
		isConnecting = false
		isConnected = true
		if userSettings?.preferredPeripheralId.count ?? 0 < 1 {
			userSettings?.preferredPeripheralId = peripheral.identifier.uuidString
			preferredPeripheral = true
		} else if userSettings!.preferredPeripheralId ==  peripheral.identifier.uuidString {
			preferredPeripheral = true
		} else {
			preferredPeripheral = false
			print("Trying to connect a non prefered peripheral")
		}
		UserDefaults.standard.synchronize()
		// Invalidate and reset connection timer count
		timeoutTimerCount = 0
		if timeoutTimer != nil {
			timeoutTimer!.invalidate()
		}
		
		// remove any connection errors
		self.lastConnectionError = ""
		// Map the peripheral to the connectedPeripheral ObservedObjects
		connectedPeripheral = peripherals.filter({ $0.peripheral.identifier == peripheral.identifier }).first
		if connectedPeripheral != nil {
			connectedPeripheral.peripheral.delegate = self
		}
		else {
			// we are null just disconnect and start over
			lastConnectionError = "Bluetooth connection error, please try again."
			disconnectPeripheral()
			return
		}
		// Discover Services
		peripheral.discoverServices([meshtasticServiceCBUUID])
		MeshLogger.log("✅ BLE Connected: \(peripheral.name ?? "Unknown")")
	}

	// Called when a Peripheral fails to connect
	func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
		disconnectPeripheral()
		MeshLogger.log("🚫 BLE Failed to Connect: \(peripheral.name ?? "Unknown")")
	}

	// Disconnect Peripheral Event
	func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
		self.connectedPeripheral = nil
		self.isConnecting = false
		self.isConnected = false
		self.isSubscribed = false
		if let e = error {
			// https://developer.apple.com/documentation/corebluetooth/cberror/code
			let errorCode = (e as NSError).code
			if errorCode == 6 { // CBError.Code.connectionTimeout The connection has timed out unexpectedly.
				// Happens when device is manually reset / powered off
				lastConnectionError = "🚨 \(e.localizedDescription) The app will automatically reconnect to the preferred radio if it come back in range."
				MeshLogger.log("🚨 BLE Disconnected: \(peripheral.name ?? "Unknown") Error Code: \(errorCode) Error: \(e.localizedDescription)")
			} else if errorCode == 7 { // CBError.Code.peripheralDisconnected The specified device has disconnected from us.
				// Seems to be what is received when a tbeam sleeps, immediately recconnecting does not work.
				lastConnectionError = e.localizedDescription
				MeshLogger.log("🚨 BLE Disconnected: \(peripheral.name ?? "Unknown") Error Code: \(errorCode) Error: \(e.localizedDescription)")
				
			} else if errorCode == 14 { // Peer removed pairing information
				// Forgetting and reconnecting seems to be necessary so we need to show the user an error telling them to do that
				lastConnectionError = "🚨 \(e.localizedDescription) This error usually cannot be fixed without forgetting the device unders Settings > Bluetooth and re-connecting to the radio."
				MeshLogger.log("🚨 BLE Disconnected: \(peripheral.name ?? "Unknown") Error Code: \(errorCode) Error: \(lastConnectionError)")
			} else {
				lastConnectionError = e.localizedDescription
				MeshLogger.log("🚨 BLE Disconnected: \(peripheral.name ?? "Unknown") Error Code: \(errorCode) Error: \(e.localizedDescription)")
			}

		} else {
			// Disconnected without error which indicates user intent to disconnect
			// Happens when swiping to disconnect
			MeshLogger.log("ℹ️ BLE Disconnected: \(peripheral.name ?? "Unknown"): User Initiated Disconnect")
		}
		// Start a scan so the disconnected peripheral is moved to the peripherals[] if it is awake
		self.startScanning()
	}

	// MARK: Peripheral Services functions
	func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
		if let e = error {
			print("🚫 Discover Services error \(e)")
		}
		guard let services = peripheral.services else { return }
		for service in services {
			if service.uuid == meshtasticServiceCBUUID {
				peripheral.discoverCharacteristics([TORADIO_UUID, FROMRADIO_UUID, FROMNUM_UUID], for: service)
				MeshLogger.log("✅ BLE Service for Meshtastic discovered by \(peripheral.name ?? "Unknown")")
			}
		}
	}

	// MARK: Discover Characteristics Event
	func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
		
		if let e = error {
			MeshLogger.log("🚫 BLE Discover Characteristics error for \(peripheral.name ?? "Unknown") \(e) disconnecting device")
			// Try and stop crashes when this error occurs
			disconnectPeripheral()
			return
		}
		
		guard let characteristics = service.characteristics else { return }

		for characteristic in characteristics {
			switch characteristic.uuid {
				
			case TORADIO_UUID:
				MeshLogger.log("✅ BLE did discover TORADIO characteristic for Meshtastic by \(peripheral.name ?? "Unknown")")
				TORADIO_characteristic = characteristic

			case FROMRADIO_UUID:
				MeshLogger.log("✅ BLE did discover FROMRADIO characteristic for Meshtastic by \(peripheral.name ?? "Unknown")")
				FROMRADIO_characteristic = characteristic
				peripheral.readValue(for: FROMRADIO_characteristic)

			case FROMNUM_UUID:
				MeshLogger.log("✅ BLE did discover FROMNUM (Notify) characteristic for Meshtastic by \(peripheral.name ?? "Unknown")")
				FROMNUM_characteristic = characteristic
				peripheral.setNotifyValue(true, for: characteristic)

			default:
				break
			}
		}
		if (![FROMNUM_characteristic, TORADIO_characteristic].contains(nil)) {
			sendWantConfig()
		}
	}
	
	func requestDeviceMetadata() {
		guard (connectedPeripheral!.peripheral.state == CBPeripheralState.connected) else { return }

		MeshLogger.log("ℹ️ Requesting Device Metadata for \(connectedPeripheral!.peripheral.name ?? "Unknown")")
		
		var adminPacket = AdminMessage()
		adminPacket.getDeviceMetadataRequest = true
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true
		
		meshPacket.decoded = dataMessage
		
		var toRadio: ToRadio = ToRadio()
		toRadio.packet = meshPacket
		
		let binaryData: Data = try! toRadio.serializedData()
		connectedPeripheral!.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
		
		// Either Read the config complete value or from num notify value
		connectedPeripheral!.peripheral.readValue(for: FROMRADIO_characteristic)
	}
	
	func sendTraceRouteRequest(destNum: Int64,  wantResponse: Bool) -> Bool {
		
		var success = false
		let fromNodeNum = connectedPeripheral.num

		let routePacket = RouteDiscovery()

		var meshPacket = MeshPacket()
		meshPacket.to = UInt32(destNum)
		meshPacket.from	= UInt32(fromNodeNum)//0 // Send 0 as from from phone to device to avoid warning about client trying to set node num
		var dataMessage = DataMessage()
		dataMessage.payload = try! routePacket.serializedData()
		dataMessage.portnum = PortNum.tracerouteApp
		dataMessage.wantResponse = wantResponse
		meshPacket.decoded = dataMessage

		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		let binaryData: Data = try! toRadio.serializedData()
		
		if connectedPeripheral!.peripheral.state == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			success = true
			MeshLogger.log("🪧 Sent a Trace Route Packet to node: \(destNum).")
		}
		return success
	}
	
	func sendWantConfig() {
		guard (connectedPeripheral!.peripheral.state == CBPeripheralState.connected) else { return }

		if FROMRADIO_characteristic == nil {
			MeshLogger.log("🚨 Unsupported Firmware Version Detected, unable to connect to device.")
			invalidVersion = true
			return
		} else {
		MeshLogger.log("ℹ️ Issuing wantConfig to \(connectedPeripheral!.peripheral.name ?? "Unknown")")
		//BLE Characteristics discovered, issue wantConfig
		var toRadio: ToRadio = ToRadio()
		configNonce += 1
		toRadio.wantConfigID = configNonce
		let binaryData: Data = try! toRadio.serializedData()
		connectedPeripheral!.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			// Either Read the config complete value or from num notify value
			connectedPeripheral!.peripheral.readValue(for: FROMRADIO_characteristic)
		}
	}

	func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {

		if let errorText = error?.localizedDescription {
			MeshLogger.log("🚫 didUpdateNotificationStateFor error: \(errorText)")
		}
	}

	// MARK: Data Read / Update Characteristic Event
	func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
	   
		if let e = error {
			
			print("🚫 didUpdateValueFor Characteristic error \(e)")

			let errorCode = (e as NSError).code
			
			if errorCode == 5 { // CBATTErrorDomain Code=5 "Authentication is insufficient."
				// BLE Pin connection error
				lastConnectionError = "🚫 BLE \(e.localizedDescription) Please try connecting again and check the PIN carefully."
				MeshLogger.log("🚫 BLE \(e.localizedDescription) Please try connecting again and check the PIN carefully.")
				self.centralManager?.cancelPeripheralConnection(peripheral)
			}
			if errorCode == 15 { // CBATTErrorDomain Code=15 "Encryption is insufficient."
				// BLE Pin connection error
				lastConnectionError = "🚫 BLE \(e.localizedDescription) Please try connecting again and check the PIN carefully."
				MeshLogger.log("🚫 BLE \(e.localizedDescription) Please try connecting again. You may need to forget the device under Settings > General > Bluetooth.")
				self.centralManager?.cancelPeripheralConnection(peripheral)
			}
		}

		switch characteristic.uuid {

		case FROMRADIO_UUID:
			
			if characteristic.value == nil || characteristic.value!.isEmpty {
				return
			}

			var decodedInfo = FromRadio()
			
			do {
				
				decodedInfo = try FromRadio(serializedData: characteristic.value!)
				
			} catch {
				print(characteristic.value!)
			}

			switch decodedInfo.packet.decoded.portnum {
				
				// Handle Any local only packets we get over BLE
				case .unknownApp:
				
				var nowKnown = false
				
				// MyInfo
				if decodedInfo.myInfo.isInitialized && decodedInfo.myInfo.myNodeNum > 0 {
					
					let lastDotIndex = decodedInfo.myInfo.firmwareVersion.lastIndex(of: ".")
					
					if lastDotIndex == nil {
						invalidVersion = true
						connectedVersion = "0.0.0"
					} else {
						let version = decodedInfo.myInfo.firmwareVersion[...(lastDotIndex ?? String.Index(utf16Offset: 6, in: decodedInfo.myInfo.firmwareVersion))]
						nowKnown = true
						connectedVersion = String(version)
					}

					let supportedVersion = connectedVersion == "0.0.0" ||  self.minimumVersion.compare(connectedVersion, options: .numeric) == .orderedAscending || minimumVersion.compare(connectedVersion, options: .numeric) == .orderedSame
					if !supportedVersion {
						invalidVersion = true
						lastConnectionError = "🚨 Update your firmware"
						return
						
					} else {
						
						let myInfo = myInfoPacket(myInfo: decodedInfo.myInfo, peripheralId: self.connectedPeripheral.id, context: context!)
						
						userSettings?.preferredNodeNum = myInfo?.myNodeNum ?? 0
						
						if myInfo != nil {
							connectedPeripheral.num = myInfo!.myNodeNum
							connectedPeripheral.firmwareVersion = myInfo?.firmwareVersion ?? "Unknown"
							connectedPeripheral.name = myInfo?.bleName ?? "Unknown"
							connectedPeripheral.longName = myInfo?.bleName ?? "Unknown"
						}
					}
				}
				// NodeInfo
				if decodedInfo.nodeInfo.num != 0 && !invalidVersion {

					nowKnown = true
					let nodeInfo = nodeInfoPacket(nodeInfo: decodedInfo.nodeInfo, channel: decodedInfo.packet.channel, context: context!)
					
					if nodeInfo != nil {
						if self.connectedPeripheral != nil && self.connectedPeripheral.num == nodeInfo!.num {
							if nodeInfo!.user != nil {
								connectedPeripheral.shortName = nodeInfo?.user?.shortName ?? "????"
								connectedPeripheral.longName = nodeInfo?.user?.longName ?? "Unknown"
							}
						}
					}
				}
				// Channels
				if decodedInfo.channel.isInitialized {
					nowKnown = true
					channelPacket(channel: decodedInfo.channel, fromNum: connectedPeripheral.num, context: context!)
				}
				
				// Config
				if decodedInfo.config.isInitialized && !invalidVersion {
					
					nowKnown = true
					localConfig(config: decodedInfo.config, context: context!, nodeNum: self.connectedPeripheral.num, nodeLongName: self.connectedPeripheral.longName)
				}
				// Module Config
				if decodedInfo.moduleConfig.isInitialized && !invalidVersion {
					
					nowKnown = true
					moduleConfig(config: decodedInfo.moduleConfig, context: context!, nodeNum: self.connectedPeripheral.num, nodeLongName: self.connectedPeripheral.longName)

					if decodedInfo.moduleConfig.payloadVariant == ModuleConfig.OneOf_PayloadVariant.cannedMessage(decodedInfo.moduleConfig.cannedMessage) {
						
						if decodedInfo.moduleConfig.cannedMessage.enabled {
							_ = self.getCannedMessageModuleMessages(destNum: self.connectedPeripheral.num, wantResponse: true)
						}
					}
				}
				// Log any other unknownApp calls
				if !nowKnown { MeshLogger.log("ℹ️ MESH PACKET received for Unknown App UNHANDLED \(try! decodedInfo.packet.jsonString())") }
				
				case .textMessageApp:
					textMessageAppPacket(packet: decodedInfo.packet, connectedNode: (self.connectedPeripheral != nil ? connectedPeripheral.num : 0), context: context!)
				case .remoteHardwareApp:
					MeshLogger.log("ℹ️ MESH PACKET received for Remote Hardware App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .positionApp:
					positionPacket(packet: decodedInfo.packet, context: context!)
				case .waypointApp:
					MeshLogger.log("ℹ️ MESH PACKET received for Waypoint App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .nodeinfoApp:
					if !invalidVersion { nodeInfoAppPacket(packet: decodedInfo.packet, context: context!) }
				case .routingApp:
					if !invalidVersion { routingPacket(packet: decodedInfo.packet, connectedNodeNum: self.connectedPeripheral.num, context: context!) }
				case .adminApp:
					adminAppPacket(packet: decodedInfo.packet, context: context!)
				case .replyApp:
					MeshLogger.log("ℹ️ MESH PACKET received for Reply App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .ipTunnelApp:
					MeshLogger.log("ℹ️ MESH PACKET received for IP Tunnel App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .serialApp:
					MeshLogger.log("ℹ️ MESH PACKET received for Serial App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .storeForwardApp:
					MeshLogger.log("ℹ️ MESH PACKET received for Store Forward App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .rangeTestApp:
					MeshLogger.log("ℹ️ MESH PACKET received for Range Test App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .telemetryApp:
				if !invalidVersion { telemetryPacket(packet: decodedInfo.packet, connectedNode: (self.connectedPeripheral != nil ? connectedPeripheral.num : 0), context: context!) }
				case .textMessageCompressedApp:
					MeshLogger.log("ℹ️ MESH PACKET received for Text Message Compressed App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .zpsApp:
					MeshLogger.log("ℹ️ MESH PACKET received for ZPS App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .privateApp:
					MeshLogger.log("ℹ️ MESH PACKET received for Private App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .atakForwarder:
					MeshLogger.log("ℹ️ MESH PACKET received for ATAK Forwarder App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .simulatorApp:
					MeshLogger.log("ℹ️ MESH PACKET received for Simulator App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .audioApp:
					MeshLogger.log("ℹ️ MESH PACKET received for Audio App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .tracerouteApp:
					if let routingMessage = try? RouteDiscovery(serializedData: decodedInfo.packet.decoded.payload) {
						
						if routingMessage.route.count == 0 {
							MeshLogger.log("🪧 Trace Route request sent to \(decodedInfo.packet.from) was recieived directly.")
						} else {
							
							var routeString = "🪧 Trace Route request returned: \(decodedInfo.packet.to) --> "
							for node in routingMessage.route {
								routeString += "\(node) --> "
							}
							routeString += "\(decodedInfo.packet.from)"
							MeshLogger.log(routeString)
						}
					}
				case .UNRECOGNIZED(_):
					MeshLogger.log("ℹ️ MESH PACKET received for Other App UNHANDLED \(try! decodedInfo.packet.jsonString())")
				case .max:
					print("MAX PORT NUM OF 511")
			}
			
			// MARK: Check for an All / Broadcast User and delete it as a transition to multi channel
			let fetchBCUserRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest.init(entityName: "UserEntity")
			fetchBCUserRequest.predicate = NSPredicate(format: "num == %lld", Int64(emptyNodeNum))

			do {
				let fetchedUser = try context?.fetch(fetchBCUserRequest) as! [UserEntity]
				if fetchedUser.count > 0 {
					
					context?.delete(fetchedUser[0])
					print("🗑️ Deleted the All - Broadcast User")
				}

			} catch {
				MeshLogger.log("💥 Error Deleting the All - Broadcast User")
			}

			if decodedInfo.configCompleteID != 0 && decodedInfo.configCompleteID == configNonce {
				invalidVersion = false
				lastConnectionError = ""
				timeoutTimerRuns = 0
				isSubscribed = true
				MeshLogger.log("🤜 BLE Config Complete Packet Id: \(decodedInfo.configCompleteID)")
				peripherals.removeAll(where: { $0.peripheral.state == CBPeripheralState.disconnected })
				// Config conplete returns so we don't read the characteristic again
				// MARK: Share Location Position Update Timer
				// Use context to pass the radio name with the timer
				// Use a RunLoop to prevent the timer from running on the main UI thread
				if userSettings?.provideLocation ?? false {
					if positionTimer != nil {
						positionTimer!.invalidate()
					}
					positionTimer = Timer.scheduledTimer(timeInterval: TimeInterval((userSettings?.provideLocationInterval ?? 900)), target: self, selector: #selector(positionTimerFired), userInfo: context, repeats: true)
					if positionTimer != nil {
						RunLoop.current.add(positionTimer!, forMode: .common)
					}
				}
				
				return
			}

		case FROMNUM_UUID :
			print("🗞️ BLE (Notify) characteristic, value will be read next")
		default:
			print("🚨 Unhandled Characteristic UUID: \(characteristic.uuid)")
		}
		if FROMRADIO_characteristic != nil {
			
			// Either Read the config complete value or from num notify value
			peripheral.readValue(for: FROMRADIO_characteristic)
		}
	}

	public func sendMessage(message: String, toUserNum: Int64, channel: Int32, isEmoji: Bool, replyID: Int64) -> Bool {
		
		var success = false

		// Return false if we are not properly connected to a device, handle retry logic in the view for now
		if connectedPeripheral == nil || connectedPeripheral!.peripheral.state != CBPeripheralState.connected {

			self.disconnectPeripheral()
			self.startScanning()

			// Try and connect to the preferredPeripherial first
			let preferredPeripheral = peripherals.filter({ $0.peripheral.identifier.uuidString == UserDefaults.standard.object(forKey: "preferredPeripheralId") as? String ?? "" }).first
			if preferredPeripheral != nil && preferredPeripheral?.peripheral != nil {
				connectTo(peripheral: preferredPeripheral!.peripheral)
			}
			MeshLogger.log("🚫 Message Send Failed, not properly connected to \(preferredPeripheral?.name ?? "Unknown")")
			success = false
			
		} else if message.count < 1 {

			// Don't send an empty message
			print("🚫 Don't Send an Empty Message")
			success = false

		} else {

			let fromUserNum: Int64 = self.connectedPeripheral.num

			let messageUsers: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest.init(entityName: "UserEntity")
			messageUsers.predicate = NSPredicate(format: "num IN %@", [fromUserNum, Int64(toUserNum)])

			do {

				let fetchedUsers = try context?.fetch(messageUsers) as! [UserEntity]

				if fetchedUsers.isEmpty {

					print("🚫 Message Users Not Found, Fail")
					success = false
					
				} else if fetchedUsers.count >= 1 {

					let newMessage = MessageEntity(context: context!)
					newMessage.messageId = Int64(UInt32.random(in: UInt32(UInt8.max)..<UInt32.max))
					newMessage.messageTimestamp =  Int32(Date().timeIntervalSince1970)
					newMessage.receivedACK = false
					if toUserNum > 0 {
						newMessage.toUser = fetchedUsers.first(where: { $0.num == toUserNum })
					}
					newMessage.fromUser = fetchedUsers.first(where: { $0.num == fromUserNum })
					newMessage.isEmoji = isEmoji
					newMessage.admin = false
					newMessage.channel = channel
					if replyID > 0 {
						newMessage.replyID = replyID
					}
					newMessage.messagePayload = message
					newMessage.messagePayloadMarkdown = generateMessageMarkdown(message: message)

					let dataType = PortNum.textMessageApp
					let payloadData: Data = message.data(using: String.Encoding.utf8)!

					var dataMessage = DataMessage()
					dataMessage.payload = payloadData
					dataMessage.portnum = dataType

					var meshPacket = MeshPacket()
					meshPacket.id = UInt32(newMessage.messageId)
					if toUserNum > 0 {
						meshPacket.to = UInt32(toUserNum)
					} else {
						meshPacket.to = emptyNodeNum
					}
					meshPacket.channel = UInt32(channel)
					meshPacket.from	= UInt32(fromUserNum)
					meshPacket.decoded = dataMessage
					meshPacket.decoded.emoji = isEmoji ? 1 : 0
					if replyID > 0 {
						meshPacket.decoded.replyID = UInt32(replyID)
					}
					meshPacket.wantAck = true

					var toRadio: ToRadio!
					toRadio = ToRadio()
					toRadio.packet = meshPacket

					let binaryData: Data = try! toRadio.serializedData()
					
					MeshLogger.log("📲 New messageId \(newMessage.messageId) sent to \(newMessage.toUser?.longName! ?? "Unknown")")
					if connectedPeripheral!.peripheral.state == CBPeripheralState.connected {
						connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
						do {

							try context!.save()
							MeshLogger.log("💾 Saved a new sent message from \(connectedPeripheral.num) to \(toUserNum)")
							success = true

						} catch {

							context!.rollback()

							let nsError = error as NSError
							MeshLogger.log("💥 Unresolved Core Data error in Send Message Function your database is corrupted running a node db reset should clean up the data. Error: \(nsError)")
						}
					}
				}

			} catch {

			}
		}
		return success
	}
	
	public func sendWaypoint(destNum: Int64, name: String, wantAck: Bool) -> Bool {
		
		var success = false
		let fromNodeNum = connectedPeripheral.num
		if fromNodeNum <= 0 || (LocationHelper.currentLocation.latitude == LocationHelper.DefaultLocation.latitude && LocationHelper.currentLocation.longitude == LocationHelper.DefaultLocation.longitude) {
			return false
		}
		var waypointPacket = Waypoint()
		waypointPacket.latitudeI = Int32(LocationHelper.currentLocation.latitude * 1e7)
		waypointPacket.longitudeI = Int32(LocationHelper.currentLocation.longitude * 1e7)
		let oneWeekFromNow = Calendar.current.date(byAdding: .day, value: 7, to: Date())
		waypointPacket.expire = UInt32(oneWeekFromNow!.timeIntervalSince1970)
		waypointPacket.name = name
		var meshPacket = MeshPacket()
		meshPacket.to = UInt32(destNum)
		meshPacket.from	= 0 // Send 0 as from from phone to device to avoid warning about client trying to set node num
		meshPacket.wantAck = true//wantAck
		var dataMessage = DataMessage()
		dataMessage.payload = try! waypointPacket.serializedData()
		dataMessage.portnum = PortNum.waypointApp
		meshPacket.decoded = dataMessage
		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		let binaryData: Data = try! toRadio.serializedData()
		
		MeshLogger.log("📍 Sent a Waypoint Packet from the Apple device GPS to node: \(fromNodeNum)")
		
		if connectedPeripheral!.peripheral.state == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			success = true
		}
		return success
	}
	
	public func sendPosition(destNum: Int64,  wantResponse: Bool) -> Bool {
		
		var success = false
		let fromNodeNum = connectedPeripheral.num
		if fromNodeNum <= 0 || (LocationHelper.currentLocation.latitude == LocationHelper.DefaultLocation.latitude && LocationHelper.currentLocation.longitude == LocationHelper.DefaultLocation.longitude) {
			return false
		}
		var positionPacket = Position()
		positionPacket.latitudeI = Int32(LocationHelper.currentLocation.latitude * 1e7)
		positionPacket.longitudeI = Int32(LocationHelper.currentLocation.longitude * 1e7)
		positionPacket.time = UInt32(LocationHelper.currentTimestamp.timeIntervalSince1970)
		positionPacket.timestamp = UInt32(LocationHelper.currentTimestamp.timeIntervalSince1970)
		positionPacket.altitude = Int32(LocationHelper.currentAltitude)
		positionPacket.satsInView = UInt32(LocationHelper.satsInView)
		// Get Errors without some speed
		if LocationHelper.currentSpeed >= 5 {
			
			positionPacket.groundSpeed = UInt32(LocationHelper.currentSpeed)
			positionPacket.groundTrack = UInt32(LocationHelper.currentHeading)
		}
		var meshPacket = MeshPacket()
		meshPacket.to = UInt32(destNum)
		meshPacket.from	= 0 // Send 0 as from from phone to device to avoid warning about client trying to set node num
	
		var dataMessage = DataMessage()
		dataMessage.payload = try! positionPacket.serializedData()
		dataMessage.portnum = PortNum.positionApp
		//if destNum != emptyNodeNum {
			dataMessage.wantResponse = wantResponse
		//}
		meshPacket.decoded = dataMessage

		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket
		let binaryData: Data = try! toRadio.serializedData()
		
		if connectedPeripheral!.peripheral.state == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			success = true
			MeshLogger.log("📍 Sent a Position Packet from the Apple device GPS to node: \(fromNodeNum)")
		}
		return success
	}
	
	@objc func positionTimerFired(timer: Timer) {
		
		// Check for connected node
		if connectedPeripheral != nil {

			// Send a position out to the mesh if "share location with the mesh" is enabled in settings
			if userSettings!.provideLocation {
				
				let success = sendPosition(destNum: connectedPeripheral.num, wantResponse: false)
				if !success {
					
					print("Failed to send positon to device")
					
				}
			}
		}
	}
	
	public func sendShutdown(destNum: Int64) -> Bool {
		
		var adminPacket = AdminMessage()
		adminPacket.shutdownSeconds = 10
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedPeripheral.num)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage

		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket

		let binaryData: Data = try! toRadio.serializedData()
		
		if connectedPeripheral!.peripheral.state == CBPeripheralState.connected {
			
			do {
				try context!.save()
				MeshLogger.log("💾 Saved a Shutdown Admin Message for node: \(String(destNum))")
				connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
				return true

			} catch {
				context!.rollback()
				let nsError = error as NSError
				MeshLogger.log("💥 Error Inserting New Core Data MessageEntity: \(nsError)")
			}
		}
		return false
	}
	
	public func sendReboot(destNum: Int64) -> Bool {
		
		var adminPacket = AdminMessage()
		adminPacket.rebootSeconds = 10
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedPeripheral.num)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.hopLimit = 0
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage

		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket

		let binaryData: Data = try! toRadio.serializedData()
		
		if connectedPeripheral!.peripheral.state == CBPeripheralState.connected {
			
			do {
				try context!.save()
				connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
				MeshLogger.log("💾 Saved a Reboot Admin Message for node: \(String(destNum))")
				return true
			} catch {
				context!.rollback()
				let nsError = error as NSError
				MeshLogger.log("💥 Error Inserting New Core Data MessageEntity: \(nsError)")
			}
		}
		return false
	}
	
	public func sendFactoryReset(destNum: Int64) -> Bool {
		
		var adminPacket = AdminMessage()
		adminPacket.factoryReset = 1
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(destNum)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		
		meshPacket.decoded = dataMessage

		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket

		let binaryData: Data = try! toRadio.serializedData()
		
		if connectedPeripheral!.peripheral.state == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			MeshLogger.log("💾 Sent a Factory Reset for node: \(String(destNum))")
			return true
		}
		return false
	}
	
	public func sendNodeDBReset(destNum: Int64) -> Bool {
		
		var adminPacket = AdminMessage()
		adminPacket.nodedbReset = 1
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(destNum)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		
		meshPacket.decoded = dataMessage

		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket

		let binaryData: Data = try! toRadio.serializedData()
		
		if connectedPeripheral!.peripheral.state == CBPeripheralState.connected {
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			MeshLogger.log("💾 Sent a NodeDB Reset for node: \(String(destNum))")
			return true
		}
		return false
	}
	
	public func connectToPreferredPeripheral() -> Bool {
		
		var success = false
		// Return false if we are not properly connected to a device, handle retry logic in the view for now
		if connectedPeripheral == nil || connectedPeripheral!.peripheral.state != CBPeripheralState.connected {
			
			self.disconnectPeripheral()
			self.startScanning()
			
			// Try and connect to the preferredPeripherial first
			let preferredPeripheral = peripherals.filter({ $0.peripheral.identifier.uuidString == UserDefaults.standard.object(forKey: "preferredPeripheralId") as? String ?? "" }).first
			if preferredPeripheral != nil && preferredPeripheral?.peripheral != nil {
				connectTo(peripheral: preferredPeripheral!.peripheral)
				success = true
			}
		} else if connectedPeripheral != nil && isSubscribed {
			success = true
		}
		return success
	}
	
	public func saveChannel(channel: Channel, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setChannel = channel
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= 0 //UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		
		meshPacket.decoded = dataMessage

		let messageDescription = "Saved Channel \(channel.index) for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func saveChannelSet(base64UrlString: String) -> Bool {
				
		if isConnected {
			
			//Before we get started delete the existing channels from the myNodeInfo
			let fetchMyInfoRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest.init(entityName: "MyInfoEntity")
			fetchMyInfoRequest.predicate = NSPredicate(format: "myNodeNum == %lld", Int64(connectedPeripheral.num))

			do {
				let fetchedMyInfo = try context!.fetch(fetchMyInfoRequest) as! [MyInfoEntity]
				if fetchedMyInfo.count == 1 {
					
					let mutableChannels = fetchedMyInfo[0].channels!.mutableCopy() as! NSMutableOrderedSet
					mutableChannels.removeAllObjects()
					fetchedMyInfo[0].channels = mutableChannels
					do {
						try context!.save()
					} catch {
						print("Failed to clear existing channels from local app database")
					}
				}
			} catch {
				print("Failed to find a node MyInfo to save these channels to")
			}
			
			let decodedString = base64UrlString.base64urlToBase64()
			if let decodedData = Data(base64Encoded: decodedString) {
				do {
					let channelSet: ChannelSet = try ChannelSet(serializedData: decodedData)
					var i:Int32 = 0
					for cs in channelSet.settings {
						var chan = Channel()
						if i == 0 {
							chan.role = Channel.Role.primary
						} else  {
							chan.role = Channel.Role.secondary
						}
						chan.settings = cs
						chan.index = i
						i += 1
						var adminPacket = AdminMessage()
						adminPacket.setChannel = chan
						var meshPacket: MeshPacket = MeshPacket()
						meshPacket.to = UInt32(connectedPeripheral.num)
						meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
						meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
						meshPacket.priority =  MeshPacket.Priority.reliable
						meshPacket.wantAck = true
						meshPacket.channel = 0
						var dataMessage = DataMessage()
						dataMessage.payload = try! adminPacket.serializedData()
						dataMessage.portnum = PortNum.adminApp
						meshPacket.decoded = dataMessage
						var toRadio: ToRadio!
						toRadio = ToRadio()
						toRadio.packet = meshPacket
						let binaryData: Data = try! toRadio.serializedData()
						if connectedPeripheral!.peripheral.state == CBPeripheralState.connected {
							self.connectedPeripheral.peripheral.writeValue(binaryData, for: self.TORADIO_characteristic, type: .withResponse)
							MeshLogger.log("✈️ Sent a Channel for: \(String(self.connectedPeripheral.num)) Channel Index \(chan.index)")
						}
					}
					// Save the LoRa Config and the device will reboot
					var adminPacket = AdminMessage()
					adminPacket.setConfig.lora = channelSet.loraConfig
					var meshPacket: MeshPacket = MeshPacket()
					meshPacket.to = UInt32(connectedPeripheral.num)
					meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
					meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
					meshPacket.priority =  MeshPacket.Priority.reliable
					meshPacket.wantAck = true
					meshPacket.channel = 0
					var dataMessage = DataMessage()
					dataMessage.payload = try! adminPacket.serializedData()
					dataMessage.portnum = PortNum.adminApp
					meshPacket.decoded = dataMessage
					var toRadio: ToRadio!
					toRadio = ToRadio()
					toRadio.packet = meshPacket
					let binaryData: Data = try! toRadio.serializedData()
					if connectedPeripheral!.peripheral.state == CBPeripheralState.connected {
						self.connectedPeripheral.peripheral.writeValue(binaryData, for: self.TORADIO_characteristic, type: .withResponse)
							MeshLogger.log("✈️ Sent a LoRaConfig for: \(String(self.connectedPeripheral.num))")
					}
					return true
						
				} catch {
					return false
				}
			}
		}
		return false
	}
	
	public func saveUser(config: User, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		
		var adminPacket = AdminMessage()
		adminPacket.setOwner = config
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedPeripheral.num)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.hopLimit = 0
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		let messageDescription = "Saved User Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func saveBluetoothConfig(config: Config.BluetoothConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		
		var adminPacket = AdminMessage()
		adminPacket.setConfig.bluetooth = config
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedPeripheral.num)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		let messageDescription = "Saved Bluetooth Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func saveDeviceConfig(config: Config.DeviceConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		
		var adminPacket = AdminMessage()
		adminPacket.setConfig.device = config
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedPeripheral.num)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		
		let messageDescription = "Saved Device Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func saveDisplayConfig(config: Config.DisplayConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		
		var adminPacket = AdminMessage()
		adminPacket.setConfig.display = config
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedPeripheral.num)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.hopLimit = 0
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		let messageDescription = "Saved Display Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func saveLoRaConfig(config: Config.LoRaConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setConfig.lora = config
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedPeripheral.num)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.hopLimit = 0
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		meshPacket.decoded = dataMessage
		let messageDescription = "Saved LoRa Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func savePositionConfig(config: Config.PositionConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		
		var adminPacket = AdminMessage()
		adminPacket.setConfig.position = config
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedPeripheral.num)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.hopLimit = 0
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		
		meshPacket.decoded = dataMessage
		
		let messageDescription = "Saved Position Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func saveWiFiConfig(config: Config.NetworkConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		
		var adminPacket = AdminMessage()
		adminPacket.setConfig.network = config
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedPeripheral.num)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.hopLimit = 0
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		
		meshPacket.decoded = dataMessage
		
		let messageDescription = "Saved WiFi Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func saveCannedMessageModuleConfig(config: ModuleConfig.CannedMessageConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.cannedMessage = config
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= 0 //UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		
		meshPacket.decoded = dataMessage
		
		let messageDescription = "Saved Canned Message Module Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func saveCannedMessageModuleMessages(messages: String, fromUser: UserEntity, toUser: UserEntity, wantResponse: Bool) -> Int64 {
		
		var adminPacket = AdminMessage()
		adminPacket.setCannedMessageModuleMessages = messages
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= 0 //UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = wantResponse
		
		meshPacket.decoded = dataMessage
		
		let messageDescription = "💾 Saved Canned Message Module Messages for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func getChannel(channelIndex: UInt32, fromUser: UserEntity, toUser: UserEntity, wantResponse: Bool) -> Bool {
		
		var adminPacket = AdminMessage()
		adminPacket.getChannelRequest = channelIndex
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= 0 //UInt32(cnodeNum)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = wantResponse
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = true
		
		meshPacket.decoded = dataMessage
		
		let messageDescription = "🛎️ Sent a Get Channel \(channelIndex) Request Admin Message for node: \(String(connectedPeripheral.num))"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			
			return true
		}
		
		return false
	}
	
	public func getCannedMessageModuleMessages(destNum: Int64,  wantResponse: Bool) -> Bool {
		
		var adminPacket = AdminMessage()
		adminPacket.getCannedMessageModuleMessagesRequest = true
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedPeripheral.num)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.decoded.wantResponse = wantResponse
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		dataMessage.wantResponse = wantResponse
		
		meshPacket.decoded = dataMessage

		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket

		let binaryData: Data = try! toRadio.serializedData()
		
		if connectedPeripheral!.peripheral.state == CBPeripheralState.connected {
			MeshLogger.log("✈️ Sent a Canned Messages Module Get Messages Request Admin Message for node: \(String(destNum))")
			connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
			return true
		}
		
		return false
	}
	
	public func saveExternalNotificationModuleConfig(config: ModuleConfig.ExternalNotificationConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {

		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.externalNotification = config
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= 0 //UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		
		meshPacket.decoded = dataMessage

		let messageDescription = "Saved External Notification Module Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func saveMQTTConfig(config: ModuleConfig.MQTTConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		
		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.mqtt = config
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedPeripheral.num)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.hopLimit = 0
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		
		meshPacket.decoded = dataMessage
		
		let messageDescription = "Saved WiFi Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func saveRangeTestModuleConfig(config: ModuleConfig.RangeTestConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		
		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.rangeTest = config
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= 0 //UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		
		meshPacket.decoded = dataMessage

		let messageDescription = "Saved Range Test Module Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func saveSerialModuleConfig(config: ModuleConfig.SerialConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
		
		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.serial = config
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(connectedPeripheral.num)
		meshPacket.from	= 0 //UInt32(connectedPeripheral.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		meshPacket.hopLimit = 0
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		
		meshPacket.decoded = dataMessage

		let messageDescription = "Saved Serial Module Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	public func saveTelemetryModuleConfig(config: ModuleConfig.TelemetryConfig, fromUser: UserEntity, toUser: UserEntity) -> Int64 {
				
		var adminPacket = AdminMessage()
		adminPacket.setModuleConfig.telemetry = config
		
		var meshPacket: MeshPacket = MeshPacket()
		meshPacket.to = UInt32(toUser.num)
		meshPacket.from	= 0 //UInt32(fromUser.num)
		meshPacket.id = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
		meshPacket.priority =  MeshPacket.Priority.reliable
		meshPacket.wantAck = true
		
		var dataMessage = DataMessage()
		dataMessage.payload = try! adminPacket.serializedData()
		dataMessage.portnum = PortNum.adminApp
		
		meshPacket.decoded = dataMessage

		let messageDescription = "Saved Telemetry Module Config for \(toUser.longName ?? "Unknown")"
		
		if sendAdminMessageToRadio(meshPacket: meshPacket, adminDescription: messageDescription, fromUser: fromUser, toUser: toUser) {
			
			return Int64(meshPacket.id)
		}
		
		return 0
	}
	
	// Send an admin message to a radio, save a message to core data for logging
	private func sendAdminMessageToRadio(meshPacket: MeshPacket, adminDescription: String, fromUser: UserEntity, toUser: UserEntity) -> Bool {
		
		var toRadio: ToRadio!
		toRadio = ToRadio()
		toRadio.packet = meshPacket

		let binaryData: Data = try! toRadio.serializedData()
		
		if connectedPeripheral!.peripheral.state == CBPeripheralState.connected {
						
			let newMessage = MessageEntity(context: context!)
			newMessage.messageId =  Int64(meshPacket.id)
			newMessage.messageTimestamp =  Int32(Date().timeIntervalSince1970)
			newMessage.receivedACK = false
			newMessage.admin = true
			newMessage.adminDescription = adminDescription
			newMessage.fromUser = fromUser
			newMessage.toUser = toUser
			
			do {

				connectedPeripheral.peripheral.writeValue(binaryData, for: TORADIO_characteristic, type: .withResponse)
				try context!.save()
				MeshLogger.log("💾 \(adminDescription)")
				
				return true

			} catch {

				context!.rollback()

				let nsError = error as NSError
				MeshLogger.log("💥 Error inserting new core data MessageEntity: \(nsError)")
			}
		}
		return false
	}
}

// MARK: - CB Central Manager implmentation
extension BLEManager: CBCentralManagerDelegate {
	
	// MARK: Bluetooth enabled/disabled
	func centralManagerDidUpdateState(_ central: CBCentralManager) {
		if central.state == CBManagerState.poweredOn {
			print("BLE powered on")
			isSwitchedOn = true
			startScanning()
		}
		else {
			isSwitchedOn = false
		}
		
		var status = ""

		switch central.state {
			case .poweredOff:
				status = "BLE is powered off"
			case .poweredOn:
				status = "BLE is poweredOn"
			case .resetting:
				status = "BLE is resetting"
			case .unauthorized:
				status = "BLE is unauthorized"
			case .unknown:
				status = "BLE is unknown"
			case .unsupported:
				status = "BLE is unsupported"
			default:
				status = "default"
		}
		print("BLEManager status: \(status)")
	}
	
	// Called each time a peripheral is discovered
	func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
		
		if timeoutTimerRuns < 2 && peripheral.identifier.uuidString == UserDefaults.standard.object(forKey: "preferredPeripheralId") as? String ?? "" {
			self.connectTo(peripheral: peripheral)
			MeshLogger.log("ℹ️ BLE Reconnecting to prefered peripheral: \(peripheral.name ?? "Unknown")")
		}
		let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
		let device = Peripheral(id: peripheral.identifier.uuidString, num: 0, name: name ?? "Unknown", shortName: "????", longName: name ?? "Unknown", firmwareVersion: "Unknown", rssi: RSSI.intValue, lastUpdate: Date(), peripheral: peripheral)
		let index = peripherals.map { $0.peripheral }.firstIndex(of: peripheral)
		
		if let peripheralIndex = index {
			peripherals[peripheralIndex] = device
		} else {
			peripherals.append(device)
		}
		let today = Date()
		let visibleDuration = Calendar.current.date(byAdding: .second, value: -5, to: today)!
		self.peripherals.removeAll(where: { $0.lastUpdate < visibleDuration})
	}
}
