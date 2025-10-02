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

            // Preload city lights layer on background thread
            if let mapView = mapView {
                context.coordinator.preloadCityLightsLayer(mapView: mapView)
            }

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
        context.coordinator.userSettings = userSettings
        
        // Note: updateViewport removed - viewport changes now handled directly through updateCamera calls
        context.coordinator.updateUserPath(userPath)
        // Note: updateUserLocation removed - location updates handled automatically by puck
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
        var userSettings: UserSettings = UserSettings() // Store user settings for styling
        var didSetInitialCamera = false
        enum MapMode { case neon, globe }
        var mode: MapMode = .neon
        var preGlobeLocation: CLLocationCoordinate2D? // Store location before entering globe mode
        var cityLightsLoaded = false // Track if city lights layer is ready
        var cityLightsObserver: Cancelable? // Observer for city lights visibility

        // ❌ REMOVED: updateViewport - Complex function that was rarely used and caused potential conflicts
        
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
        
        
        /// ✅ KEEP: Essential for compass-based map rotation
        func updateBearing(_ bearing: Double, userLocation: CLLocationCoordinate2D) {
            //print("[map] 🧭 Updating map bearing to: \(String(format: "%.1f", bearing))°")
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
           // print("[map] 📏 Using center + padding approach (not anchor) for puck positioning...")
            
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
            
           // print("[map] ⚓ SINGLE camera update: zoom=\(zoom ?? currentCamera.zoom), bearing=\(String(format: "%.1f", bearing ?? currentCamera.bearing))°, pitch=\(pitch ?? currentCamera.pitch)°")
        }
        
        
        
        // ❌ REMOVED: updateCameraZoom - Simple wrapper that can be replaced with direct updateCamera calls
        
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
        

        /// ✅ KEEP: Essential for updating neon style when user settings change
        func reapplyNeonGridStyle(with userSettings: UserSettings) {
            print("[map] 🎨 Reapplying neon grid style - width:\(userSettings.horizonWidth) start:\(userSettings.horizonStart) feather:\(userSettings.horizonFeather)")
            guard let mapView = mapView else {
                print("[map] ❌ MapView is nil in reapplyNeonGridStyle")
                return
            }
            mapView.applyNeonGridStyle(with: userSettings)
        }

        // MARK: - Globe Mode Functions

        /// ✅ KEEP: Essential for globe mode functionality
        func toggleElectrifiedGlobe(userLocation: CLLocationCoordinate2D?) {
            switch mode {
            case .neon: enterGlobe(userLocation: userLocation)
            case .globe: exitGlobe(to: userLocation)
            }
        }

        /// Enter globe mode with smooth transition
        private func enterGlobe(userLocation: CLLocationCoordinate2D?) {
            guard let mapView = mapView else { return }

            // 0) Store current location before entering globe mode
            let currentCamera = mapView.mapboxMap.cameraState
            preGlobeLocation = userLocation ?? currentCamera.center
            print("[globe] 💾 Current camera center: \(currentCamera.center)")
            print("[globe] 💾 Stored pre-globe location: \(preGlobeLocation!)")
            print("[globe] 💾 Current zoom: \(currentCamera.zoom)")

            // 1) Enable rotate for spin-the-globe feel
            mapView.gestures.options.rotateEnabled = true

            // 2) Start the zoom out animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.startGlobeAnimation(mapView: mapView)
            }

            mode = .globe
            print("[globe] 🌍 Entered electrified globe mode")
        }

        /// Preload city lights layer asynchronously to avoid blocking main thread
        func preloadCityLightsLayer(mapView: MapView) {
            guard !cityLightsLoaded else {
                print("[lights] ℹ️ City lights already loaded, skipping")
                return
            }

            print("[lights] 🚀 Starting async preload of city lights layer...")

            // Perform heavy work on background thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak mapView] in
                guard let self = self, let mapView = mapView else { return }

                let srcId = "city-lights"
                let layerId = "city-lights-layer"

                // Check if TIFF file exists
                guard let blackMarbleURL = Bundle.main.url(forResource: "BlackMarble_2016_3km_geo", withExtension: "tif") else {
                    print("[lights] ❌ BlackMarble TIFF not found in bundle")
                    return
                }

                print("[lights] 📁 Found BlackMarble TIFF at: \(blackMarbleURL.path)")

                // Switch to main thread for MapView operations (Mapbox requires main thread)
                DispatchQueue.main.async {
                    let sourceExists = (try? mapView.mapboxMap.sourceExists(withId: srcId)) ?? false
                    if !sourceExists {
                        print("[lights] 🎯 Adding Black Marble TIF source on main thread")

                        var imageSource = ImageSource(id: srcId)
                        imageSource.url = blackMarbleURL.absoluteString

                        // Black Marble TIFF typically covers -180 to 180 longitude, -65 to 75 latitude
                        // These bounds match the actual data extent of NASA's Black Marble
                        imageSource.coordinates = [
                            [-180, 75],    // top-left (west, north)
                            [180, 75],     // top-right (east, north)
                            [180, -65],    // bottom-right (east, south)
                            [-180, -65]    // bottom-left (west, south)
                        ]

                        do {
                            try mapView.mapboxMap.addSource(imageSource)
                            print("[lights] ✅ City lights source added successfully")
                        } catch {
                            print("[lights] ❌ Failed to add source: \(error)")
                            return
                        }

                        // Add the raster layer
                        let layerExists = (try? mapView.mapboxMap.layerExists(withId: layerId)) ?? false
                        if !layerExists {
                            var rasterLayer = RasterLayer(id: layerId, source: srcId)
                            rasterLayer.rasterOpacity = .constant(0.0) // Start hidden
                            rasterLayer.rasterBrightnessMax = .constant(1.0)
                            rasterLayer.rasterBrightnessMin = .constant(0.0)
                            rasterLayer.rasterResampling = .constant(.linear) // Better interpolation at different zoom levels

                            do {
                                try mapView.mapboxMap.addLayer(rasterLayer)
                                print("[lights] ✅ City lights layer added (hidden, will show at zoom < 4)")

                                // Verify the layer was actually added
                                let layerExists = (try? mapView.mapboxMap.layerExists(withId: layerId)) ?? false
                                print("[lights] 🔍 Layer exists after adding: \(layerExists)")

                                // Get current opacity to verify initial state
                                if let opacity = try? mapView.mapboxMap.layerProperty(for: layerId, property: "raster-opacity") {
                                    print("[lights] 🔍 Initial opacity: \(opacity)")
                                }

                                // Mark as loaded
                                self.cityLightsLoaded = true

                                // Set up camera observer to control visibility
                                self.setupCityLightsVisibilityObserver(mapView: mapView)
                            } catch {
                                print("[lights] ❌ Failed to add layer: \(error)")
                            }
                        }
                    } else {
                        print("[lights] ℹ️ City lights source already exists")
                        self.cityLightsLoaded = true
                        self.setupCityLightsVisibilityObserver(mapView: mapView)
                    }
                }
            }
        }

        /// Set up observer to control city lights visibility based on zoom level
        private func setupCityLightsVisibilityObserver(mapView: MapView) {
            // Cancel existing observer if any
            cityLightsObserver?.cancel()

            cityLightsObserver = mapView.mapboxMap.onCameraChanged.observe { [weak mapView] _ in
                guard let mapView = mapView else { return }
                let camera = mapView.mapboxMap.cameraState

                // Fade in city lights from zoom 7 to 4 (fully visible at 4, fully hidden at 7)
                let targetOpacity: Double
                if camera.zoom <= 4.0 {
                    targetOpacity = 1.0  // Fully visible at zoom 4 and below
                } else if camera.zoom >= 7.0 {
                    targetOpacity = 0.0  // Fully hidden at zoom 7 and above
                } else {
                    // Linear interpolation between zoom 4 and 7
                    // At zoom 4: opacity = 1.0
                    // At zoom 7: opacity = 0.0
                    targetOpacity = 1.0 - ((camera.zoom - 4.0) / 3.0)
                }

                if (try? mapView.mapboxMap.layerExists(withId: "city-lights-layer")) == true {
                    try? mapView.mapboxMap.setLayerProperty(
                        for: "city-lights-layer",
                        property: "raster-opacity",
                        value: targetOpacity
                    )

                    // Debug logging (only log when zoom is in the transition range)
                    if camera.zoom >= 3.5 && camera.zoom <= 7.5 {
                        print("[lights] 💡 Zoom: \(String(format: "%.2f", camera.zoom)), opacity: \(String(format: "%.2f", targetOpacity))")
                    }
                }
            }

            print("[lights] 👁️ City lights visibility observer set up (fade in from zoom 7→4)")
        }

        /// Helper function to start the globe zoom animation
        private func startGlobeAnimation(mapView: MapView) {
            let preZoomCamera = mapView.mapboxMap.cameraState
            let currentCenter = preGlobeLocation ?? preZoomCamera.center

            print("[globe] 🎯 Starting globe mode from current location: (\(String(format: "%.4f", currentCenter.latitude)), \(String(format: "%.4f", currentCenter.longitude)))")

            // Center the globe to show your continent properly
            // Use your actual longitude but put it at equator for good global view
            let globeCenter = CLLocationCoordinate2D(
                latitude: 0.0, // Equator for balanced north/south view
                longitude: currentCenter.longitude // Your longitude to show your continent
            )

            let globePadding = UIEdgeInsets(
                top: dynamicTopPadding * 1.5,
                left: 0,
                bottom: 0,
                right: 0
            )

            let spaceCamera = CameraOptions(
                center: globeCenter,
                padding: globePadding, // Preserve existing padding
                zoom: 1.5, // Slightly closer zoom to avoid extreme distortion
                bearing: 0.0, // North at top
                pitch: 0 // Flat view for globe
            )

            // Start animation with progress logging
            let progressObserver = mapView.mapboxMap.onCameraChanged.observe { [weak mapView] _ in
                guard let mapView = mapView else { return }
                let camera = mapView.mapboxMap.cameraState

                // Log animation progress (city lights visibility is now handled by separate observer)
                if Int(camera.zoom * 10) % 10 == 0 {
                   // print("[globe] 📍 Animation progress - Lat: \(String(format: "%.4f", camera.center.latitude)), Lon: \(String(format: "%.4f", camera.center.longitude)), Zoom: \(String(format: "%.2f", camera.zoom))")
                }
            }

            mapView.camera.fly(to: spaceCamera, duration: 10.0, curve: .easeOut) { [weak self] _ in
                progressObserver.cancel()
                print("[globe] ✅ Globe animation complete")

                if let finalCamera = self?.mapView?.mapboxMap.cameraState {
                    print("[globe] 🏁 Final position - Lat: \(String(format: "%.4f", finalCamera.center.latitude)), Lon: \(String(format: "%.4f", finalCamera.center.longitude)), Zoom: \(String(format: "%.2f", finalCamera.zoom))")
                }
            }
        }

 
        /// Exit globe mode and return to neon grid view with smooth animation
        private func exitGlobe(to userLocation: CLLocationCoordinate2D?) {
            guard let mapView = mapView else { return }

            print("[globe] 🛑 All movement timers stopped before transition")

            // 1) Clean up globe mode resources
            cleanupGlobeResources(mapView: mapView)

            // 2) Animate back to pre-globe location with defaults
            let targetLocation = userLocation ?? preGlobeLocation ?? mapView.mapboxMap.cameraState.center
            animateBackToDefaults(mapView: mapView, targetLocation: targetLocation)
        }

        // MARK: - Globe Helper Functions
        private var rotationTimer: Timer?
        private var currentRotationBearing: Double = 0.0

 



        /// Clean up globe mode resources
        private func cleanupGlobeResources(mapView: MapView) {
            // DON'T remove city lights layer - let the observer handle visibility based on zoom
            // The layer should persist and fade in/out automatically as user zooms
            print("[globe] ℹ️ Keeping city lights layer (will auto-hide at zoom > 7)")

            // Back to Mercator projection
           // try? mapView.mapboxMap.setProjection(StyleProjection(name: .mercator))

            // Reset gesture options
            mapView.gestures.options.rotateEnabled = false

            print("[globe] 🧹 Globe mode exited (city lights remain active)")
        }

        /// Animate back to defaults with proper transition
        private func animateBackToDefaults(mapView: MapView, targetLocation: CLLocationCoordinate2D) {
            print("[globe] 🎯 Animating back to defaults at location: (\(String(format: "%.4f", targetLocation.latitude)), \(String(format: "%.4f", targetLocation.longitude)))")

            // Use defaults from the coordinator parameters
            let defaultCamera = CameraOptions(
                center: targetLocation,
                padding: UIEdgeInsets(
                    top: dynamicTopPadding,
                    left: 0,
                    bottom: dynamicBottomPadding,
                    right: 0
                ),
                zoom: defaultZoom,  // Use app default zoom
                bearing: 0,         // Reset to north up
                pitch: defaultPitch // Use app default pitch
            )

            // Animate back with proper duration
            mapView.camera.fly(to: defaultCamera, duration: 8.0, curve: .easeInOut) { [weak self] _ in
                guard let self = self else { return }

                // Reset atmosphere to defaults
                var defaultAtm = Atmosphere()
                defaultAtm.range = .constant([2.0, 2.4])
                defaultAtm.color = .constant(StyleColor(UIColor(red: 0.86, green: 0.36, blue: 0.12, alpha: 0.0)))
                defaultAtm.highColor = .constant(StyleColor(.black))
                defaultAtm.spaceColor = .constant(StyleColor(.black))
                defaultAtm.horizonBlend = .constant(0.06)
                defaultAtm.starIntensity = .constant(1.0)
                try? mapView.mapboxMap.setAtmosphere(defaultAtm)

                // Restore neon style
                mapView.applyNeonGridStyle(with: self.userSettings)

                // Reset mode
                self.mode = .neon

                print("[globe] ✅ Successfully returned to neon mode with defaults")
            }
        }

    }


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
 
    private let demSourceId = "mapbox-dem"

    private init() {}

    func apply(to mapView: MapView, userSettings: UserSettings? = nil) {
        let style = mapView.mapboxMap.style
        print("[NEON] 🔥 Applying neon grid with REAL sky/atmosphere + (optional) terrain")

        // 0) Hide unnecessary layers but keep the ones we want to style
        let initialLayers = style.allLayerIdentifiers
        print("[NEON] 📋 Found \(initialLayers.count) existing layers to process")
        var hiddenCount = 0
        let layersToKeep = ["user-path", "water", "landuse", "national-park", "building", "puck", "city-lights-layer", "land"]

        // AGGRESSIVE: Hide ALL layers that might show white, force visibility none for everything except what we explicitly want
        initialLayers.forEach { id in
            let shouldKeep = layersToKeep.contains(id.id) ||
                           id.id.hasPrefix("neon-") ||
                           id.id.hasPrefix("city-lights") ||  // Keep city lights layer
                           id.id.contains("label") ||
                           id.id == "sky" ||
                           id.id == "land"  // ALWAYS keep land layer so we can set its background-color

            if !shouldKeep {
                // Force visibility off AND set opacity to 0 for double protection
                try? style.setLayerProperty(for: id.id, property: "visibility", value: "none")
                try? style.setLayerProperty(for: id.id, property: "fill-opacity", value: 0.0)
                try? style.setLayerProperty(for: id.id, property: "line-opacity", value: 0.0)
                try? style.setLayerProperty(for: id.id, property: "background-opacity", value: 0.0)
                hiddenCount += 1
            }
        }
        print("[NEON] 👻 Aggressively hid \(hiddenCount) layers with visibility=none AND opacity=0")

        // 2) Streets source (for neon roads)
        if !((try? style.sourceExists(withId: streetsSourceId)) ?? false) {
            var streets = VectorSource(id: streetsSourceId)
            streets.url = "mapbox://mapbox.mapbox-streets-v8"
            try? style.addSource(streets)
            print("[NEON] 🧭 Added streets source (v8)")
        }
        print("[NEON] ✅ streets exists? \((try? style.sourceExists(withId: streetsSourceId)) ?? false)")



        // REMOVED: black-sky background layer - not needed since land is transparent
        // Default Mapbox background should be sufficient
        print("[NEON] 🌌 Relying on default background (no custom black-sky layer)")


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

        // TEMPORARILY COMMENTED OUT ATMOSPHERE TO TEST WHITE LAND ISSUE
        
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
        
        print("[NEON] ⚠️ ATMOSPHERE TEMPORARILY DISABLED FOR TESTING")

        // Land layer will be styled below with background-color (it's a background type layer)
        print("[NEON] 🔍 Land layer will be styled as background layer (not fill)")

        // Double-lined roads like the mockup
        print("[NEON] 🛣️ Adding double-lined roads above land/water...")

        // Log all available layers and classes once
        logAllLayersAndClasses(style: mapView.mapboxMap)

        // Debug land-related layers specifically
        debugLandLayers(style: mapView.mapboxMap)

        // Roads outer glow (widest layer for soft glow)
        var roadsGlow = LineLayer(id: roadsGlowId, source: streetsSourceId)
        roadsGlow.sourceLayer = "road"
        roadsGlow.filter = roadFilter()
        roadsGlow.minZoom = 1.0  // Start earlier for smooth transition
        roadsGlow.lineColor = .constant(StyleColor(UIColor(red: 1.00, green: 0.62, blue: 0.20, alpha: 0.8))) // brighter warm amber glow
        roadsGlow.lineWidth = .expression(widthExp(mult: 3.5))
        roadsGlow.lineOpacity = .expression(opacityExp(min: 0.0, max: 0.30))  // Fade in from 0
        roadsGlow.lineBlur = .constant(10.0)
        try? style.addLayer(roadsGlow, layerPosition: .above("land"))
        print("[NEON] ✨ roads-glow (outer) added")

        // Roads main line (bright orange outer line)
        var roadsOuter = LineLayer(id: roadsCoreId, source: streetsSourceId)
        roadsOuter.sourceLayer = "road"
        roadsOuter.filter = roadFilter()
        roadsOuter.minZoom = 1.0  // Start earlier for smooth transition
        roadsOuter.lineColor = .constant(StyleColor(UIColor(red: 1.00, green: 0.75, blue: 0.30, alpha: 1.0))) // brighter orange
        roadsOuter.lineWidth = .expression(widthExp(mult: 1.5))
        roadsOuter.lineOpacity = .expression(Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            4; 0.95    // Invisible at zoom 4
            6; 0.95   // Full opacity at zoom 6
            18; 0.95
        })
        roadsOuter.lineBlur = .constant(0.5)
        try? style.addLayer(roadsOuter, layerPosition: .above(roadsGlowId))
        print("[NEON] 🧡 roads-outer (main line) added")

        // Roads inner dark line (creates double-line effect)
        var roadsInner = LineLayer(id: "neon-roads-inner", source: streetsSourceId)
        roadsInner.sourceLayer = "road"
        roadsInner.filter = roadFilter()
        roadsInner.minZoom = 1.0  // Start earlier for smooth transition
        roadsInner.lineColor = .constant(StyleColor(UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))) // black inner line
        roadsInner.lineWidth = .expression(widthExp(mult: 0.8))
        roadsInner.lineOpacity = .expression(Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            4; 0.9    // Invisible at zoom 4
            6; 0.9    // Full opacity at zoom 6
            18; 0.9
        })
        roadsInner.lineBlur = .constant(0.0)
        try? style.addLayer(roadsInner, layerPosition: .above(roadsCoreId))
        print("[NEON] 🟫 roads-inner (dark center) added - creates double-line effect")

        // Roads puck glow (bright highlight around user position)
        var roadsPuckGlow = LineLayer(id: "neon-roads-puck-glow", source: streetsSourceId)
        roadsPuckGlow.sourceLayer = "road"
        roadsPuckGlow.filter = roadFilter()
        roadsPuckGlow.minZoom = 1.0  // Start earlier for smooth transition
        roadsPuckGlow.lineColor = .constant(StyleColor(UIColor(red: 0.00, green: 1.00, blue: 1.00, alpha: 1.0))) // Cyan glow
        roadsPuckGlow.lineWidth = .expression(widthExp(mult: 2.0)) // Reduced width to avoid overwhelming roads
        roadsPuckGlow.lineOpacity = .expression(Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            4; 0.3    // Invisible at zoom 4
            6; 0.3    // Full opacity at zoom 6
            18; 0.3
        })
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

        // Style the actual existing layers directly
        // The "land" layer IS the background layer (type: "background")
        // Set it to black instead of white to fix the white land issue at low zoom
        do {
            try style.setLayerProperty(for: "land", property: "background-color", value: "rgba(0, 0, 0, 1.0)")
            print("[NEON] 🖤 Set land (background) layer to black")

            // Verify it was set
            if let bgColor = try? style.layerProperty(for: "land", property: "background-color") {
                print("[NEON] 🔍 Verified land background-color: \(bgColor)")
            }
        } catch {
            print("[NEON] ❌ Failed to set land background-color: \(error)")
        }

        // Also try setting it with a zoom expression to ensure it's black at ALL zoom levels
        try? style.setLayerProperty(for: "land", property: "background-color", value: [
            "interpolate", ["linear"], ["zoom"],
            0, "rgba(0, 0, 0, 1.0)",
            22, "rgba(0, 0, 0, 1.0)"
        ])
        print("[NEON] 🖤 Set land background-color with zoom expression (always black)")

        // Also hide any potential base map layers that might show white
        let baseLayers = ["land-structure-polygon", "land-structure-line", "aeroway-polygon", "aeroway-line"]
        for layerId in baseLayers {
            try? style.setLayerProperty(for: layerId, property: "fill-opacity", value: [
                "interpolate", ["linear"], ["zoom"],
                0, 0.0,    // Transparent at all zoom levels
                15, 0.0
            ])
            try? style.setLayerProperty(for: layerId, property: "line-opacity", value: [
                "interpolate", ["linear"], ["zoom"],
                0, 0.0,    // Transparent at all zoom levels
                15, 0.0
            ])
        }

        // Force hide any other potential white layers
        let potentialWhiteLayers = ["admin-0-boundary-bg", "admin-1-boundary-bg"]
        for layerId in potentialWhiteLayers {
            try? style.setLayerProperty(for: layerId, property: "line-opacity", value: 0.0)
            try? style.setLayerProperty(for: layerId, property: "visibility", value: "none")
        }

        print("[NEON] 🌍 Made all land layers fully transparent with zoom expressions")

        // Water layer - keep blue water visible
        try? style.setLayerProperty(for: "water", property: "fill-color", value: "rgba(20, 60, 120, 1.0)")
        try? style.setLayerProperty(for: "water", property: "fill-opacity", value: 1.0)
        print("[NEON] 💧 Styled water layer blue")

        // Just style the existing landuse layer - don't make it transparent!
        // Green areas (parks, forests, etc) in landuse
        try? style.setLayerProperty(for: "landuse", property: "fill-color", value: [
            "case",
            ["in", ["get", "class"], ["literal", ["park", "cemetery", "grass", "recreation_ground", "golf_course", "pitch", "forest", "wood", "nature_reserve"]]],
            "rgba(0, 200, 0, 1.0)", // Bright green for green spaces
            "rgba(0, 0, 0, 0.0)"    // Transparent for other landuse (residential, commercial, etc)
        ])
        try? style.setLayerProperty(for: "landuse", property: "fill-opacity", value: 1.0)
        print("[NEON] 🏞️ Styled landuse layer: green for parks/forests, transparent for other uses")

        // National parks - force bright green at ALL zoom levels
        try? style.setLayerProperty(for: "national-park", property: "fill-color", value: "rgba(0, 180, 0, 1.0)")
        try? style.setLayerProperty(for: "national-park", property: "fill-opacity", value: 1.0)
        print("[NEON] 🌳 Styled national-park layer bright green")

        // Buildings
        try? style.setLayerProperty(for: "building", property: "fill-color", value: "rgba(40, 40, 40, 1.0)")
        try? style.setLayerProperty(for: "building", property: "fill-opacity", value: 0.8)
        print("[NEON] 🏢 Styled building layer")

        // REMOVED: neon-greenspace layer - we now style the existing landuse layer directly
        // This eliminates redundancy and potential conflicts

        // Water override - keep blue water
        try? style.setLayerProperty(for: "water-override", property: "fill-color", value: "rgba(20, 60, 120, 1.0)")
        try? style.setLayerProperty(for: "water-override", property: "fill-opacity", value: 1.0)
        print("[NEON] 💙 Enhanced water to proper blue")



 


    }



    // MARK: - Expressions
    private func roadFilter() -> Exp {
        // Include ALL possible road classes for complete coverage
        let includedClasses = [
            // Main roads
            "motorway", "trunk", "primary", "secondary", "tertiary", "street", "service",
            // Paths and trails
            "path", "trail", "cycleway", "piste", "steps", "pedestrian", "footway",
            // Other road types
            "simple", "rail", "minor", "major", "link", "residential", "unclassified"
        ]
        print("[layer] 🛣️ Road filter includes ALL types: \(includedClasses.count) classes")

        return Exp(.match) {
            Exp(.get) { "class" }
            includedClasses
            true
            false
        }
    }
    private func widthExp(mult: Double) -> Exp {
        Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            4; 0.3 * mult   // Very thin at low zoom
            6; 0.6 * mult   // Start visible
            10; 0.8 * mult
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
            4; 0.0          // Invisible at zoom 4
            6; max * 0.7    // Fade in by zoom 6
            10; max         // Full opacity by zoom 10
            18; max
        }
    }

    // Log all available layers and their source layers/classes
    private func logAllLayersAndClasses(style: StyleManager) {
        print("[layer] 🔍 === ALL MAPBOX LAYERS AND CLASSES ===")

        let allLayers = style.allLayerIdentifiers
        print("[layer] 📋 Total layers found: \(allLayers.count)")

        for layerInfo in allLayers {
            let layerId = layerInfo.id
            let layerType = layerInfo.type

            // Just log basic layer information without trying to access complex properties
            print("[layer] 🎨 \(layerId) | type: \(layerType)")
        }

        print("[layer] ✅ === END LAYER DUMP ===")

        // Also log available sources
        print("[layer] 📡 === ALL SOURCES ===")
        let allSources = style.allSourceIdentifiers
        for sourceInfo in allSources {
            print("[layer] 📡 Source: \(sourceInfo.id) | type: \(sourceInfo.type)")
        }
        print("[layer] ✅ === END SOURCE DUMP ===")
    }

    // Debug land-related layers that might be causing white curves
    private func debugLandLayers(style: StyleManager) {
        print("[layer] 🌍 === LAND LAYER DEBUG ===")

        let landRelatedNames = ["land", "landuse", "landcover", "background", "natural"]

        for layerName in landRelatedNames {
            if (try? style.layerExists(withId: layerName)) == true {
                print("[layer] 🌍 Found layer: \(layerName)")

                // Try to get current properties
                do {
                    if let fillColor = try? style.layerProperty(for: layerName, property: "fill-color") {
                        print("[layer] 🎨 \(layerName) fill-color: \(fillColor)")
                    }
                    if let bgColor = try? style.layerProperty(for: layerName, property: "background-color") {
                        print("[layer] 🎨 \(layerName) background-color: \(bgColor)")
                    }
                    if let visibility = try? style.layerProperty(for: layerName, property: "visibility") {
                        print("[layer] 👁️ \(layerName) visibility: \(visibility)")
                    }
                } catch {
                    print("[layer] ❌ Failed to get properties for \(layerName): \(error)")
                }
            } else {
                print("[layer] 🚫 Layer not found: \(layerName)")
            }
        }

        print("[layer] ✅ === END LAND DEBUG ===")
    }

}
