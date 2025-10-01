//
//  CustomMapView.swift
//  kiloworld
//
//  Created by Claude on 9/22/25.
//

// FUNCTION ANALYSIS FOR CLEANUP:
// ✅ KEEP: Core functionality, used regularly
// ⚠️ REVIEW: May be overly complex or redundant
// ❌ REMOVE: Unused, deprecated, or unnecessary complexity

import SwiftUI
import MapboxMaps
import Turf
import CoreLocation

// MARK: - Custom MapView
struct CustomMapView: UIViewRepresentable {
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
    let userSettings: UserSettings // User settings for horizon controls

    /// ❌ REMOVE: This function is unused - globe toggle handled directly in ContentView
    func setElectrifiedGlobeEnabled(_ enabled: Bool) {
        if enabled {
            coordinator?.mode = .neon
            coordinator?.toggleElectrifiedGlobe(userLocation: userLocation)
        } else {
            coordinator?.mode = .globe
            coordinator?.toggleElectrifiedGlobe(userLocation: userLocation)
        }
    }

    /// ✅ KEEP: Core UIViewRepresentable requirement - creates the MapView
    func makeUIView(context: Context) -> MapView {
        let mapView = MapView(frame: .zero)
        
        // Load dark style first
        mapView.mapboxMap.loadStyle(.dark) { error in
            if let error = error {
                print("[map] ❌ Failed to load dark style: \(error)")
            } else {
                print("[map] 🌑 Dark style loaded successfully")
                DispatchQueue.main.async {
                    mapView.applyNeonGridStyle(with: self.userSettings)
                }
            }
        }
        
        // Configure gesture options
        mapView.gestures.options.panEnabled = false // Ensure pan is enabled for map movement
        mapView.gestures.options.pinchEnabled = true // Ensure pinch is enabled for zoom
        mapView.gestures.options.doubleTapToZoomInEnabled = false
        mapView.gestures.options.doubleTouchToZoomOutEnabled = false
        mapView.gestures.options.rotateEnabled = false
        mapView.gestures.options.quickZoomEnabled = false
        mapView.gestures.options.pitchEnabled = true // Allow programmatic pitch changes
        
        print("[map] 🎮 Gesture options: pan=\(mapView.gestures.options.panEnabled), pinch=\(mapView.gestures.options.pinchEnabled), pitch=\(mapView.gestures.options.pitchEnabled)")
        
        
        // Configure location with 2D puck to avoid URI errors
        let puck2DConfig = Puck2DConfiguration(
            topImage: nil, // Use default arrow
            bearingImage: nil,
            shadowImage: nil,
            scale: .constant(4.0), // Even larger puck for more presence
            showsAccuracyRing: true, // Enable accuracy ring for additional glow effect
            accuracyRingColor: UIColor.cyan.withAlphaComponent(0.3), // Cyan glow ring
            accuracyRingBorderColor: UIColor.cyan.withAlphaComponent(0.8) // Bright cyan border
        )

        let locationOptions = LocationOptions(
            puckType: .puck2D(puck2DConfig),
            puckBearing: .heading,
            puckBearingEnabled: true
        )
        mapView.location.options = locationOptions
        
        // Explicitly start location updates to make puck visible
        print("[map] 📍 Starting mapView location updates for puck visibility")
        
        // Set up style loaded callback
        context.coordinator.styleObserver = mapView.mapboxMap.onStyleLoaded.observe { [weak mapView] _ in
            print("[MAP] 🎨 Style loaded callback triggered")
            print("[MAP] 🗺️ About to apply NeonGridStyle...")
            mapView?.applyNeonGridStyle(with: self.userSettings)
            print("[MAP] ⚡ NeonGridStyle application requested")

            // One-time initial camera so we see something besides the dark background.
            if let mapView = mapView, let coord = mapView.location.latestLocation?.coordinate {
                context.coordinator.didSetInitialCamera = true
                context.coordinator.updateCamera(
                    userLocation: coord,
                    zoom: max(self.defaultZoom, 15.5),
                    pitch: self.defaultPitch,
                    duration: 0.0
                )
            } else if let mapView = mapView {
                // Fallback to SF until the first GPS fix arrives.
                context.coordinator.updateCamera(
                    userLocation: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                    zoom: max(self.defaultZoom, 15.5),
                    pitch: self.defaultPitch,
                    duration: 0.0
                )
            }

            // Recenter exactly once when we get the first real GPS update.
            _ = mapView?.location.onLocationChange.observeNext { [weak mapView, weak coordinator = context.coordinator] update in
                guard let coordinator = coordinator,
                      coordinator.didSetInitialCamera == false,
                      let loc = update.last?.coordinate else { return }
                coordinator.didSetInitialCamera = true
                coordinator.updateCamera(
                    userLocation: loc,
                    zoom: max(self.defaultZoom, 15.5),
                    pitch: self.defaultPitch,
                    duration: 0.0
                )
            }

            onMapLoaded()

            // Set up SkyGateRecognizer
            DispatchQueue.main.async {
                context.coordinator.setupSkyGateRecognizer(mapView: mapView, metalSynth: metalSynth, onSkyTouchCountChanged: onSkyTouchCountChanged, hologramCoordinator: hologramCoordinator)
            }
            
            // Set up camera observer for debug panel updates and auto-center reset
            context.coordinator.cameraObserver = mapView?.mapboxMap.onCameraChanged.observe { [weak mapView, weak coordinator = context.coordinator] _ in
                guard let mapView = mapView, let coordinator = coordinator else { return }
                let cameraState = mapView.mapboxMap.cameraState
                
                DispatchQueue.main.async {
                    self.onCameraChanged(cameraState)
                    // Only notify about user interaction if this isn't a programmatic bearing change
                    // (Check if bearing change is significant to avoid resetting timer during compass rotation)
                    if let lastCamera = coordinator.lastCameraState {
                        let centerChange = cameraState.center.distance(to: lastCamera.center)
                        let zoomChange = abs(cameraState.zoom - lastCamera.zoom)
                        
                        // Only reset auto-center timer if user manually panned/zoomed (not just bearing rotation)
                        if centerChange > 10 || zoomChange > 0.1 {
                            print("[map] 🚨 Triggering user interaction: centerChange=\(String(format: "%.1f", centerChange))m OR zoomChange=\(String(format: "%.3f", zoomChange))")
                            self.onUserInteraction()
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
    
    /// ✅ KEEP: Core UIViewRepresentable requirement - updates MapView when SwiftUI state changes
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
    
    /// ✅ KEEP: Core UIViewRepresentable requirement - creates the coordinator
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
        var didSetInitialCamera = false
        enum MapMode { case neon, globe }
        var mode: MapMode = .neon
        
        /// ⚠️ REVIEW: Complex viewport handling - could be simplified or removed if not used
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
                // Safety check: Don't use invalid (0,0) coordinates from viewport
                if abs(center.latitude) < 0.001 && abs(center.longitude) < 0.001 {
                    // Silently ignore placeholder viewport - no need to spam logs
                    return
                }

                print("[map] 📷 Viewport update through single camera system: center=(\(center.latitude), \(center.longitude)), zoom=\(options.zoom ?? 0), pitch=\(options.pitch ?? 0)")

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
        
        /// ✅ KEEP: Essential for showing user's journey path on the map
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
            pathLayer.lineColor = .constant(StyleColor(UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))) // Maximum bright white
            pathLayer.lineWidth = .expression(Exp(.interpolate) {
                Exp(.linear)
                Exp(.zoom)
                10; 3.0  // Even wider for visibility
                12; 5.0
                14; 8.0
                16; 12.0
                18; 24.0
            }) // Much wider white path
            pathLayer.lineOpacity = .constant(1.0) // 100% opacity
            pathLayer.lineBlur = .constant(0.0) // Remove blur for maximum contrast

            try? mapView.mapboxMap.addSource(source)
            try? mapView.mapboxMap.addLayer(pathLayer, layerPosition: .above("neon-road-labels")) // Above all roads and labels
            
            // Journey path updated (\(path.count) points)
        }
         
        /// ❌ REMOVE: Function does nothing - puck handles location automatically
        func updateUserLocation(_ location: CLLocationCoordinate2D?) {
            // Puck should automatically use device location via locationProvider
            // This function is kept for compatibility but puck handles location internally
            // Location logging removed to reduce spam
        }
        
        /// ✅ KEEP: Essential for SkyGate touch interaction system
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
        
        /// ✅ KEEP: Needed to update synth reference in SkyGate
        func updateSkyGateSynth(_ metalSynth: MetalWavetableSynth?) {
            skyGateRecognizer?.updateMetalSynth(metalSynth)
        }
        
        /// ❌ REMOVE: Function is disabled and serves no purpose
        func adjustPitchIfNeeded(mapView: MapView, currentZoom: CGFloat) {
            // Temporarily disabled to prevent camera snapping
            print("[map] 🔧 adjustPitchIfNeeded disabled to prevent camera snapping")
        }
        
        /// ✅ KEEP: Essential for compass-based map rotation
        func updateBearing(_ bearing: Double, userLocation: CLLocationCoordinate2D) {
            print("[map] 🧭 Updating map bearing to: \(String(format: "%.1f", bearing))°")
            updateCamera(userLocation: userLocation, bearing: bearing, duration: 1.0)
        }
        
        /// ✅ KEEP: Essential for puck positioning with dynamic padding
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
        
        /// ✅ KEEP: Essential for hologram particle emission at puck location
        func getPuckScreenPosition() -> CGPoint? {
            guard let mapView = mapView else { return nil }
            
            let padding = getPuckPadding()
            let viewBounds = mapView.bounds
            
            // Puck appears in the center of the "padded" area
            // With top padding, the effective center moves down
            let puckX = viewBounds.width / 2 // Always centered horizontally
            let effectiveHeight = viewBounds.height - padding.top - padding.bottom
            let puckY = padding.top + (effectiveHeight / 2)
            
            return CGPoint(x: puckX, y: puckY)
        }
        
        /// ✅ KEEP: Core camera control function - all camera movements use this
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
            
            // ERROR CHECK: Never allow zoom < 0.1 (but allow space view 0.5-1.0)
            if finalZoom < 0.1 {
                print("[map] 🚨 ERROR: Attempting to set zoom to \(finalZoom) - too low for space view!")
                print("[map] 🚨 Stack trace: \(Thread.callStackSymbols.prefix(5))")
                print("[map] 🚨 Current camera: zoom=\(currentCamera.zoom), pitch=\(currentCamera.pitch)°")
                print("[map] 🚨 Requested: zoom=\(zoom?.description ?? "nil"), pitch=\(pitch?.description ?? "nil")°")
                // Don't proceed with the bad zoom value
                return
            }
            
            // ERROR CHECK: Allow (0,0) for space view, but warn about other invalid coordinates
            if abs(userLocation.latitude) < 0.001 && abs(userLocation.longitude) < 0.001 && finalZoom > 2.0 {
                print("[map] 🚨 ERROR: Attempting to set center to invalid coordinates (0,0) at zoom \(finalZoom)")
                print("[map] 🚨 User location: \(userLocation)")
                print("[map] 🚨 Stack trace: \(Thread.callStackSymbols.prefix(5))")
                // Don't proceed with invalid coordinates at high zoom
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
            
            // Detailed logging disabled to reduce spam
            
            // Using center + padding approach for reliable puck positioning
            print("[map] 📏 Using center + padding approach (not anchor) for puck positioning...")
            
            mapView.camera.ease(
                to: cameraOptions,
                duration: duration,
                curve: .easeOut,
                completion: { _ in
                    let finalCamera = mapView.mapboxMap.cameraState
                    // Animation complete
                    print("[map] ✅ Final center: (\(String(format: "%.6f", finalCamera.center.latitude)), \(String(format: "%.6f", finalCamera.center.longitude)))")
                }
            )
            
            print("[map] ⚓ SINGLE camera update: zoom=\(zoom ?? currentCamera.zoom), bearing=\(String(format: "%.1f", bearing ?? currentCamera.bearing))°, pitch=\(pitch ?? currentCamera.pitch)°")
        }
        
        /// ⚠️ REVIEW: Duplicate of updateBearing - could be merged
        func updateBearingWithUserLocation(_ bearing: Double, userLocation: CLLocationCoordinate2D) {
            print("[map] 🧭 Rotating map to bearing \(String(format: "%.1f", bearing))°")
            updateCamera(userLocation: userLocation, bearing: bearing, duration: 0.3)
        }
        
        /// ❌ REMOVE: Not used - dynamic padding handled through updateCamera
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
        
        /// ⚠️ REVIEW: Simple wrapper around updateCamera - could be inlined
        func updateCameraZoom(_ zoom: Double, userLocation: CLLocationCoordinate2D) {
            print("[map] 🔍 Updating camera zoom to: \(String(format: "%.1f", zoom))")
            updateCamera(userLocation: userLocation, zoom: zoom, duration: 0.5)
        }
        
        /// ✅ KEEP: Essential for location button functionality
        func animateToLocation(_ coordinate: CLLocationCoordinate2D) {
            print("[map] 🎬 Animating to location: \(coordinate)")
            print("[map] 🎬 Is this San Francisco? \(coordinate.latitude > 37.0 && coordinate.latitude < 38.0 && coordinate.longitude > -123.0 && coordinate.longitude < -122.0 ? "YES! ⚠️" : "No")")
            
            guard let mapView = mapView else { return }
            let currentCamera = mapView.mapboxMap.cameraState
            print("[map] 🎬 Current camera before location button: zoom=\(String(format: "%.2f", currentCamera.zoom)), pitch=\(String(format: "%.1f", currentCamera.pitch))°, bearing=\(String(format: "%.1f", currentCamera.bearing))°")
            
            // For location button, use our app's standard defaults
            print("[map] 🎯 Location button zoom target: \(defaultZoom) (should fly to this zoom level)")
            updateCamera(
                userLocation: coordinate,
                zoom: defaultZoom,  // Use persistent default zoom for location button
                bearing: currentCamera.bearing, // Preserve bearing
                pitch: defaultPitch, // Use persistent default pitch for location button
                duration: 2.0 // Faster animation (was 4.0) to reduce interruption chance
            )

            // Add completion callback to ensure zoom reaches target
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self = self, let mapView = self.mapView else { return }
                let finalCamera = mapView.mapboxMap.cameraState
                if abs(finalCamera.zoom - defaultZoom) > 0.5 {
                    print("[map] ⚠️ Location button zoom didn't reach target (\(String(format: "%.2f", finalCamera.zoom)) vs \(defaultZoom)), correcting...")
                    self.updateCamera(
                        userLocation: coordinate,
                        zoom: defaultZoom,
                        pitch: defaultPitch,
                        duration: 1.0
                    )
                } else {
                    print("[map] ✅ Location button animation completed successfully")
                }
            }
        }
        
        /// ⚠️ REVIEW: Rarely used function - could be merged with animateToLocation
        func continuouslyCenterOnUser(_ coordinate: CLLocationCoordinate2D) {
            print("[map] 🎯 Continuously centering user")
            updateCamera(userLocation: coordinate, duration: 1.5)
        }

        /// ✅ KEEP: Essential for updating neon style when user settings change
        func reapplyNeonGridStyle(with userSettings: UserSettings) {
            print("[map] 🎨 Reapplying neon grid style - width:\(userSettings.horizonWidth) start:\(userSettings.horizonStart) feather:\(userSettings.horizonFeather)")
            guard let mapView = mapView else {
                print("[map] ❌ MapView is nil in reapplyNeonGridStyle")
                return
            }
            mapView.applyNeonGridStyle(with: userSettings)
        }

        /// ✅ KEEP: Essential for globe mode functionality
        func toggleElectrifiedGlobe(userLocation: CLLocationCoordinate2D?) {
            switch mode {
            case .neon: enterGlobe(userLocation: userLocation)
            case .globe: exitGlobe(to: userLocation)
            }
        }

        /// ⚠️ REVIEW: Very complex function with lots of styling code - could be simplified
        private func enterGlobe(userLocation: CLLocationCoordinate2D?) {
            guard let mapView = mapView else { return }

            // 1) Switch to globe projection
            try? mapView.mapboxMap.style.setProjection(StyleProjection(name: .globe))

            // 2) Add city lights / population electrified effect
            let srcId = "city-lights"
            let layerId = "city-lights-layer"
            if !((try? mapView.mapboxMap.style.sourceExists(withId: srcId)) ?? false) {

                // Black Marble TIF needs to be treated as equirectangular and reprojected
                // For now, we need GDAL conversion to Web Mercator projection
                print("[lights] ⚠️ Black Marble TIF requires GDAL reprojection from equirectangular to Web Mercator")
                print("[lights] ⚠️ Cannot display equirectangular projection directly on globe without distortion")

                // Use Black Marble TIF with manual equirectangular correction
                if let blackMarbleURL = Bundle.main.url(forResource: "BlackMarble_2016_3km_geo", withExtension: "tif") {
                    var imageSource = ImageSource(id: srcId)
                    imageSource.url = blackMarbleURL.absoluteString
                    // Manually correct for equirectangular distortion by limiting latitude range
                    // This reduces the polar stretching effect
                    imageSource.coordinates = [
                        [-180, 70],   // top-left (reduced from 90 to minimize polar distortion)
                        [180, 70],    // top-right
                        [180, -70],   // bottom-right (reduced from -90)
                        [-180, -70]   // bottom-left
                    ]
                    try? mapView.mapboxMap.style.addSource(imageSource)
                    print("[lights] 🖤 Using Black Marble TIF with reduced polar coordinates to minimize distortion")
                } else {
                    // Fallback to GIBS tiles
                    var src = RasterSource(id: srcId)
                    src.tiles = [
                        "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/VIIRS_Night_Lights/default/default/GoogleMapsCompatible_Level8/{z}/{y}/{x}.png"
                    ]
                    src.tileSize = 256
                    try? mapView.mapboxMap.style.addSource(src)
                    print("[lights] 🌐 Using GIBS tiles (Black Marble TIF not found)")
                }

                print("[lights] ✅ City lights source configuration complete")

                var lights = RasterLayer(id: layerId, source: srcId)
                lights.rasterOpacity = .constant(1.0) // Full opacity to see lights clearly
                lights.rasterBrightnessMax = .constant(3.0) // Even brighter for TIF visibility
                lights.rasterBrightnessMin = .constant(0.0) // Dark blacks
                lights.rasterContrast = .constant(1.5) // Much higher contrast for TIF
                lights.rasterSaturation = .constant(2.0) // Very saturated
                print("[lights] 🎛️ Enhanced raster settings for Black Marble visibility")

                // Add layer with error logging - put on top for visibility
                do {
                    try mapView.mapboxMap.style.addLayer(lights, layerPosition: .default)
                    print("[lights] ✨ City lights layer added successfully for electrified effect")
                } catch {
                    print("[lights] ❌ Failed to add city lights layer: \(error)")
                }
            }

            // 3) Subtle blue atmosphere glow close to Earth, black space
            var atm = Atmosphere()
            atm.range = .constant([0.8, 2.0]) // Narrow range - only near Earth
            atm.color = .constant(StyleColor(UIColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 0.4))) // Subtle cyan-blue
            atm.highColor = .constant(StyleColor(UIColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 0.3))) // Dimmer blue
            atm.spaceColor = .constant(StyleColor(.black)) // Pure black space
            atm.horizonBlend = .constant(0.1) // Subtle glow blend
            atm.starIntensity = .constant(0.6) // Dim stars
            try? mapView.mapboxMap.style.setAtmosphere(atm)

            // Darken the base land so city lights pop against dark background
            do {
                // Check if land layer exists first
                let landExists = try mapView.mapboxMap.style.layerExists(withId: "land")
                print("[lights] 🔍 Land layer exists: \(landExists)")

                if landExists {
                    try mapView.mapboxMap.style.setLayerProperty(for: "land", property: "fill-color", value: "rgba(20,20,40,1)")
                    print("[lights] 🌍 Land darkened to show city lights")
                } else {
                    print("[lights] ❌ No 'land' layer found - checking available layers...")
                    // List all available layers to see what we can modify
                    let allLayers = try mapView.mapboxMap.style.allLayerIdentifiers
                    print("[lights] 📋 Available layers: \(allLayers.map { $0.id })")
                }
            } catch {
                print("[lights] ⚠️ Could not darken land: \(error)")

                // Try alternative layer names and properties that might control land color
                let layerAttempts = [
                    ("background", "background-color"),
                    ("landuse", "fill-color"),
                    ("landcover", "fill-color"),
                    ("natural", "fill-color"),
                    ("land", "background-color"),
                    ("water", "fill-color")
                ]

                for (layerName, property) in layerAttempts {
                    do {
                        let exists = try mapView.mapboxMap.style.layerExists(withId: layerName)
                        if exists {
                            try mapView.mapboxMap.style.setLayerProperty(for: layerName, property: property, value: "rgba(20,20,40,1)")
                            print("[lights] 🌍 Darkened \(layerName) layer with \(property)")
                        } else {
                            print("[lights] 🔍 Layer \(layerName) not found")
                        }
                    } catch {
                        print("[lights] ⚠️ Failed to modify \(layerName) with \(property): \(error)")
                    }
                }

                // Also try to set the overall background to dark
                try? mapView.mapboxMap.style.setLayerProperty(for: "background", property: "background-color", value: "rgba(10,10,20,1)")
                print("[lights] 🎨 Attempted to set dark background")

                // Make oceans/water dark blue for contrast with black land
                do {
                    let waterExists = try mapView.mapboxMap.style.layerExists(withId: "water")
                    if waterExists {
                        try mapView.mapboxMap.style.setLayerProperty(for: "water", property: "fill-color", value: "rgba(0,20,40,1)")
                        print("[lights] 🌊 Set oceans to dark blue")
                    } else {
                        print("[lights] 🔍 No 'water' layer found")
                    }
                } catch {
                    print("[lights] ⚠️ Could not modify water layer: \(error)")
                }

                // Re-enable dark overlay since we're using GIBS tiles again
                let overlayId = "dark-land-overlay"
                let overlayLayerId = "dark-overlay-layer"

                // Remove existing overlay if present to force recreation
                try? mapView.mapboxMap.style.removeLayer(withId: overlayLayerId)
                try? mapView.mapboxMap.style.removeSource(withId: overlayId)
                print("[lights] 🧹 Cleaned existing overlay")

                // Always create new overlay
                var overlaySource = GeoJSONSource(id: overlayId)
                // Create a world polygon to cover all land
                let worldPolygon = """
                {
                  "type": "Feature",
                  "geometry": {
                    "type": "Polygon",
                    "coordinates": [[
                      [-180, -85], [180, -85], [180, 85], [-180, 85], [-180, -85]
                    ]]
                  }
                }
                """
                overlaySource.data = .string(worldPolygon)
                try? mapView.mapboxMap.style.addSource(overlaySource)

                var overlay = FillLayer(id: overlayLayerId, source: overlayId)
                overlay.fillColor = .constant(StyleColor(UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)))
                overlay.fillOpacity = .constant(1.0)

                // Add at the very top to ensure it covers everything
                try? mapView.mapboxMap.style.addLayer(overlay, layerPosition: .default)
                print("[lights] 🌑 Added dark overlay to cover white continents")

                // Move city lights layer to absolute top
                try? mapView.mapboxMap.style.moveLayer(withId: "city-lights-layer", to: .default)
                print("[lights] ⬆️ Moved city lights to top layer")

                // Hide any problematic layers that might show white continents
                let layersToHide = ["admin-0-boundary", "admin-1-boundary", "country-label", "state-label"]
                for layerId in layersToHide {
                    if ((try? mapView.mapboxMap.style.layerExists(withId: layerId)) ?? false) {
                        try? mapView.mapboxMap.style.setLayerProperty(for: layerId, property: "visibility", value: "none")
                        print("[lights] 🙈 Hidden layer: \(layerId)")
                    }
                }
            }

            // 4) Enable rotate for spin-the-globe feel
            mapView.gestures.options.rotateEnabled = true

            // 5) Fly out to space at maximum zoom-out with globe positioned near bottom
            let startCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0) // Center on equator and prime meridian
            let cam = CameraOptions(
                center: startCenter,
                padding: UIEdgeInsets(top: 400, left: 0, bottom: 50, right: 0), // Large top padding to push globe down
                zoom: 0.5, // Maximum zoom out for smallest Earth view
                bearing: 0,
                pitch: 0
            )
            print("[globe] 🎯 Globe camera: center=(0,0), zoom=0.5 (max out), globe positioned near bottom")

