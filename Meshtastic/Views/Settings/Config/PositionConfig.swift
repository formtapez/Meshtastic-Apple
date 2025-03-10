//
//  PositionConfig.swift
//  Meshtastic Apple
//
//  Copyright (c) Garth Vander Houwen 6/11/22.
//

import SwiftUI

struct PositionFlags: OptionSet
{
	let rawValue: Int
	
	static let Altitude = PositionFlags(rawValue: 1)
	static let AltitudeMsl = PositionFlags(rawValue: 2)
	static let GeoidalSeparation = PositionFlags(rawValue: 4)
	static let Dop = PositionFlags(rawValue: 8)
	static let Hvdop = PositionFlags(rawValue: 16)
	static let Satsinview = PositionFlags(rawValue: 32)
	static let SeqNo = PositionFlags(rawValue: 64)
	static let Timestamp = PositionFlags(rawValue: 128)
	static let Speed = PositionFlags(rawValue: 256)
	static let Heading = PositionFlags(rawValue: 512)
}

struct PositionConfig: View {
	
	@Environment(\.managedObjectContext) var context
	@EnvironmentObject var bleManager: BLEManager
	@Environment(\.dismiss) private var goBack
	
	var node: NodeInfoEntity?
	
	@State private var isPresentingSaveConfirm: Bool = false
	@State var hasChanges = false
	@State var hasFlagChanges = false
	
	@State var smartPositionEnabled = true
	@State var deviceGpsEnabled = true
	@State var fixedPosition = false
	@State var gpsUpdateInterval = 0
	@State var gpsAttemptTime = 0
	@State var positionBroadcastSeconds = 0
	@State var positionFlags = 3
	
	/// Position Flags
	/// Altitude value - 1
	@State var includeAltitude = false
	/// Altitude value is MSL - 2
	@State var includeAltitudeMsl = false
	/// Include geoidal separation - 4
	@State var includeGeoidalSeparation = false
	/// Include the DOP value ; PDOP used by default, see below - 8
	@State var includeDop = false
	/// If POS_DOP set, send separate HDOP / VDOP values instead of PDOP - 16
	@State var includeHvdop = false
	/// Include number of "satellites in view" - 32
	@State var includeSatsinview = false
	/// Include a sequence number incremented per packet - 64
	@State var includeSeqNo = false
	/// Include positional timestamp (from GPS solution) - 128
	@State var includeTimestamp = false
	/// Include positional heading - 256
	/// Intended for use with vehicle not walking speeds
	/// walking speeds are likely to be error prone like the compass
	@State var includeSpeed = false
	/// Include positional speed - 512
	/// Intended for use with vehicle not walking speeds
	/// walking speeds are likely to be error prone like the compass
	@State var includeHeading = false
	
