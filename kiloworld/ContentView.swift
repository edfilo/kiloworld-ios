//
//  ContentView_New.swift
//  kiloworld
//
//  Refactored ContentView using extracted components
//  Created by Claude on 9/22/25.
//

import SwiftUI
import Metal
import MetalKit
import FirebaseDatabase
import MapboxMaps
import Turf
import CoreLocation
import os

struct ContentView: View {
    @State private var messageText = ""
    @State private var currentXid: String? = nil
    @State private var sessionXid: String? = nil
    @State private var statusText = ""
    @State private var chatMessages: [ChatMessage] = []
    @State private var generatedImages: [String] = []
    @State private var isListening = false
    @State private var depthAmount: Float = UserDefaults.standard.float(forKey: "depthAmount") != 0 ? UserDefaults.standard.float(forKey: "depthAmount") : 0.9
    @State private var globalSize: Float = UserDefaults.standard.float(forKey: "globalSize") != 0 ? UserDefaults.standard.float(forKey: "globalSize") : 0.1
    
    // Map controls - trigger map updates
    @State private var mapPitch: Double = 65.0  // Start at minimum pitch
    @State private var baseZoom: Double = 0.5   // User-controlled base zoom
    @State private var mapBearing: Double = 0.0
    @State private var particlesHidden: Bool = false
    @State private var mapUpdateTrigger: Bool = false
    @State private var gestureStartZoom: Double = 0.5
    