            mapView.camera.fly(to: cam, duration: 6.0, curve: .easeInOut) { [weak self] _ in
                // Start rotation only after zoom-out animation completes
                print("[globe] ✅ Zoom-out animation complete, starting rotation")
                self?.startGlobeRotation()
            }

            mode = .globe
            print("[globe] 🌍 Entered electrified globe mode")
        }

        /// ⚠️ REVIEW: Very complex function with lots of cleanup code - could be simplified
        private func exitGlobe(to userLocation: CLLocationCoordinate2D?) {
            guard let mapView = mapView else { return }

            // 0) FIRST - Stop globe rotation immediately to prevent interference
            stopGlobeRotation()
            print("[globe] 🛑 Globe rotation stopped before transition")

            // 1) Remove city lights layer/source (best-effort)
            if (try? mapView.mapboxMap.style.layerExists(withId: "city-lights-layer")) == true {
                try? mapView.mapboxMap.style.removeLayer(withId: "city-lights-layer")
            }
            if (try? mapView.mapboxMap.style.sourceExists(withId: "city-lights")) == true {
                try? mapView.mapboxMap.style.removeSource(withId: "city-lights")
            }

            // 2) Back to Mercator
            try? mapView.mapboxMap.style.setProjection(StyleProjection(name: .mercator))

            // 3) Reset atmosphere to defaults first
            var defaultAtm = Atmosphere()
            defaultAtm.range = .constant([2.0, 2.4])
            defaultAtm.color = .constant(StyleColor(UIColor(red: 0.86, green: 0.36, blue: 0.12, alpha: 0.0))) // Disabled
            defaultAtm.highColor = .constant(StyleColor(.black))
            defaultAtm.spaceColor = .constant(StyleColor(.black))
            defaultAtm.horizonBlend = .constant(0.06)
            defaultAtm.starIntensity = .constant(1.0)
            try? mapView.mapboxMap.style.setAtmosphere(defaultAtm)

            // 4) Reset water color from globe mode changes
            do {
                try mapView.mapboxMap.style.setLayerProperty(for: "water", property: "fill-color", value: "rgba(20, 60, 120, 1.0)")
                print("[globe] 🔄 Reset water to neon blue")
            } catch {
                print("[globe] ⚠️ Could not reset water color: \(error)")
            }

            // 5) Restore Neon style
            if let mv = mapView as? MapView {
                mv.applyNeonGridStyle(with: UserSettings())
            }

            // 6) Debug road layers and restore golden colors
            do {
                let allLayers = try mapView.mapboxMap.style.allLayerIdentifiers
                let roadLayers = allLayers.filter { $0.id.contains("road") || $0.id.contains("neon") }
                print("[road-debug] 🔍 Found road layers: \(roadLayers.map { $0.id })")

                // Try to restore all road-related layers
                for layerId in ["neon-roads-glow", "neon-roads-core", "road", "road-street", "road-primary"] {
                    if (try? mapView.mapboxMap.style.layerExists(withId: layerId)) == true {
                        try? mapView.mapboxMap.style.setLayerProperty(for: layerId, property: "line-color", value: "rgba(255, 140, 0, 1.0)")
                        print("[road-debug] 🧡 Restored golden color for layer: \(layerId)")
                    }
                }
            } catch {
                print("[globe] ⚠️ Could not restore road colors: \(error)")
            }

            // 5) Restore gesture prefs
            mapView.gestures.options.rotateEnabled = false

            // 6) Restore location puck with full configuration
            let puck2DConfig = Puck2DConfiguration(
                topImage: nil, // Use default arrow
                bearingImage: nil,
                shadowImage: nil,
                scale: .constant(4.0), // Even larger puck for more presence
                showsAccuracyRing: true, // Enable accuracy ring for additional glow effect
                accuracyRingColor: UIColor.cyan.withAlphaComponent(0.3), // Cyan glow ring
                accuracyRingBorderColor: UIColor.cyan.withAlphaComponent(0.8) // Bright cyan border
            )
            let locationOptions = LocationOptions(
                puckType: .puck2D(puck2DConfig),
                puckBearing: .heading,
                puckBearingEnabled: true
            )
            mapView.location.options = locationOptions
            print("[globe] 🎯 Restored full location puck configuration")

            // 6) Fly camera back to app defaults / current user center
            let current = mapView.mapboxMap.cameraState
            let targetCenter = userLocation ?? current.center

            print("[globe] 🔄 Exiting globe - flying to defaults:")
            print("[globe] 🔄 Target zoom: \(defaultZoom) (should be ~16)")
            print("[globe] 🔄 Target pitch: \(defaultPitch)° (should be ~85°)")
            print("[globe] 🔄 Target center: (\(targetCenter.latitude), \(targetCenter.longitude))")

            // Add a small delay to ensure all systems (rotation, etc.) have stopped
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                print("[globe] 🚀 Starting camera transition to neon defaults")

                // Use a faster, more reliable transition
                self.updateCamera(
                    userLocation: targetCenter,
                    zoom: defaultZoom,
                    bearing: current.bearing, // Keep current bearing to avoid disorientation
                    pitch: defaultPitch,
                    duration: 2.0 // Faster transition (was 5.0) to reduce chance of interruption
                )

                // Add completion callback to ensure zoom reaches target
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self = self else { return }
                    let finalCamera = self.mapView?.mapboxMap.cameraState
                    if let finalZoom = finalCamera?.zoom, abs(finalZoom - defaultZoom) > 0.5 {
                        print("[globe] ⚠️ Zoom didn't reach target (\(String(format: "%.2f", finalZoom)) vs \(defaultZoom)), correcting...")
                        self.updateCamera(
                            userLocation: targetCenter,
                            zoom: defaultZoom,
                            pitch: defaultPitch,
                            duration: 1.0
                        )
                    } else {
                        print("[globe] ✅ Camera transition completed successfully")
                    }
                }
            }

            mode = .neon
            print("[globe] 💡 Returned to Neon mode")

            // Stop globe rotation when exiting
            stopGlobeRotation()
        }

        // MARK: - Globe Rotation
        private var rotationTimer: Timer?
        private var currentRotationBearing: Double = 0.0

        /// ✅ KEEP: Essential for globe rotation animation
        private func startGlobeRotation() {
            stopGlobeRotation() // Clean up any existing timer

            print("[globe] 🔄 Starting globe rotation along Earth's axis (N-S pole)")

            // Rotate the globe slowly along its vertical axis (complete rotation in 60 seconds)
            rotationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let mapView = self.mapView else { return }

                // Increment longitude by 0.6 degrees every 0.1 seconds (360° / 60s = 6°/s)
                // This rotates the globe around its vertical axis (North-South pole)
                self.currentRotationBearing += 0.6
                if self.currentRotationBearing >= 360.0 {
                    self.currentRotationBearing = 0.0
                }

                // Only rotate if in globe mode
                guard self.mode == .globe else { return }

                // Calculate new longitude position (rotate around vertical axis)
                let baseLongitude = 0.0 // Start at prime meridian
                let rotatedLongitude = baseLongitude + self.currentRotationBearing
                let normalizedLongitude = rotatedLongitude > 180.0 ? rotatedLongitude - 360.0 : rotatedLongitude

                // Keep camera looking at equator (latitude 0) but rotate longitude
                let currentCamera = mapView.mapboxMap.cameraState
                let rotatedCamera = CameraOptions(
                    center: CLLocationCoordinate2D(latitude: 0.0, longitude: normalizedLongitude),
                    padding: UIEdgeInsets(top: 400, left: 0, bottom: 50, right: 0), // Maintain bottom positioning during rotation
                    zoom: currentCamera.zoom,
                    bearing: 0.0, // Keep north at top
                    pitch: 0.0    // Keep looking straight down at globe
                )

                mapView.camera.ease(to: rotatedCamera, duration: 0.2, curve: .linear) { _ in
                    // Rotation step complete
                }
            }
        }

        /// ✅ KEEP: Essential for cleaning up globe rotation
        private func stopGlobeRotation() {
            rotationTimer?.invalidate()
            rotationTimer = nil
            print("[globe] ⏹️ Stopped globe rotation")
        }

    }

    // CLEANUP SUMMARY:
    // ❌ REMOVE: setElectrifiedGlobeEnabled, updateUserLocation, adjustPitchIfNeeded, updateCameraPadding
    // ⚠️ REVIEW: updateViewport (complex), updateBearingWithUserLocation (duplicate), updateCameraZoom (wrapper),
    //           continuouslyCenterOnUser (rarely used), enterGlobe/exitGlobe (very complex)
    // ✅ KEEP: Core functions for map functionality, camera control, puck positioning, SkyGate, neon styling, globe toggle
}

