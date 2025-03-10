//
//  Contacts.swift
//  MeshtasticApple
//
//  Created by Garth Vander Houwen on 12/21/21.
//

import SwiftUI
import CoreData

struct Contacts: View {

	@Environment(\.managedObjectContext) var context
	@EnvironmentObject var bleManager: BLEManager
	@ObservedObject private var userSettings: UserSettings = UserSettings()
	
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(key: "longName", ascending: true)],
		animation: .default)
	
	private var users: FetchedResults<UserEntity>
	@State var node: NodeInfoEntity? = nil
	@State private var selection: UserEntity? = nil // Nothing selected by default.
	@State private var isPresentingDeleteChannelMessagesConfirm: Bool = false
	@State private var isPresentingDeleteUserMessagesConfirm: Bool = false
	@State private var isPresentingTraceRouteSentAlert = false

    var body: some View {

		NavigationSplitView {
			List {
				Section(header: Text("channels")) {
					// Display Contacts for the rest of the non admin channels
					if node != nil && node!.myInfo != nil && node!.myInfo!.channels != nil {
						ForEach(node!.myInfo!.channels!.array as! [ChannelEntity], id: \.self) { (channel: ChannelEntity) in
							if channel.name?.lowercased() ?? "" != "admin" && channel.name?.lowercased() ?? "" != "gpio" && channel.name?.lowercased() ?? "" != "serial" {
								NavigationLink(destination: ChannelMessageList(channel: channel)) {
						
									let mostRecent = channel.allPrivateMessages.last(where: { $0.channel == channel.index })
									let lastMessageTime = Date(timeIntervalSince1970: TimeInterval(Int64((mostRecent?.messageTimestamp ?? 0 ))))
									let lastMessageDay = Calendar.current.dateComponents([.day], from: lastMessageTime).day ?? 0
									let currentDay = Calendar.current.dateComponents([.day], from: Date()).day ?? 0
									VStack(alignment: .leading) {
										HStack {
											CircleText(text: String(channel.index), color: .accentColor, circleSize: 52, fontSize: 40, brightness: 0.1)
												.padding(.trailing, 5)
											VStack {
												HStack {
													if channel.name?.isEmpty ?? false {
														if channel.role == 1 {
															Text(String("PrimaryChannel").camelCaseToWords()).font(.headline)
														} else {
															Text(String("Channel \(channel.index)").camelCaseToWords()).font(.headline)
														}
													} else {
														Text(String(channel.name ?? "Channel \(channel.index)").camelCaseToWords()).font(.headline)
													}
													Spacer()
													if channel.allPrivateMessages.count > 0 {
														VStack (alignment: .trailing) {
															if lastMessageDay == currentDay {
																Text(lastMessageTime, style: .time )
																	.font(.subheadline)
															} else if  lastMessageDay == (currentDay - 1) {
																Text("Yesterday")
																	.font(.subheadline)
															} else if  lastMessageDay < (currentDay - 1) && lastMessageDay > (currentDay - 5) {
																Text(lastMessageTime.formattedDate(format: "MM/dd/yy"))
																	.font(.subheadline)
															} else if lastMessageDay < (currentDay - 1800) {
																Text(lastMessageTime.formattedDate(format: "MM/dd/yy"))
																	.font(.subheadline)
															}
														}
														.brightness(-0.20)
													}
												}
												if channel.allPrivateMessages.count > 0 {
													HStack(alignment: .top) {
														Text("\(mostRecent != nil ? mostRecent!.messagePayload! : " ")")
															.truncationMode(.tail)
															.frame(maxWidth: .infinity, alignment: .leading)
															.brightness(-0.20)
															.font(.body)
													}
												}
											}
											.frame(maxWidth: .infinity, alignment: .leading)
										}
									}
								}
								.frame(maxWidth: .infinity, maxHeight: 80, alignment: .leading)
								.contextMenu {
									Button {
										channel.mute = !channel.mute

										do {
											try context.save()
											// Would rather not do this but the merge changes on
											// A single object is only working on mac GVH
											context.refreshAllObjects()
											//context.refresh(channel, mergeChanges: true)
										} catch {
											context.rollback()
											print("💥 Save Channel Mute Error")
										}
									} label: {
										Label(channel.mute ? "Show Alerts" : "Hide Alerts", systemImage: channel.mute ? "bell" : "bell.slash")
									}

									if channel.allPrivateMessages.count > 0 {
										Button(role: .destructive) {
											isPresentingDeleteChannelMessagesConfirm = true
										} label: {
											Label("Delete Messages", systemImage: "trash")
										}
									}
								}
								.confirmationDialog(
									"This conversation will be deleted.",
									isPresented: $isPresentingDeleteChannelMessagesConfirm,
									
									titleVisibility: .visible
								) {
									
									Button(role: .destructive) {
										deleteChannelMessages(channel: channel, context: context)
										context.refresh(node!.myInfo!, mergeChanges: true)
									} label: {
										Text("delete")
									}
								}
							}
						}
						.padding([.top, .bottom])
						
					}
				}
				Section(header: Text("direct.messages")) {
					ForEach(users) { (user: UserEntity) in
						if  user.num != bleManager.userSettings?.preferredNodeNum ?? 0 {
							NavigationLink(destination: UserMessageList(user: user)) {
								let mostRecent = user.messageList.last
								let lastMessageTime = Date(timeIntervalSince1970: TimeInterval(Int64((mostRecent?.messageTimestamp ?? 0 ))))
								let lastMessageDay = Calendar.current.dateComponents([.day], from: lastMessageTime).day ?? 0
								let currentDay = Calendar.current.dateComponents([.day], from: Date()).day ?? 0
								HStack {
									VStack {
										HStack {
											CircleText(text: user.shortName ?? "???", color: .accentColor, circleSize: 52, fontSize: 16, brightness: 0.1)
												.padding(.trailing, 5)
											VStack {
												HStack {
													Text(user.longName ?? "Unknown").font(.headline)
													Spacer()
													if user.messageList.count > 0 {
														VStack (alignment: .trailing) {
															if lastMessageDay == currentDay {
																Text(lastMessageTime, style: .time )
																	.font(.subheadline)
															} else if  lastMessageDay == (currentDay - 1) {
																Text("Yesterday")
																	.font(.subheadline)
															} else if  lastMessageDay < (currentDay - 1) && lastMessageDay > (currentDay - 5) {
																Text(lastMessageTime.formattedDate(format: "MM/dd/yy"))
																	.font(.subheadline)
															} else if lastMessageDay < (currentDay - 1800) {
																Text(lastMessageTime.formattedDate(format: "MM/dd/yy"))
																	.font(.subheadline)
															}
														}
														.brightness(-0.2)
													}
												}
												if user.messageList.count > 0 {
													HStack(alignment: .top) {
														Text("\(mostRecent != nil ? mostRecent!.messagePayload! : " ")")
															.truncationMode(.tail)
															.font(.body)
															.frame(maxWidth: .infinity, alignment: .leading)
															.brightness(-0.2)
													}
												}
											}
											.frame(maxWidth: .infinity, maxHeight: 80, alignment: .leading)
											.contextMenu {
												Button {
													user.mute = !user.mute
													do {
														try context.save()
													} catch {
														context.rollback()
														print("💥 Save User Mute Error")
													}
												} label: {
													Label(user.mute ? "Show Alerts" : "Hide Alerts", systemImage: user.mute ? "bell" : "bell.slash")
												}
												Button {
													let success = bleManager.sendTraceRouteRequest(destNum: user.num, wantResponse: true)
													if success {
														isPresentingTraceRouteSentAlert = true
													}
												} label: {
													Label("Trace Route", systemImage: "signpost.right.and.left")
												}
												if user.messageList.count  > 0 {
													Button(role: .destructive) {
														isPresentingDeleteUserMessagesConfirm = true
													} label: {
														Label("Delete Messages", systemImage: "trash")
													}
												}
											}
											.alert(
												"Trace Route Sent",
												isPresented: $isPresentingTraceRouteSentAlert
											)
											{
												Button("OK", role: .cancel) { }
											}
											message: {
												Text("This could take a while, response will appear in the mesh log.")
											}
											.confirmationDialog(
												"This conversation will be deleted.",
												isPresented: $isPresentingDeleteUserMessagesConfirm,
												titleVisibility: .visible
											) {
												Button(role: .destructive) {
													deleteUserMessages(user: user, context: context)
													context.refresh(node!.user!, mergeChanges: true)
												} label: {
													Text("delete")
												}
											}
										}
									}
								}
							}
							.padding(.top, 10)
							.padding(.bottom, 10)
						}
					}
				}
			}
			.navigationTitle("contacts")
			.navigationBarItems(leading:
				MeshtasticLogo()
			)
			.onAppear {
				self.bleManager.userSettings = userSettings
				self.bleManager.context = context
				
				if userSettings.preferredNodeNum > 0 {
					
					let fetchNodeInfoRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest.init(entityName: "NodeInfoEntity")
					fetchNodeInfoRequest.predicate = NSPredicate(format: "num == %lld", Int64(userSettings.preferredNodeNum))
					
					do {
						
						let fetchedNode = try context.fetch(fetchNodeInfoRequest) as! [NodeInfoEntity]
						// Found a node, check it for a region
						if !fetchedNode.isEmpty {
							node = fetchedNode[0]
							
						}
					} catch {
						
					}
				}
				
			}
		}
		detail: {
			if let user = selection {
				UserMessageList(user:user)
				
			} else {
				Text("select.contact")
			}
		}
    }
}