    // Actual camera values from Mapbox
    @State private var actualZoom: Double = 10.0
    @State private var actualPitch: Double = 85.0
    @State private var actualCenter: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 40.7589, longitude: -73.9851)
    @State private var actualBearing: Double = 0.0
    
    // Energy tracking (total walking distance)
    @State private var totalWalkingDistance: Double = 0.0
    
    // Flag to allow explicit viewport updates (e.g. location button, initial setup)
    @State private var allowViewportUpdate: Bool = true // Start true to apply initial settings
    
    // User modal state
    @State private var showUserModal: Bool = false
    
    // Location manager
    @StateObject private var locationManager = LocationManager()
    
    // Journey path storage - persistent across app launches
    @StateObject private var pathStorage = JourneyPathStorage()
    
    // User settings for hologram and UI controls
    @StateObject private var userSettings = UserSettings()
    
    // Path tracking
    @State private var isTrackingPath: Bool = false
    
    // Viewport for reactive camera updates - will be set to user location when available
    @State private var viewport: Viewport = .camera(center: CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0), zoom: 16.0, bearing: 0.0, pitch: 85.0) // Will be updated with defaultPitch on load
    
    // Track active sky touches from SkyGateRecognizer
    @State private var activeSkyTouches: Int = 0
    
    // Compass heading tracking
    @State private var compassHeading: Double = 0.0
    @State private var showCompassBeam: Bool = false
    @State private var isCompassRotating: Bool = false
    
    // Auto-centering timer (like Pokemon Go)
    @State private var lastUserInteraction: Date = Date()
    @State private var autoCenterTimer: Timer?
    
    // Latest AI message for typewriter display
    @State private var latestAIMessage: String = ""
    
    // Dynamic camera settings with persistence
    @State private var dynamicTopPadding: Double = UserDefaults.standard.double(forKey: "dynamicTopPadding") != 0 ? UserDefaults.standard.double(forKey: "dynamicTopPadding") : 200.0
    @State private var dynamicBottomPadding: Double = UserDefaults.standard.double(forKey: "dynamicBottomPadding") != 0 ? UserDefaults.standard.double(forKey: "dynamicBottomPadding") : 0.0
    @State private var defaultPitch: Double = UserDefaults.standard.double(forKey: "defaultPitch") != 0 ? UserDefaults.standard.double(forKey: "defaultPitch") : 85.0
    @State private var defaultZoom: Double = UserDefaults.standard.double(forKey: "defaultZoom") != 0 ? UserDefaults.standard.double(forKey: "defaultZoom") : 16.0
    
    // Reference to map coordinator for animations
    @State private var mapCoordinator: NeonGridMapView.Coordinator?
    
    // Reference to hologram coordinator for SkyGate control
    @State private var hologramCoordinator: HologramMetalView.HologramCoordinator?
    
    // Puck screen position for particle emission
    @State private var puckScreenPosition: CGPoint = CGPoint(x: 0, y: 0)
    
    // Create MetalWavetableSynth once for sharing between components
    @State private var metalSynth: MetalWavetableSynth? = {
        // Initialize synth immediately so it's available when map loads
        if let device = MTLCreateSystemDefaultDevice() {
            print("🔧 Creating MetalWavetableSynth early for SkyGate")
            return MetalWavetableSynth(device: device)
        }
        return nil
    }()
    
    private var database = Database.database().reference()
    
    private var optimalPitch: Double {
        // Simple zoom-to-pitch mapping
        // Below 5: always 65°
        // 5-6: linear interpolation from 65° to 85°
        // Above 6: always 85°
        
        let zoom = actualZoom
        let pitch: Double
        
        if zoom <= 5.0 {
            pitch = 65.0
        } else if zoom >= 6.0 {
            pitch = 85.0
        } else {
            // Linear interpolation between 5-6 zoom
            let t = (zoom - 5.0) / (6.0 - 5.0) // 0.0 to 1.0
            pitch = 65.0 + (t * (85.0 - 65.0)) // 65° to 85°
        }
        
        print("[map] 🎯 ZOOM-TO-PITCH: zoom=\(String(format: "%.2f", zoom)), optimal_pitch=\(String(format: "%.1f", pitch))°")
        return pitch
    }
    
    // Neon Grid MapView using UIKit approach
    private var mapboxMapView: some View {
        NeonGridMapView(
            viewport: $viewport,
            allowViewportUpdate: allowViewportUpdate,
            userPath: pathStorage.currentPath,
            userLocation: locationManager.currentLocation?.coordinate,
            onCameraChanged: { cameraState in
                // Update actual camera values for debug display
                actualZoom = cameraState.zoom
                actualPitch = cameraState.pitch
                actualCenter = cameraState.center
                actualBearing = cameraState.bearing
                
                // Update puck screen position for hologram particle emission
                if let mapCoordinator = mapCoordinator,
                   let puckPosition = mapCoordinator.getPuckScreenPosition() {
                    puckScreenPosition = puckPosition
                }
                
                // IMPORTANT: Update viewport to match actual camera to prevent snap-back
                // BUT don't update during compass rotation as it will override anchor point
                if !allowViewportUpdate && !isCompassRotating {
                    viewport = .camera(
                        center: cameraState.center,
                        zoom: cameraState.zoom,
                        bearing: cameraState.bearing,
                        pitch: cameraState.pitch
                    )
                }
                
                // DISABLED: Pitch adjustment was creating infinite loop and preventing anchor positioning
                // TODO: Re-implement pitch adjustment without infinite feedback loop
                // let optimalPitch = self.optimalPitch
                // let pitchDifference = abs(cameraState.pitch - optimalPitch)
            },
            onMapLoaded: {
                print("[map] 🗺️ Neon Grid Map loaded - Setting up SkyGateRecognizer")
                // We'll set up SkyGateRecognizer in the UIViewRepresentable
            },
            metalSynth: metalSynth,
            onSkyTouchCountChanged: { count in
                activeSkyTouches = count
            },
            coordinator: $mapCoordinator,
            hologramCoordinator: hologramCoordinator,
            onUserInteraction: {
                resetAutoCenter()
            },
            dynamicTopPadding: dynamicTopPadding,
            dynamicBottomPadding: dynamicBottomPadding,
            defaultPitch: defaultPitch,
            defaultZoom: defaultZoom
        )
    }
    
    var body: some View {
        ZStack {
            // Map layer
            mapboxMapView
                .ignoresSafeArea()
            
            // Debug overlay and controls
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PARTICLES: \(String(format: "%.0f", userSettings.hologramParticleCount))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.pink)
                        Text("EMISSION: \(String(format: "%.2f", userSettings.hologramEmissionDensity))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.pink)
                        Text("ZOOM: \(String(format: "%.2f", actualZoom))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white)
                        Text("SYNTH: \(activeSkyTouches) notes")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
                    
                    Spacer()
                }
                Spacer()
            }
            .padding(.leading, 12)
            
            // User icon button - positioned independently at top right
            VStack {
                HStack {
                    Spacer()
                    Button(action: { showUserModal = true }) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.white)
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Circle())
                }
                Spacer()
            }
            .padding(.top, 5)
            .padding(.trailing, 5)
            
            // Hide Mapbox logo with overlay
            VStack {
                Spacer()
                HStack {
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: 80, height: 20)
                        .cornerRadius(4)
                    Spacer()
                }
                .padding(.bottom, 8)
                .padding(.leading, 8)
            }
            
            // Gradient mask that fades map from transparent to black at bottom
            VStack(spacing: 0) {
                Spacer()
                
                // Gradient overlay that masks map behind chat area and extends to screen bottom
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),          // Fully transparent at top
                        .init(color: .clear, location: 0.3),          // Stay transparent
                        .init(color: .black.opacity(0.1), location: 0.5), // Start fading
                        .init(color: .black.opacity(0.4), location: 0.7), // More opacity
                        .init(color: .black.opacity(0.8), location: 0.9), // Almost opaque
                        .init(color: .black, location: 1.0)           // Fully opaque at bottom
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false) // Don't intercept touches
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Fill entire screen
            .ignoresSafeArea(.all) // Extend to absolute screen edges
            
            // Chat interface positioned 5px from safe areas
            VStack {
                Spacer()
                    .allowsHitTesting(false) // Let map handle touches in empty area above chat
                
                // Chat interface with latest messages above controls
                ChatView(
                    messageText: $messageText,
                    chatMessages: $chatMessages,
                    statusText: $statusText,
                    isListening: $isListening,
                    sessionXid: $sessionXid,
                    currentXid: $currentXid,
                    generatedImages: $generatedImages,
                    onLocationTapped: {
                        print("[map] 📍 ZOOM TO CURRENT LOCATION")
                        zoomToUserLocation()
                    },
                    onLatestMessageChanged: { message in
                        latestAIMessage = message
                        print("[typewriter] 📨 Latest AI message updated: \"\(String(message.prefix(50)))...\"")
                    }
                )
                .frame(height: chatMessages.isEmpty ? 75 : 250) // Compact when empty
                .padding(.horizontal, 5) // 5px from left/right safe areas
                .padding(.bottom, 5) // 5px from bottom safe area
            }
            
            // Compass beam overlay - shows direction you're facing
            CompassBeamView(
                heading: compassHeading,
                isVisible: showCompassBeam
            )
            .allowsHitTesting(false) // Don't block map touches
            
            // Typewriter message display in the sky
            TypewriterMessageView(latestMessage: latestAIMessage)
            .allowsHitTesting(false) // Don't block map touches
            
            // Hologram Metal view - always visible, no touch blocking
            HologramMetalView(
                depthAmount: depthAmount,
                globalSize: globalSize,
                metalSynth: metalSynth,
                userSettings: userSettings,
                puckScreenPosition: puckScreenPosition,
                coordinator: $hologramCoordinator
            )
            .allowsHitTesting(false) // Disable touch to let map/skygate handle touches
            .opacity(0.8) // Slightly transparent so map is visible behind
        }
        .sheet(isPresented: $showUserModal) {
            UserModalView(
                pathStorage: pathStorage, 
                mapCoordinator: mapCoordinator,
                userLocation: locationManager.currentLocation?.coordinate,
                dynamicTopPadding: $dynamicTopPadding,
                dynamicBottomPadding: $dynamicBottomPadding,
                defaultPitch: $defaultPitch,
                defaultZoom: $defaultZoom,
                globalSize: $globalSize,
                depthAmount: $depthAmount,
                userSettings: userSettings,
                generatedImages: $generatedImages,
                sessionXid: $sessionXid
            )
        }
        .onAppear {
            print("[map] 🏁 App appeared - requesting location permission")
            locationManager.requestLocationPermission()
            
            // Update viewport to use persistent default settings
            viewport = .camera(
                center: CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0),
                zoom: defaultZoom,
                bearing: 0.0,
                pitch: defaultPitch
            )
            print("[settings] 📐 Updated initial viewport: zoom=\(defaultZoom), pitch=\(defaultPitch)°")
            
            // MetalWavetableSynth is now created early during initialization
            print("🔧 MetalWavetableSynth status: \(metalSynth != nil ? "✅ Available" : "❌ Failed")")
            
            // Connect storage to location manager
            locationManager.pathStorage = pathStorage
            
            // Set up course tracking for map bearing
            locationManager.onCourseUpdate = { course in
                updateMapBearing(course)
            }
            
            // Set up compass heading tracking for blue beam AND live map rotation
            locationManager.onHeadingUpdate = { heading in
                updateCompassHeading(heading)
                updateMapBearingFromCompass(heading)
            }
            
            // Set up location updates for auto-centering timer
            locationManager.onLocationUpdate = { coordinate in
                checkAutoCenterTimer(userLocation: coordinate)
            }
            
            // Start the auto-center timer
            startAutoCenterTimer()
            
            setupAlwaysOnPathTracking()
            
            // Add initial journey message to chat
            if chatMessages.isEmpty {
                chatMessages.append(ChatMessage(role: "assistant", content: "welcome to the kiloverse! what sparks your curiosity?"))
            }
            
            // Try to start at user location if available
            if let userLocation = locationManager.currentLocation {
                print("[map] 📍 Starting at user location using anchor-based positioning")
                // Wait for coordinator to be available, then use anchor-based positioning
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let coordinator = mapCoordinator {
                        coordinator.updateCamera(
                            userLocation: userLocation.coordinate,
                            zoom: defaultZoom,
                            bearing: 0.0,
                            pitch: defaultPitch,
                            duration: 1.0
                        )
                    }
                }
            }
        }
        .onDisappear {
            // Clean up timer
            autoCenterTimer?.invalidate()
            autoCenterTimer = nil
            print("[map] 🗑️ Cleaned up auto-center timer")
        }
        .onChange(of: currentXid) { oldValue, newValue in
            if let xid = newValue {
                setupFirebaseListeners(xid: xid)
            }
        }
        .onChange(of: locationManager.currentLocation) { oldValue, newValue in
            // When location becomes available for the first time, use anchor-based positioning
            if oldValue == nil && newValue != nil {
                print("[map] 📍 Location became available, using anchor-based positioning")
                if let coordinator = mapCoordinator {
                    coordinator.updateCamera(
                        userLocation: newValue!.coordinate,
                        zoom: defaultZoom,
                        bearing: 0.0,
                        pitch: defaultPitch,
                        duration: 1.0
                    )
                }
            }
        }
        .onChange(of: dynamicTopPadding) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "dynamicTopPadding")
            print("[settings] 💾 Saved dynamicTopPadding: \(newValue)")
        }
        .onChange(of: dynamicBottomPadding) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "dynamicBottomPadding")
            print("[settings] 💾 Saved dynamicBottomPadding: \(newValue)")
        }
        .onChange(of: defaultPitch) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "defaultPitch")
            print("[settings] 💾 Saved defaultPitch: \(newValue)")
        }
        .onChange(of: defaultZoom) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "defaultZoom")
            print("[settings] 💾 Saved defaultZoom: \(newValue)")
        }
        .onChange(of: globalSize) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "globalSize")
            print("[settings] ✨ Saved globalSize: \(String(format: "%.2f", newValue))")
        }
        .onChange(of: depthAmount) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "depthAmount")
            print("[settings] 🏔️ Saved depthAmount: \(String(format: "%.2f", newValue))")
        }
    }
    
    // MARK: - Functions
    
    private func updateMapBearing(_ course: Double) {
        // Update map bearing to match walking direction using single camera update
        if let coordinator = mapCoordinator, let userLocation = locationManager.currentLocation {
            coordinator.updateBearing(course, userLocation: userLocation.coordinate)
        }
    }
    
    private func updateCompassHeading(_ heading: Double) {
        // Update compass beam to show direction you're facing
        compassHeading = heading
        // Only show compass beam when you're actively moving
        showCompassBeam = (locationManager.currentLocation?.speed ?? 0) > 0.3
        print("[compass] 🧭 Compass beam updated to: \(String(format: "%.1f", heading))°, visible: \(showCompassBeam)")
    }
    
    private func updateMapBearingFromCompass(_ heading: Double) {
        // Live rotate map based on compass heading (which direction device is pointing)
        if let coordinator = mapCoordinator, let userLocation = locationManager.currentLocation {
            isCompassRotating = true
            coordinator.updateBearingWithUserLocation(heading, userLocation: userLocation.coordinate)
            print("[compass] 🗺️ Live rotating map to compass heading: \(String(format: "%.1f", heading))°")
            
            // Reset flag after rotation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isCompassRotating = false
            }
        }
    }
    
    private func centerMapOnUser(_ coordinate: CLLocationCoordinate2D) {
        // Center map on user like location button (25% from bottom)
        guard let coordinator = mapCoordinator else { return }
        
        // Use the same animation as location button
        coordinator.animateToLocation(coordinate)
        
        print("[location] 🎯 Auto-centering map on user location: \(coordinate)")
    }
    
    private func startAutoCenterTimer() {
        // Start timer that checks every 2 seconds if we should auto-center
        autoCenterTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            checkAutoCenterCondition()
        }
        print("[map] ⏰ Started auto-center timer (12s timeout)")
    }
    
    private func checkAutoCenterTimer(userLocation: CLLocationCoordinate2D) {
        // Just store the latest user location for potential centering
        // The timer will handle the actual centering logic
    }
    
    private func checkAutoCenterCondition() {
        let timeSinceLastInteraction = Date().timeIntervalSince(lastUserInteraction)
        
        // If 12 seconds have passed since last user interaction, auto-center
        if timeSinceLastInteraction >= 12.0, let userLocation = locationManager.currentLocation {
            print("[map] ⏰ 12 seconds elapsed, auto-centering on user location")
            
            // Use the full location button animation (which properly sets up anchor point)
            centerMapOnUser(userLocation.coordinate)
            
            // Reset timer after centering
            lastUserInteraction = Date()
        }
    }
    
    private func resetAutoCenter() {
        // Reset the timer whenever user interacts with map
        lastUserInteraction = Date()
        print("[map] 👆 User interaction detected, resetting auto-center timer")
    }
    
    private func adjustedCoordinateFor25PercentFromBottom(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        // To position user 25% from bottom, we need to center the map NORTH of user location
        // This shifts the map center up (positive latitude) so user appears down from center
        // At zoom 16, roughly 0.001 degrees latitude ≈ 111 meters
        let latitudeOffset = 0.008 // Increased offset to position user further down (25% from bottom)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + latitudeOffset,
            longitude: coordinate.longitude
        )
    }
    
    private func setupFirebaseListeners(xid: String) {
        print("Setting up Firebase listeners for xid: \(xid)")
        let currentUserId = "ios-user-42"
        
        // Listen for chat messages
        let messagesRef = database.child("exhibits").child(xid).child("messages")
        messagesRef.observe(.childAdded) { snapshot in
            guard let messageData = snapshot.value as? [String: Any],
                  let mode = messageData["mode"] as? String,
                  let message = messageData["message"] as? String else {
                print("Invalid message data: \(snapshot.value ?? "nil")")
                return
            }
            
            DispatchQueue.main.async {
                if !chatMessages.contains(where: { $0.content == message && $0.role == mode }) {
                    chatMessages.append(ChatMessage(role: mode, content: message))
                    print("Added \(mode) message: \(message)")
                }
            }
        }
        
        // Listen for generated images
        let editObjectRef = database.child("exhibits").child(xid).child("editObject")
        editObjectRef.observe(.value) { snapshot in
            guard let editData = snapshot.value as? [String: Any],
                  let edits = editData["edits"] as? [[String: Any]] else {
                return
            }
            
            guard let userEdit = edits.first(where: { edit in
                (edit["userId"] as? String) == currentUserId
            }) else {
                return
            }
            
            DispatchQueue.main.async {
                if let status = userEdit["status"] as? String {
                    statusText = status
                }
                
                if let item = userEdit["item"] as? [String: Any],
                   let layers = item["layers"] as? [[String: Any]] {
                    let newImageUrls = layers.compactMap { $0["url"] as? String }
                    for imageUrl in newImageUrls {
                        if !generatedImages.contains(imageUrl) {
                            generatedImages.append(imageUrl)
                        }
                    }
                }
            }
        }
    }
    
    // Walking distance is now calculated and stored in pathStorage.currentDistance
    
    private func zoomToUserLocation() {
        guard let location = locationManager.currentLocation else {
            print("[map] ❌ No current location available")
            print("[map] 🔍 LocationManager status: \(locationManager.authorizationStatus)")
            print("[map] 🔍 LocationManager isTracking: \(locationManager.isTracking)")
            return
        }
        
        print("[map] 🎯 Location button pressed - using location: \(location.coordinate)")
        print("[map] 🎯 Location accuracy: \(location.horizontalAccuracy)m, age: \(abs(location.timestamp.timeIntervalSinceNow))s")
        
        // Use animated transition if coordinator is available
        if let coordinator = mapCoordinator {
            coordinator.animateToLocation(location.coordinate)
        } else {
            // Fallback to instant transition if coordinator not ready
            print("[map] ⚠️ Coordinator not ready, using instant transition with PRESERVED zoom/bearing/pitch")
            allowViewportUpdate = true
            viewport = .camera(
                center: location.coordinate, 
                zoom: viewport.camera?.zoom ?? defaultZoom,  // Preserve current zoom or default to persistent setting
                bearing: viewport.camera?.bearing ?? 0.0,  // Preserve current bearing or default to 0
                pitch: viewport.camera?.pitch ?? defaultPitch  // Preserve current pitch or default to persistent setting
            )
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                allowViewportUpdate = false
            }
        }
    }
    
    private func setupAlwaysOnPathTracking() {
        // Location updates are now handled automatically by pathStorage via LocationManager
        
        if !isTrackingPath {
            isTrackingPath = true
            print("[location] 🛤️ Started always-on journey tracking")
        }
    }
    
    // Path tracking is now handled by JourneyPathStorage
}