// MARK: - NeonGridStyle Implementation

// MARK: - Public API you'll call
extension MapView {
    /// Call once after the style loads (you already do this in CustomMapView).
    public func applyNeonGridStyle() {
        NeonGridStyler.shared.apply(to: self)
    }

    /// Apply neon grid style with user settings
    func applyNeonGridStyle(with userSettings: UserSettings) {
        NeonGridStyler.shared.apply(to: self, userSettings: userSettings)
    }


}

// MARK: - Implementation
private final class NeonGridStyler {
    static let shared = NeonGridStyler()

    // IDs
    private let streetsSourceId = "neon-streets"
    private let roadsGlowId = "neon-roads-glow"
    private let roadsCoreId = "neon-roads-core"
    private let beaconsSourceId = "neon-beacons-source"

    private let demSourceId = "mapbox-dem"

    private init() {}

    func apply(to mapView: MapView, userSettings: UserSettings? = nil) {
        let style = mapView.mapboxMap.style
        print("[NEON] 🔥 Applying neon grid with REAL sky/atmosphere + (optional) terrain")

        // 0) Minimize base style clutter but DON'T block engine features (sky/terrain).
        let initialLayers = style.allLayerIdentifiers
        print("[NEON] 📋 Found \(initialLayers.count) existing layers to hide")
        var hiddenCount = 0
        initialLayers.forEach { id in
            if id.id != "user-path"
                && !id.id.hasPrefix("neon-")
                && id.id != "sky"
                && id.id != "land"          // keep base land layer
                && id.id != "water"         // keep base water layer
                && !id.id.contains("label") // keep all labels
                && !id.id.contains("road-label") {       // keep road labels
                try? style.setLayerProperty(for: id.id, property: "visibility", value: "none")
                hiddenCount += 1
            }
        }
        print("[NEON] 👻 Hid \(hiddenCount) default layers, kept land/water/labels")

        // 2) Streets source (for neon roads)
        if !((try? style.sourceExists(withId: streetsSourceId)) ?? false) {
            var streets = VectorSource(id: streetsSourceId)
            streets.url = "mapbox://mapbox.mapbox-streets-v8"
            try? style.addSource(streets)
            print("[NEON] 🧭 Added streets source (v8)")
        }
        print("[NEON] ✅ streets exists? \((try? style.sourceExists(withId: streetsSourceId)) ?? false)")



        // 3) Pure black background instead of sky layer
        var blackBg = BackgroundLayer(id: "black-sky")
        blackBg.backgroundColor = .constant(StyleColor(UIColor.red))
        try? style.addLayer(blackBg)
        print("[NEON] 🌌 Added pure black background")

        // Water fill (oceans/rivers/lakes) - TEMPORARILY HIDDEN FOR TESTING
        var waterFill = FillLayer(id: "water-override", source: streetsSourceId)
        waterFill.sourceLayer = "water"
        waterFill.fillColor = .constant(StyleColor(UIColor(red: 0.05, green: 0.10, blue: 0.20, alpha: 1.0)))
        waterFill.fillOpacity = .constant(1.0)  // HIDDEN FOR TESTING
        try? style.addLayer(waterFill, layerPosition: .above("black-sky"))
        print("[NEON] 💧 Added water override (HIDDEN FOR TESTING)")


        // 4) Configurable orange horizon band (true thickness near camera)
        // Interpret horizonWidth as *kilometers of band thickness*, not a far-field offset.
        let horizonWidth = Double(userSettings?.horizonWidth ?? 0.4)   // km; 0.2–1.0 feels good
        let clampedWidth = max(0.02, min(2.0, horizonWidth))
        let startKm = Double(userSettings?.horizonStart ?? 2.0)       // how close the band begins (km)

        print("[NEON] 🔍 HORIZON DEBUG: userSettings?.horizonStart = \(userSettings?.horizonStart ?? -999)")
        print("[NEON] 🔍 HORIZON DEBUG: startKm = \(startKm)")
        print("[NEON] 🔍 HORIZON DEBUG: horizonWidth = \(horizonWidth)")
        print("[NEON] 🔍 HORIZON DEBUG: clampedWidth = \(clampedWidth)")
        print("[NEON] 🔍 HORIZON DEBUG: final range = [\(startKm), \(startKm + clampedWidth)]")

        var atm = Atmosphere()
        // A thin band close to the camera: [start, start + width]
        atm.range = .constant([startKm, startKm + clampedWidth])
        // Feather controls softness; small = crisper horizon
        let feather = Double(userSettings?.horizonFeather ?? 0.06)
        atm.horizonBlend = .constant(max(0.0, min(0.06, feather)))
        // Slightly lower alpha so the band doesn't overpower the ground edge
        atm.color = .constant(StyleColor(UIColor(red: 0.86, green: 0.36, blue: 0.12, alpha: 0.0))) // DISABLED: was 0.65
        atm.highColor = .constant(StyleColor(.black))
        atm.spaceColor = .constant(StyleColor(.black))
        atm.starIntensity = .constant(1.0)
        
        try? style.setAtmosphere(atm)
        print("[NEON] 🟠 Horizon start=\(startKm) km, width=\(clampedWidth) km, feather=\(feather)")

        // Double-lined roads like the mockup
        print("[NEON] 🛣️ Adding double-lined roads above land/water...")

        // Roads outer glow (widest layer for soft glow)
        var roadsGlow = LineLayer(id: roadsGlowId, source: streetsSourceId)
        roadsGlow.sourceLayer = "road"
        roadsGlow.filter = roadFilter()
        roadsGlow.minZoom = 6.0
        roadsGlow.lineColor = .constant(StyleColor(UIColor(red: 1.00, green: 0.62, blue: 0.20, alpha: 0.5))) // brighter warm amber glow
        roadsGlow.lineWidth = .expression(widthExp(mult: 3.5))
        roadsGlow.lineOpacity = .expression(opacityExp(min: 0.15, max: 0.30))
        roadsGlow.lineBlur = .constant(10.0)
        try? style.addLayer(roadsGlow, layerPosition: .above("water-override"))
        print("[NEON] ✨ roads-glow (outer) added")

        // Roads main line (bright orange outer line)
        var roadsOuter = LineLayer(id: roadsCoreId, source: streetsSourceId)
        roadsOuter.sourceLayer = "road"
        roadsOuter.filter = roadFilter()
        roadsOuter.minZoom = 6.0
        roadsOuter.lineColor = .constant(StyleColor(UIColor(red: 1.00, green: 0.75, blue: 0.30, alpha: 1.0))) // brighter orange
        roadsOuter.lineWidth = .expression(widthExp(mult: 1.5))
        roadsOuter.lineOpacity = .constant(0.95)
        roadsOuter.lineBlur = .constant(0.5)
        try? style.addLayer(roadsOuter, layerPosition: .above(roadsGlowId))
        print("[NEON] 🧡 roads-outer (main line) added")

        // Roads inner dark line (creates double-line effect)
        var roadsInner = LineLayer(id: "neon-roads-inner", source: streetsSourceId)
        roadsInner.sourceLayer = "road"
        roadsInner.filter = roadFilter()
        roadsInner.minZoom = 6.0
        roadsInner.lineColor = .constant(StyleColor(UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))) // black inner line
        roadsInner.lineWidth = .expression(widthExp(mult: 0.8))
        roadsInner.lineOpacity = .constant(0.9)
        roadsInner.lineBlur = .constant(0.0)
        try? style.addLayer(roadsInner, layerPosition: .above(roadsCoreId))
        print("[NEON] 🟫 roads-inner (dark center) added - creates double-line effect")