	var body: some View {
		
		VStack {
			Form {
				Section(header: Text("Device GPS")) {
					Toggle(isOn: $deviceGpsEnabled) {
						Label("Device GPS Enabled", systemImage: "location")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					if deviceGpsEnabled {
						Picker("Update Interval", selection: $gpsUpdateInterval) {
							ForEach(GpsUpdateIntervals.allCases) { ui in
								Text(ui.description)
							}
						}
						Text("How often should we try to get a GPS position.")
							.font(.caption)
						Picker("Attempt Time", selection: $gpsAttemptTime) {
							ForEach(GpsAttemptTimes.allCases) { at in
								Text(at.description)
							}
						}
						.pickerStyle(DefaultPickerStyle())
						Text("How long should we try to get our position during each GPS Update Interval attempt?")
							.font(.caption)
					} else {
						Toggle(isOn: $fixedPosition) {
							Label("Fixed Position", systemImage: "location.square.fill")
						}
						.toggleStyle(SwitchToggleStyle(tint: .accentColor))
						Text("If enabled your current location will be set as a fixed position.")
							.font(.caption)
					}
				}
				
				Section(header: Text("Position Packet")) {
					
					Toggle(isOn: $smartPositionEnabled) {

						Label("Smart Position Broadcast", systemImage: "location.fill.viewfinder")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
						
					Picker("Position Broadcast Interval", selection: $positionBroadcastSeconds) {
						ForEach(PositionBroadcastIntervals.allCases) { at in
							Text(at.description)
						}
					}
					.pickerStyle(DefaultPickerStyle())
					
					Text("We should send our position this often (but only if it has changed significantly)")
						.font(.caption)
				}
				Section(header: Text("Position Flags")) {
					
					Text("Optional fields to include when assembling position messages. the more fields are included, the larger the message will be - leading to longer airtime and a higher risk of packet loss")
						.font(.caption)
						.listRowSeparator(.visible)
					
					Toggle(isOn: $includeAltitude) {
						Label("Altitude", systemImage: "arrow.up")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					
					if includeAltitude {
						Toggle(isOn: $includeAltitudeMsl) {
							Label("Altitude is Mean Sea Level", systemImage: "arrow.up.to.line.compact")
						}
						.toggleStyle(SwitchToggleStyle(tint: .accentColor))
						Toggle(isOn: $includeGeoidalSeparation) {
							Label("Altitude Geoidal Separation", systemImage: "globe.americas")
						}
						.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					}
					
					Toggle(isOn: $includeSatsinview) {
						Label("Number of satellites", systemImage: "skew")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					
					Toggle(isOn: $includeSeqNo) { //64
						Label("Sequence number", systemImage: "number")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					
					Toggle(isOn: $includeTimestamp) { //128
						Label("Timestamp", systemImage: "clock")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					
					Toggle(isOn: $includeHeading) { //128
						Label("Vehicle heading", systemImage: "location.circle")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					
					Toggle(isOn: $includeSpeed) { //128

						Label("Vehicle speed", systemImage: "speedometer")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
				}
				Section(header: Text("Advanced Position Flags")) {
					
					Toggle(isOn: $includeDop) {
						Text("Dilution of precision (DOP) PDOP used by default")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					
					if includeDop {
						Toggle(isOn: $includeHvdop) {
							Text("If DOP is set use, HDOP / VDOP values instead of PDOP")
						}
						.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					}
				}
			}
			.disabled(bleManager.connectedPeripheral == nil)
			
			Button {
							
				isPresentingSaveConfirm = true
				
			} label: {
				
				Label("save", systemImage: "square.and.arrow.down")
			}
			.disabled(bleManager.connectedPeripheral == nil || !hasChanges)
			.buttonStyle(.bordered)
			.buttonBorderShape(.capsule)
			.controlSize(.large)
			.padding()
			.confirmationDialog(
				"are.you.sure",
				isPresented: $isPresentingSaveConfirm,
				titleVisibility: .visible
			) {
				Button("Save Position Config to \(bleManager.connectedPeripheral != nil ? bleManager.connectedPeripheral.longName : "Unknown")?") {
					
					if fixedPosition {
						_ = bleManager.sendPosition(destNum: bleManager.connectedPeripheral.num, wantResponse: false)
					}
					
					var pc = Config.PositionConfig()
					pc.positionBroadcastSmartEnabled = smartPositionEnabled
					pc.gpsEnabled = deviceGpsEnabled
					pc.fixedPosition = fixedPosition
					pc.gpsUpdateInterval = UInt32(gpsUpdateInterval)
					pc.gpsAttemptTime = UInt32(gpsAttemptTime)
					pc.positionBroadcastSecs = UInt32(positionBroadcastSeconds)
					var pf : PositionFlags = []
					if includeAltitude { pf.insert(.Altitude) }
					if includeAltitudeMsl { pf.insert(.AltitudeMsl) }
					if includeGeoidalSeparation { pf.insert(.GeoidalSeparation) }
					if includeDop { pf.insert(.Dop) }
					if includeHvdop { pf.insert(.Hvdop) }
					if includeSatsinview { pf.insert(.Satsinview) }
					if includeSeqNo { pf.insert(.SeqNo) }
					if includeTimestamp { pf.insert(.Timestamp) }
					if includeSpeed { pf.insert(.Speed) }
					if includeHeading { pf.insert(.Heading) }
					pc.positionFlags = UInt32(pf.rawValue)
					let adminMessageId =  bleManager.savePositionConfig(config: pc, fromUser: node!.user!, toUser: node!.user!)
					if adminMessageId > 0 {
						// Should show a saved successfully alert once I know that to be true
						// for now just disable the button after a successful save
						hasChanges = false
						goBack()
					}
				}
			}
		}
		.navigationTitle("position.config")
		.navigationBarItems(trailing:

			ZStack {

			ConnectedDevice(bluetoothOn: bleManager.isSwitchedOn, deviceConnected: bleManager.connectedPeripheral != nil, name: (bleManager.connectedPeripheral != nil) ? bleManager.connectedPeripheral.shortName : "????")
		})
		.onAppear {
				
			self.bleManager.context = context
			self.smartPositionEnabled = node?.positionConfig?.smartPositionEnabled ?? true
			self.deviceGpsEnabled = node?.positionConfig?.deviceGpsEnabled ?? true
			self.fixedPosition = node?.positionConfig?.fixedPosition ?? false
			self.gpsUpdateInterval = Int(node?.positionConfig?.gpsUpdateInterval ?? 30)
			self.gpsAttemptTime = Int(node?.positionConfig?.gpsAttemptTime ?? 30)
			self.positionBroadcastSeconds = Int(node?.positionConfig?.positionBroadcastSeconds ?? 900)
			self.positionFlags = Int(node?.positionConfig?.positionFlags ?? 3)
			
			let pf = PositionFlags(rawValue: self.positionFlags)
			
			if pf.contains(.Altitude) { self.includeAltitude = true } else { self.includeAltitude = false }
			if pf.contains(.AltitudeMsl) { self.includeAltitudeMsl = true } else { self.includeAltitudeMsl = false }
			if pf.contains(.GeoidalSeparation) { self.includeGeoidalSeparation = true } else { self.includeGeoidalSeparation = false }
			if pf.contains(.Dop) { self.includeDop = true  } else { self.includeDop = false }
			if pf.contains(.Hvdop) { self.includeHvdop = true } else { self.includeHvdop = false }
			if pf.contains(.Satsinview) { self.includeSatsinview = true } else { self.includeSatsinview = false }
			if pf.contains(.SeqNo) { self.includeSeqNo = true } else { self.includeSeqNo = false }
			if pf.contains(.Timestamp) { self.includeTimestamp = true } else { self.includeTimestamp = false }
			if pf.contains(.Speed) { self.includeSpeed = true } else { self.includeSpeed = false }
			if pf.contains(.Heading) { self.includeHeading = true } else { self.includeHeading = false }
			
			self.hasChanges = false
			
		}
		.onChange(of: deviceGpsEnabled) { newDeviceGps in
			if node != nil && node!.positionConfig != nil {
				if newDeviceGps != node!.positionConfig!.deviceGpsEnabled { hasChanges = true }
			}
		}
		.onChange(of: gpsAttemptTime) { newGpsAttemptTime in
			if node != nil && node!.positionConfig != nil {
				if newGpsAttemptTime != node!.positionConfig!.gpsAttemptTime { hasChanges = true }
			}
		}
		.onChange(of: gpsUpdateInterval) { newGpsUpdateInterval in
			if node != nil && node!.positionConfig != nil {
				if newGpsUpdateInterval != node!.positionConfig!.gpsUpdateInterval { hasChanges = true }
			}
		}
		.onChange(of: smartPositionEnabled) { newSmartPositionEnabled in
			if node != nil && node!.positionConfig != nil {
				if newSmartPositionEnabled != node!.positionConfig!.smartPositionEnabled { hasChanges = true }
			}
		}
		.onChange(of: fixedPosition) { newFixed in
			if node != nil && node!.positionConfig != nil {
				if newFixed != node!.positionConfig!.fixedPosition { hasChanges = true }
			}
		}
		.onChange(of: positionBroadcastSeconds) { newPositionBroadcastSeconds in
			if node != nil && node!.positionConfig != nil {
				if newPositionBroadcastSeconds != node!.positionConfig!.positionBroadcastSeconds { hasChanges = true }
			}
		}
		.onChange(of: includeAltitude) { altFlag in
			let pf = PositionFlags(rawValue: self.positionFlags)
			let existingValue = pf.contains(.Altitude)
			if existingValue != altFlag { hasChanges = true }
		}
		.onChange(of: includeAltitudeMsl) { altMslFlag in
			let pf = PositionFlags(rawValue: self.positionFlags)
			let existingValue = pf.contains(.AltitudeMsl)
			if existingValue != altMslFlag { hasChanges = true }
		}
		.onChange(of: includeSatsinview) { satsFlag in
			let pf = PositionFlags(rawValue: self.positionFlags)
			let existingValue = pf.contains(.Satsinview)
			if existingValue != satsFlag { hasChanges = true }
		}
		.onChange(of: includeSeqNo) { seqFlag in
			let pf = PositionFlags(rawValue: self.positionFlags)
			let existingValue = pf.contains(.SeqNo)
			if existingValue != seqFlag { hasChanges = true }
		}
		.onChange(of: includeTimestamp) { timestampFlag in
			let pf = PositionFlags(rawValue: self.positionFlags)
			let existingValue = pf.contains(.Timestamp)
			if existingValue != timestampFlag { hasChanges = true }
		}
		.onChange(of: includeTimestamp) { timestampFlag in
			let pf = PositionFlags(rawValue: self.positionFlags)
			let existingValue = pf.contains(.Timestamp)
			if existingValue != timestampFlag { hasChanges = true }
		}
		.onChange(of: includeSpeed) { speedFlag in
			let pf = PositionFlags(rawValue: self.positionFlags)
			let existingValue = pf.contains(.Speed)
			if existingValue != speedFlag { hasChanges = true }
		}
		.onChange(of: includeHeading) { headingFlag in
			let pf = PositionFlags(rawValue: self.positionFlags)
			let existingValue = pf.contains(.Heading)
			if existingValue != headingFlag { hasChanges = true }
		}
		.onChange(of: includeGeoidalSeparation) { geoSepFlag in
			let pf = PositionFlags(rawValue: self.positionFlags)
			let existingValue = pf.contains(.GeoidalSeparation)
			if existingValue != geoSepFlag { hasChanges = true }
		}
		.onChange(of: includeDop) { dopFlag in
			let pf = PositionFlags(rawValue: self.positionFlags)
			let existingValue = pf.contains(.Dop)
			if existingValue != dopFlag { hasChanges = true }
		}
		.onChange(of: includeHvdop) { hvdopFlag in
			let pf = PositionFlags(rawValue: self.positionFlags)
			let existingValue = pf.contains(.Hvdop)
			if existingValue != hvdopFlag { hasChanges = true }
		}
	}
}
