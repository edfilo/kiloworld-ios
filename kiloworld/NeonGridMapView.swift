//
//  NeonGridMapView.swift
//  kiloworld
//
//  Created by Claude on 9/22/25.
//

import SwiftUI
import MapboxMaps
import Turf
import CoreLocation

// MARK: - Neon Grid MapView
struct NeonGridMapView: UIViewRepresentable {
    @Binding var viewport: Viewport
    let allowViewportUpdate: Bool
    let userPath: [CLLocationCoordinate2D]
    let userLocation: CLLocationCoordinate2D?
    let onCameraChanged: (CameraState) -> Void
    let onMapLoaded: () -> Void
    let metalSynth: MetalWavetableSynth?
    let onSkyTouchCountChanged: (Int) -> Void
    @Binding var coordinator: Coordinator?
    let hologramCoordinator: AnyObject?
    let onUserInteraction: () -> Void // Callback when user interacts with map
    let dynamicTopPadding: Double // Dynamic top padding controlled by slider
    let dynamicBottomPadding: Double // Dynamic bottom padding controlled by slider
    let defaultPitch: Double // Default pitch controlled by slider
    let defaultZoom: Double // Default zoom controlled by slider
    
    func makeUIView(context: Context) -> MapView {
        let mapView = MapView(frame: .zero)
        
        // Load dark style first
        mapView.mapboxMap.loadStyle(.dark) { error in
            if let error = error {
                print("[map] ❌ Failed to load dark style: \(error)")
            } else {
                print("[map] 🌑 Dark style loaded successfully")
                DispatchQueue.main.async {
                    mapView.applyNeonGridStyle()
                }
            }
        }
        
        // Configure gesture options
        mapView.gestures.options.panEnabled = true // Ensure pan is enabled for map movement
        mapView.gestures.options.pinchEnabled = true // Ensure pinch is enabled for zoom
        mapView.gestures.options.doubleTapToZoomInEnabled = false
        mapView.gestures.options.doubleTouchToZoomOutEnabled = false
        mapView.gestures.options.quickZoomEnabled = false
        mapView.gestures.options.pitchEnabled = true // Allow programmatic pitch changes
        
        print("[map] 🎮 Gesture options: pan=\(mapView.gestures.options.panEnabled), pinch=\(mapView.gestures.options.pinchEnabled), pitch=\(mapView.gestures.options.pitchEnabled)")
        
        
        // Configure location with 2D puck (simplified for SDK compatibility)
        let puck2DConfig = Puck2DConfiguration.makeDefault(showBearing: true)
        let locationOptions = LocationOptions(
            puckType: .puck2D(puck2DConfig)
        )
        mapView.location.options = locationOptions
        
        // Explicitly start location updates to make puck visible
        print("[map] 📍 Starting mapView location updates for puck visibility")
        
        // Set up style loaded callback
        context.coordinator.styleObserver = mapView.mapboxMap.onStyleLoaded.observe { [weak mapView] _ in
            print("[map] 🎨 Style loaded callback triggered")
            mapView?.applyNeonGridStyle()
            onMapLoaded()
            
            // Set up SkyGateRecognizer
            DispatchQueue.main.async {
                context.coordinator.setupSkyGateRecognizer(mapView: mapView, metalSynth: metalSynth, onSkyTouchCountChanged: onSkyTouchCountChanged, hologramCoordinator: hologramCoordinator)
            }
            
            // Set up camera observer for debug panel updates and auto-center reset
            context.coordinator.cameraObserver = mapView?.mapboxMap.onCameraChanged.observe { [weak mapView, weak coordinator = context.coordinator] _ in
                guard let mapView = mapView, let coordinator = coordinator else { return }
                let cameraState = mapView.mapboxMap.cameraState
                
                print("[map] 📷 Camera changed: zoom=\(String(format: "%.2f", cameraState.zoom)), pitch=\(String(format: "%.1f", cameraState.pitch))°")
                
                DispatchQueue.main.async {
                    self.onCameraChanged(cameraState)
                    // Only notify about user interaction if this isn't a programmatic bearing change
                    // (Check if bearing change is significant to avoid resetting timer during compass rotation)
                    if let lastCamera = coordinator.lastCameraState {
                        let centerChange = cameraState.center.distance(to: lastCamera.center)
                        let zoomChange = abs(cameraState.zoom - lastCamera.zoom)
                        let bearingChange = abs(cameraState.bearing - lastCamera.bearing)
                        
                        print("[map] 🔍 Camera delta: center=\(String(format: "%.1f", centerChange))m, zoom=\(String(format: "%.3f", zoomChange)), bearing=\(String(format: "%.1f", bearingChange))°")
                        
                        // Only reset auto-center timer if user manually panned/zoomed (not just bearing rotation)
                        if centerChange > 10 || zoomChange > 0.1 {
                            print("[map] 🚨 Triggering user interaction: centerChange=\(String(format: "%.1f", centerChange))m OR zoomChange=\(String(format: "%.3f", zoomChange))")
                            self.onUserInteraction()
                        } else {
                            print("[map] ✅ Ignoring camera change (bearing/pitch only): centerChange=\(String(format: "%.1f", centerChange))m, zoomChange=\(String(format: "%.3f", zoomChange))")
                        }
                    } else {
                        print("[map] 📍 First camera state - no previous state to compare")
                    }
                    coordinator.lastCameraState = cameraState
                }
            }
            
            print("[map] 📷 Map setup complete with camera observer for debug updates")
        }
        
        context.coordinator.mapView = mapView
        
        // Also test camera state right after mapView creation
        print("[map] 📸 MapView created - camera: zoom=\(String(format: "%.2f", mapView.mapboxMap.cameraState.zoom)), pitch=\(String(format: "%.1f", mapView.mapboxMap.cameraState.pitch))°")
        
        return mapView
    }
    