        // Roads puck glow (bright highlight around user position)
        var roadsPuckGlow = LineLayer(id: "neon-roads-puck-glow", source: streetsSourceId)
        roadsPuckGlow.sourceLayer = "road"
        roadsPuckGlow.filter = roadFilter()
        roadsPuckGlow.minZoom = 6.0
        roadsPuckGlow.lineColor = .constant(StyleColor(UIColor(red: 0.00, green: 1.00, blue: 1.00, alpha: 1.0))) // Cyan glow
        roadsPuckGlow.lineWidth = .expression(widthExp(mult: 2.0)) // Reduced width to avoid overwhelming roads
        roadsPuckGlow.lineOpacity = .constant(0.3) // Much lower opacity so golden roads show through
        roadsPuckGlow.lineBlur = .constant(8.0) // Reduced blur radius
        try? style.addLayer(roadsPuckGlow, layerPosition: .above("neon-roads-inner"))
        print("[NEON] ✨ roads-puck-glow added for user location highlight")

       
        // White road labels for visibility
        var roadLabels = SymbolLayer(id: "neon-road-labels", source: streetsSourceId)
        roadLabels.sourceLayer = "road_label"
        roadLabels.textField = .expression(Exp(.get) { "name" })
        roadLabels.textColor = .constant(StyleColor(.white))
        roadLabels.textSize = .constant(12.0)
        roadLabels.textHaloColor = .constant(StyleColor(.black))
        roadLabels.textHaloWidth = .constant(1.0)
        roadLabels.symbolPlacement = .constant(.line)
        roadLabels.minZoom = 12.0
        try? style.addLayer(roadLabels, layerPosition: .above("neon-roads-puck-glow"))
        print("[NEON] 🏷️ Added white road labels")

