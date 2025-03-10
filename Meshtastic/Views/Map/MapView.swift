//
//  MapView.swift
//  MeshtasticApple
//
//  Created by Joshua Pirihi on 22/12/21.
//

import Foundation
import UIKit
import MapKit
import SwiftUI
import CoreData
#if false
// wrap a MKMapView into something we can use in SwiftUI
struct MapView: UIViewRepresentable {

	var nodes: FetchedResults<NodeInfoEntity>

	var mapViewDelegate = MapViewDelegate()

	// observe changes to the key in UserDefaults
	@AppStorage("meshMapType") var type: String = "hybrid"

	func makeUIView(context: Context) -> MKMapView {

		let map = MKMapView(frame: .zero)

		map.userTrackingMode = .follow

		let region = MKCoordinateRegion( center: map.centerCoordinate, latitudinalMeters: CLLocationDistance(exactly: 500)!, longitudinalMeters: CLLocationDistance(exactly: 500)!)
		map.setRegion(map.regionThatFits(region), animated: false)
		
		//self.updateMapType(map)
		self.showNodePositions(to: map)
		self.moveToMeshRegion(in: map)

		map.register(PositionAnnotationView.self, forAnnotationViewWithReuseIdentifier: NSStringFromClass(PositionAnnotationView.self))

		let overlay = MKTileOverlay(urlTemplate: //"http://tiles-a.data-cdn.linz.govt.nz/services;key=7fa19132d53240708c4ff436df5b9800/tiles/v4/layer=50767/EPSG:3857/{z}/{x}/{y}.png")
			"http://10.147.253.250:5050/local/map/{z}/{x}/{y}.png")
		overlay.canReplaceMapContent = true
		self.mapViewDelegate.renderer = MKTileOverlayRenderer(tileOverlay: overlay)
		map.addOverlay(overlay)
		
		return map
	}

	func updateUIView(_ view: MKMapView, context: Context) {
		view.delegate = mapViewDelegate                          // (1) This should be set in makeUIView, but it is getting reset to `nil`
		view.translatesAutoresizingMaskIntoConstraints = false   // (2) In the absence of this, we get constraints error on rotation; and again, it seems one should do this in makeUIView, but has to be here

		self.updateMapType(view)

		self.showNodePositions(to: view)
		
		//if (self.needToMoveToMeshRegion) {
		//	self.moveToMeshRegion(in: view)
		//	self.needToMoveToMeshRegion = false
		//}
	}
	
	func moveToMeshRegion(in mapView: MKMapView) {
		//go through the annotations and create a bounding box that encloses them
		
		var minLat: CLLocationDegrees = 90.0
		var maxLat: CLLocationDegrees = -90.0
		var minLon: CLLocationDegrees = 180.0
		var maxLon: CLLocationDegrees = -180.0
		
		for annotation in mapView.annotations {
			if annotation.isKind(of: PositionAnnotation.self) {
				minLat = min(minLat, annotation.coordinate.latitude)
				maxLat = max(maxLat, annotation.coordinate.latitude)
				minLon = min(minLon, annotation.coordinate.longitude)
				maxLon = max(maxLon, annotation.coordinate.longitude)
			}
		}
		
		//check if the mesh region looks sensible before we move to it.  Otherwise we won't move the map (leave it at the current location)
		if maxLat < minLat || (maxLat-minLat) > 5 || maxLon < minLon || (maxLon-minLon) > 5 {
			return
		}
		
		let centerCoord = CLLocationCoordinate2D(latitude: (minLat+maxLat)/2, longitude: (minLon+maxLon)/2)
		
		let span = MKCoordinateSpan(latitudeDelta: (maxLat-minLat)*1.5, longitudeDelta: (maxLon-minLon)*1.5)
		
		let region = mapView.regionThatFits(MKCoordinateRegion(center: centerCoord, span: span))
		
		mapView.setRegion(region, animated: true)
		
		
	}

	func updateMapType(_ map: MKMapView) {

		switch self.type {
		case "satellite":
			map.mapType = .satellite
			break
		case "standard":
			map.mapType = .standard
			break
		case "hybrid":
			map.mapType = .hybrid
			break
		default:
			map.mapType = .hybrid
		}
	}
}

private extension MapView {

	func showNodePositions(to view: MKMapView) {

		// clear any existing annotations
		if !view.annotations.isEmpty {
			view.removeAnnotations(view.annotations)
		}

		for node in self.nodes {
			// try and get the last position
			if (node.positions?.count ?? 0) > 0 && (node.positions!.lastObject as! PositionEntity).coordinate != nil {
				let annotation = PositionAnnotation()
				annotation.coordinate = (node.positions!.lastObject as! PositionEntity).coordinate!
				annotation.title = node.user?.longName ?? "Unknown"
				annotation.shortName = node.user?.shortName?.uppercased() ?? "???"

				view.addAnnotation(annotation)
			}
		}
	}
}

class MapViewDelegate: NSObject, MKMapViewDelegate {

	var renderer: MKTileOverlayRenderer?
	
	func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {

		guard !annotation.isKind(of: MKUserLocation.self) else {
			// Make a fast exit if the annotation is the `MKUserLocation`, as it's not an annotation view we wish to customize.
			return nil
		}

		var annotationView: MKAnnotationView?

		if let annotation = annotation as? PositionAnnotation {
			annotationView = self.setupPositionAnnotationView(for: annotation, on: mapView)
		}

		return annotationView
	}
	
	func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
		return self.renderer!
		
	}

	private func setupPositionAnnotationView(for annotation: PositionAnnotation, on mapView: MKMapView) -> PositionAnnotationView {
		let identifier = NSStringFromClass(PositionAnnotationView.self)

		let annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? PositionAnnotationView ?? PositionAnnotationView()

		annotationView.name = annotation.shortName ?? "???"

		annotationView.canShowCallout = true

		return annotationView
	}
}
#endif
