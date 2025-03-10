//
//  NetworkEnums.swift
//  Meshtastic
//
//  Copyright(C) Garth Vander Houwen 11/25/22.
//

import Foundation

enum EthernetMode: Int, CaseIterable, Identifiable {

	case dhcp = 0
	case staticip = 1

	var id: Int { self.rawValue }
	var description: String {
		get {
			switch self {
			
			case .dhcp:
				return "DHCP"
			case .staticip:
				return "Static IP"
			}
		}
	}
	func protoEnumValue() -> Config.NetworkConfig.EthMode {
		
		switch self {
			
		case .dhcp:
			return Config.NetworkConfig.EthMode.dhcp
		case .staticip:
			return Config.NetworkConfig.EthMode.static
		}
	}
}