        // Enhance road colors to red-orange
        try? style.setLayerProperty(for: roadsGlowId, property: "line-color", value: "rgba(255, 100, 0, 1.0)") // Red-orange
        try? style.setLayerProperty(for: roadsCoreId, property: "line-color", value: "rgba(255, 140, 0, 1.0)") // Orange with red tint
        print("[NEON] ✨ Enhanced road colors to golden orange")

        // Apply asphalt texture to land layer (with fallback color)
        try? style.setLayerProperty(for: "land", property: "background-pattern", value: "asphalt64")
        try? style.setLayerProperty(for: "land", property: "background-color", value: "rgba(25, 30, 25, 1.0)")
        print("[NEON] 🏗️ Applied asphalt texture to land layer (fallback: dark green-gray)")

        // Green spaces (parks, grass, etc.)
        var greenSpace = FillLayer(id: "neon-greenspace", source: streetsSourceId)
        greenSpace.sourceLayer = "landuse"
        greenSpace.filter = Exp(.match) {
            Exp(.get) { "class" }
            ["park", "cemetery", "grass", "recreation_ground", "golf_course", "pitch"]
            true
            false
        }
        greenSpace.fillColor = .constant(StyleColor(UIColor(red: 0.15, green: 0.4, blue: 0.15, alpha: 1.0)))
        greenSpace.fillOpacity = .constant(0.8)
        try? style.addLayer(greenSpace, layerPosition: .above("land"))
        print("[NEON] 🌱 Added green spaces (parks, grass)")

        // Better blue water
        try? style.setLayerProperty(for: "water-override", property: "fill-color", value: "rgba(20, 60, 120, 1.0)")
        try? style.setLayerProperty(for: "water-override", property: "fill-opacity", value: 1.0)
        print("[NEON] 💙 Enhanced water to proper blue")



 


    }



    // MARK: - Expressions
    private func roadFilter() -> Exp {
        Exp(.match) {
            Exp(.get) { "class" }
            ["motorway","trunk","primary","secondary","tertiary","street","service"]
            true
            false
        }
    }
    private func widthExp(mult: Double) -> Exp {
        Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            10; 0.6 * mult
            12; 1.2 * mult
            14; 2.0 * mult
            16; 4.0 * mult
            18; 9.0 * mult
        }
    }
    private func opacityExp(min: Double, max: Double) -> Exp {
        Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            10; min
            14; (min + max) * 0.5
            18; max
        }
    }
}