    func updateUIView(_ uiView: MapView, context: Context) {
        // Update dynamic values in coordinator
        context.coordinator.dynamicTopPadding = dynamicTopPadding
        context.coordinator.dynamicBottomPadding = dynamicBottomPadding
        context.coordinator.defaultPitch = defaultPitch
        context.coordinator.defaultZoom = defaultZoom
        
        // Update viewport when SwiftUI state changes
        context.coordinator.updateViewport(viewport, allowUpdate: allowViewportUpdate)
        context.coordinator.updateUserPath(userPath)
        context.coordinator.updateUserLocation(userLocation)
    }
    
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        DispatchQueue.main.async {
            self.coordinator = coordinator
        }
        return coordinator
    }
    
    class Coordinator {
        weak var mapView: MapView?
        var styleObserver: Cancelable?
        var cameraObserver: Cancelable?
        weak var skyGateRecognizer: SkyGateRecognizer?
        var lastCameraState: CameraState?
        var dynamicTopPadding: Double = 200.0 // Store dynamic top padding value
        var dynamicBottomPadding: Double = 0.0 // Store dynamic bottom padding value
        var defaultPitch: Double = 85.0 // Store default pitch value
        var defaultZoom: Double = 16.0 // Store default zoom value
        
        func updateViewport(_ viewport: Viewport, allowUpdate: Bool) {
            guard mapView != nil else { return }
            
            // Only apply viewport changes when explicitly allowed (e.g. location button)
            if !allowUpdate {
                print("[map] 🚫 updateViewport blocked to prevent snap-back")
                return
            }
            
            // Extract camera options from viewport and apply them through our single camera update system
            let cameraOptions = viewport.camera
            if let options = cameraOptions, let center = options.center {
                print("[map] 📷 Viewport update through single camera system: center=\(center.latitude), zoom=\(options.zoom ?? 0), pitch=\(options.pitch ?? 0)")
                
                // Use our single updateCamera function to preserve current values and use padding positioning
                updateCamera(
                    userLocation: center,
                    zoom: options.zoom.map(Double.init), // Convert CGFloat? to Double?
                    bearing: options.bearing, // Already Double?
                    pitch: options.pitch.map(Double.init), // Convert CGFloat? to Double?
                    duration: 0.5
                )
            }
        }
        
        func updateUserPath(_ path: [CLLocationCoordinate2D]) {
            guard let mapView = mapView else { return }
            
            guard path.count >= 2 else { 
                // Remove path if no points
                try? mapView.mapboxMap.removeLayer(withId: "user-path")
                try? mapView.mapboxMap.removeSource(withId: "user-path-source")
                return 
            }
            
            // Remove existing path
            try? mapView.mapboxMap.removeLayer(withId: "user-path")
            try? mapView.mapboxMap.removeSource(withId: "user-path-source")
            
            // Add new path
            let lineString = LineString(path)
            var source = GeoJSONSource(id: "user-path-source")
            source.data = .geometry(Geometry.lineString(lineString))
            
            var pathLayer = LineLayer(id: "user-path", source: "user-path-source")
            pathLayer.lineColor = .constant(StyleColor(.systemGreen))
            pathLayer.lineWidth = .constant(4.0)
            pathLayer.lineOpacity = .constant(0.8)
            
            try? mapView.mapboxMap.addSource(source)
            try? mapView.mapboxMap.addLayer(pathLayer)
            
            print("[map] 🛤️ Updated journey path with \(path.count) points")
        }
         
        func updateUserLocation(_ location: CLLocationCoordinate2D?) {
            // Puck should automatically use device location via locationProvider
            // This function is kept for compatibility but puck handles location internally
            if let location = location {
                print("[map] 📍 User location available: \(location)")
            }
        }
        
        func setupSkyGateRecognizer(mapView: MapView?, metalSynth: MetalWavetableSynth?, onSkyTouchCountChanged: @escaping (Int) -> Void, hologramCoordinator: AnyObject?) {
            guard let mapView = mapView else { 
                print("[map] ❌ No mapView for SkyGateRecognizer")
                return 
            }
            
            print("[map] 🚪 Setting up SkyGateRecognizer with metalSynth: \(metalSynth != nil ? "✅" : "❌")")
            
            // Remove any existing SkyGateRecognizer first
            mapView.gestureRecognizers?.forEach { recognizer in
                if recognizer is SkyGateRecognizer {
                    mapView.removeGestureRecognizer(recognizer)
                    print("[map] 🗑️ Removed old SkyGateRecognizer")
                }
            }
            
            let gate = SkyGateRecognizer(mapLoaded: mapView as AnyObject, metalSynth: metalSynth, onSkyTouchCountChanged: onSkyTouchCountChanged)
            self.skyGateRecognizer = gate  // Keep reference for later updates
            
            // Set up hologram coordinator
            gate.updateHologramCoordinator(hologramCoordinator)
            
            // Configure Mapbox gesture recognizers to require SkyGate to fail BEFORE adding SkyGate
            let recognizers = mapView.gestureRecognizers ?? []
            print("[map] 🔍 Found \(recognizers.count) existing gesture recognizers")
            
            var configuredCount = 0
            for recognizer in recognizers {
                let name = String(describing: type(of: recognizer))
                print("[map] 🔍 Gesture recognizer: \(name)")
                // Configure ALL Mapbox gestures to wait for SkyGate
                recognizer.require(toFail: gate)
                configuredCount += 1
                print("[map] ✅ Configured \(name) to wait for SkyGate")
            }
            
            // NOW add the SkyGate recognizer
            mapView.addGestureRecognizer(gate)
            print("[map] 🚪 Added SkyGateRecognizer to mapView")
            
            print("[map] 🎉 SkyGateRecognizer setup complete! Configured \(configuredCount) gestures to wait for SkyGate")
        }
        
        func updateSkyGateSynth(_ metalSynth: MetalWavetableSynth?) {
            skyGateRecognizer?.updateMetalSynth(metalSynth)
        }
        
        func adjustPitchIfNeeded(mapView: MapView, currentZoom: CGFloat) {
            // Temporarily disabled to prevent camera snapping
            print("[map] 🔧 adjustPitchIfNeeded disabled to prevent camera snapping")
        }
        
        func updateBearing(_ bearing: Double, userLocation: CLLocationCoordinate2D) {
            print("[map] 🧭 Updating map bearing to: \(String(format: "%.1f", bearing))°")
            updateCamera(userLocation: userLocation, bearing: bearing, duration: 1.0)
        }
        
        // Helper function to calculate padding using dynamic slider value
        private func getPuckPadding() -> UIEdgeInsets {
            // Use the dynamic padding values from the coordinator (which are updated from parent view)
            // Top padding: 0-600px, Bottom padding: 0-200px
            return UIEdgeInsets(
                top: CGFloat(dynamicTopPadding), 
                left: 0, 
                bottom: CGFloat(dynamicBottomPadding), 
                right: 0
            )
        }
        
        // SINGLE camera update function - ALL camera changes go through here
        func updateCamera(
            userLocation: CLLocationCoordinate2D,
            zoom: Double? = nil,
            bearing: Double? = nil, 
            pitch: Double? = nil,
            padding: UIEdgeInsets? = nil,
            duration: Double = 0.3
        ) {
            guard let mapView = mapView else { return }
            
            let currentCamera = mapView.mapboxMap.cameraState
            let puckPadding = getPuckPadding() // Calculate padding instead of anchor
            
            // Determine final values
            let finalZoom = zoom ?? currentCamera.zoom
            let finalBearing = bearing ?? currentCamera.bearing
            let finalPitch = pitch ?? currentCamera.pitch
            
            // ERROR CHECK: Never allow zoom 1 (this should never happen!)
            if finalZoom <= 1.1 {
                print("[map] 🚨 ERROR: Attempting to set zoom to \(finalZoom) - THIS SHOULD NEVER HAPPEN!")
                print("[map] 🚨 Stack trace: \(Thread.callStackSymbols.prefix(5))")
                print("[map] 🚨 Current camera: zoom=\(currentCamera.zoom), pitch=\(currentCamera.pitch)°")
                print("[map] 🚨 Requested: zoom=\(zoom?.description ?? "nil"), pitch=\(pitch?.description ?? "nil")°")
                // Don't proceed with the bad zoom value
                return
            }
            
            // ERROR CHECK: Never allow invalid coordinates (0,0) - THIS SHOULD NEVER HAPPEN!
            if abs(userLocation.latitude) < 0.001 && abs(userLocation.longitude) < 0.001 {
                print("[map] 🚨 ERROR: Attempting to set center to invalid coordinates (0,0) - THIS SHOULD NEVER HAPPEN!")
                print("[map] 🚨 User location: \(userLocation)")
                print("[map] 🚨 Stack trace: \(Thread.callStackSymbols.prefix(5))")
                // Don't proceed with invalid coordinates
                return
            }
            
            // Combine user-provided padding with puck positioning padding
            let finalPadding = padding ?? puckPadding
            
            let cameraOptions = CameraOptions(
                center: userLocation, // User location appears at the center after padding offset
                padding: finalPadding, // Padding pushes center down to put puck at 25% from bottom
                zoom: finalZoom, // Use provided or preserve current
                bearing: finalBearing, // Use provided or preserve current
                pitch: finalPitch // Use provided or preserve current
            )
            
            // COMPREHENSIVE LOGGING
            print("[map] 🎯 === SINGLE CAMERA UPDATE ===")
            print("[map] 🎯 Center: (\(String(format: "%.6f", userLocation.latitude)), \(String(format: "%.6f", userLocation.longitude)))")
            print("[map] 🎯 Padding: top=\(finalPadding.top)px (positions puck at 25% from bottom)")
            print("[map] 🎯 Zoom: \(String(format: "%.2f", finalZoom)) (requested: \(zoom?.description ?? "nil"), current: \(String(format: "%.2f", currentCamera.zoom)))")
            print("[map] 🎯 Bearing: \(String(format: "%.1f", finalBearing))° (requested: \(bearing?.description ?? "nil"), current: \(String(format: "%.1f", currentCamera.bearing))°)")
            print("[map] 🎯 Pitch: \(String(format: "%.1f", finalPitch))° (requested: \(pitch?.description ?? "nil"), current: \(String(format: "%.1f", currentCamera.pitch))°)")
            print("[map] 🎯 Duration: \(duration)s")
            print("[map] 🎯 ===============================")
            
            // Using center + padding approach for reliable puck positioning
            print("[map] 📏 Using center + padding approach (not anchor) for puck positioning...")
            
            mapView.camera.ease(
                to: cameraOptions,
                duration: duration,
                curve: .easeOut,
                completion: { _ in
                    let finalCamera = mapView.mapboxMap.cameraState
                    print("[map] ✅ Animation complete - Final camera: zoom=\(String(format: "%.2f", finalCamera.zoom)), pitch=\(String(format: "%.1f", finalCamera.pitch))°")
                    print("[map] ✅ Final center: (\(String(format: "%.6f", finalCamera.center.latitude)), \(String(format: "%.6f", finalCamera.center.longitude)))")
                }
            )
            
            print("[map] ⚓ SINGLE camera update: zoom=\(zoom ?? currentCamera.zoom), bearing=\(String(format: "%.1f", bearing ?? currentCamera.bearing))°, pitch=\(pitch ?? currentCamera.pitch)°")
        }
        
        func updateBearingWithUserLocation(_ bearing: Double, userLocation: CLLocationCoordinate2D) {
            print("[map] 🧭 Rotating map to bearing \(String(format: "%.1f", bearing))°")
            updateCamera(userLocation: userLocation, bearing: bearing, duration: 0.3)
        }
        
        func updateCameraPadding(top: Double) {
            guard let mapView = mapView else { 
                print("[map] ❌ MapView is nil in updateCameraPadding")
                return 
            }
            
            // We need a user location for our single camera update system
            let currentCamera = mapView.mapboxMap.cameraState
            let userLocation = currentCamera.center
            
            print("[map] 📏 Updating camera padding through single camera system: top=\(top)px")
            
            // Use our single updateCamera function to preserve current values and use anchor positioning
            updateCamera(
                userLocation: userLocation,
                padding: UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0),
                duration: 0.3
            )
        }
        
        func updateCameraZoom(_ zoom: Double, userLocation: CLLocationCoordinate2D) {
            print("[map] 🔍 Updating camera zoom to: \(String(format: "%.1f", zoom))")
            updateCamera(userLocation: userLocation, zoom: zoom, duration: 0.5)
        }
        
        func animateToLocation(_ coordinate: CLLocationCoordinate2D) {
            print("[map] 🎬 Animating to location: \(coordinate)")
            print("[map] 🎬 Is this San Francisco? \(coordinate.latitude > 37.0 && coordinate.latitude < 38.0 && coordinate.longitude > -123.0 && coordinate.longitude < -122.0 ? "YES! ⚠️" : "No")")
            
            guard let mapView = mapView else { return }
            let currentCamera = mapView.mapboxMap.cameraState
            print("[map] 🎬 Current camera before location button: zoom=\(String(format: "%.2f", currentCamera.zoom)), pitch=\(String(format: "%.1f", currentCamera.pitch))°, bearing=\(String(format: "%.1f", currentCamera.bearing))°")
            
            // For location button, use our app's standard defaults
            updateCamera(
                userLocation: coordinate,
                zoom: defaultZoom,  // Use persistent default zoom for location button
                bearing: currentCamera.bearing, // Preserve bearing  
                pitch: defaultPitch, // Use persistent default pitch for location button
                duration: 0.8
            )
        }
        
        func continuouslyCenterOnUser(_ coordinate: CLLocationCoordinate2D) {
            print("[map] 🎯 Continuously centering user")
            updateCamera(userLocation: coordinate, duration: 1.5)
        }
        
    }
}
