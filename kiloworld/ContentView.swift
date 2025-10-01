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

// Codable version of ChatMessage for persistence
struct ChatMessageData: Codable {
    let role: String
    let content: String
}
import os

// 80s Digital Display DateFormatters
extension DateFormatter {
    static let digitalDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy"
        return formatter
    }()

    static let digitalTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// Major world cities for nearest city calculation
struct WorldCity {
    let name: String
    let country: String
    let coordinate: CLLocationCoordinate2D
}

let majorCities: [WorldCity] = [
    WorldCity(name: "new york", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)),
    WorldCity(name: "los angeles", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)),
    WorldCity(name: "chicago", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298)),
    WorldCity(name: "houston", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 29.7604, longitude: -95.3698)),
    WorldCity(name: "phoenix", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740)),
    WorldCity(name: "philadelphia", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 39.9526, longitude: -75.1652)),
    WorldCity(name: "san antonio", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 29.4241, longitude: -98.4936)),
    WorldCity(name: "san diego", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 32.7157, longitude: -117.1611)),
    WorldCity(name: "dallas", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 32.7767, longitude: -96.7970)),
    WorldCity(name: "san jose", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863)),
    WorldCity(name: "austin", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431)),
    WorldCity(name: "jacksonville", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 30.3322, longitude: -81.6557)),
    WorldCity(name: "fort worth", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 32.7555, longitude: -97.3308)),
    WorldCity(name: "columbus", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 39.9612, longitude: -82.9988)),
    WorldCity(name: "san francisco", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)),
    WorldCity(name: "charlotte", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 35.2271, longitude: -80.8431)),
    WorldCity(name: "indianapolis", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 39.7684, longitude: -86.1581)),
    WorldCity(name: "seattle", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321)),
    WorldCity(name: "denver", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 39.7392, longitude: -104.9903)),
    WorldCity(name: "washington dc", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 38.9072, longitude: -77.0369)),
    WorldCity(name: "boston", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 42.3601, longitude: -71.0589)),
    WorldCity(name: "nashville", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 36.1627, longitude: -86.7816)),
    WorldCity(name: "pittsburgh", country: "usa", coordinate: CLLocationCoordinate2D(latitude: 40.4406, longitude: -79.9959)),
    WorldCity(name: "london", country: "uk", coordinate: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)),
    WorldCity(name: "paris", country: "france", coordinate: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)),
    WorldCity(name: "tokyo", country: "japan", coordinate: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)),
    WorldCity(name: "berlin", country: "germany", coordinate: CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050)),
    WorldCity(name: "sydney", country: "australia", coordinate: CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)),
    WorldCity(name: "toronto", country: "canada", coordinate: CLLocationCoordinate2D(latitude: 43.6510, longitude: -79.3470)),
    WorldCity(name: "dubai", country: "uae", coordinate: CLLocationCoordinate2D(latitude: 25.2048, longitude: 55.2708))
]

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

    // Settings modal state
    @State private var showSettingsModal: Bool = false
    
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
    @State private var mapCoordinator: CustomMapView.Coordinator?
    @State private var globeOn = false

    // Live clock for debug display
    @State private var currentTime = Date()
    @State private var clockTimer: Timer?
    @State private var nearestCityText = "FINDING CITY..."

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

    // Layer audio engine for looping audio files from URLs
    @StateObject private var layerAudioEngine = LayerAudioEngine()
    
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
        CustomMapView(
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
                    print("[puck] 📍 Updated puck position: \(puckPosition) (mode: \(mapCoordinator.mode == .globe ? "globe" : "neon"))")
                } else {
                    print("[puck] ⚠️ Failed to get puck position from map coordinator")
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
            defaultZoom: defaultZoom,
            userSettings: userSettings
        )
    }
    
    var body: some View {
        ZStack {
            // Map layer
            mapboxMapView
                .ignoresSafeArea()
                .onChange(of: [userSettings.horizonWidth, userSettings.horizonStart, userSettings.horizonFeather]) { _, newValues in
                    // Re-apply neon grid style when any horizon setting changes
                    print("[map] 🔄 Horizon settings changed: width=\(newValues[0]), start=\(newValues[1]), feather=\(newValues[2])")
                    if let mapCoordinator = mapCoordinator {
                        mapCoordinator.reapplyNeonGridStyle(with: userSettings)
                    }
                }
            
            // Debug overlay and controls
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        // Live date/time on same line in retro digital font
                        Text("\(DateFormatter.digitalDate.string(from: currentTime)) \(DateFormatter.digitalTime.string(from: currentTime))")
                            .font(.custom("Courier New", size: 14))
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                        Text("STEPS TAKEN: \(pathStorage.currentPath.count)")
                            .font(.custom("Courier New", size: 14))
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                        Text(nearestCityText)
                            .font(.custom("Courier New", size: 14))
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                        Text("PARTICLES: \(String(format: "%.0f", userSettings.hologramParticleCount))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.pink)
                        Text("EMISSION: \(String(format: "%.2f", userSettings.hologramEmissionDensity))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.pink)
                        Text("ZOOM: \(String(format: "%.2f", actualZoom))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white)
                        Text("PITCH: \(String(format: "%.1f", actualPitch))°")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white)
                        Text("SYNTH: \(activeSkyTouches) notes")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.cyan)
                        Text("AUDIO LAYERS: \(layerAudioEngine.activeLayerCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.yellow)
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
                    
                    Spacer()
                }
                Spacer()
            }
            .padding(.leading, 12)
            
            // Top button row - flush to safe area top
            VStack {
                HStack(spacing: 5) { // 5px spacing between buttons
                    Spacer()

                    // Globe toggle button
                    Button {
                        globeOn.toggle()
                        mapCoordinator?.toggleElectrifiedGlobe(userLocation: locationManager.currentLocation?.coordinate)
                        // Update hologram globe mode to pause rotation
                        hologramCoordinator?.setGlobeMode(globeOn)

                        // Force update puck position after mode change to prevent disappearing
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if let coordinator = mapCoordinator,
                               let puckPosition = coordinator.getPuckScreenPosition() {
                                puckScreenPosition = puckPosition
                                print("[puck] 🔄 Force updated puck position after mode change: \(puckPosition)")
                            }
                        }
                    } label: {
                        Image(systemName: globeOn ? "globe.europe.africa.fill" : "globe")
                            .font(.system(size: 36))
                            .foregroundColor(.white)
                    }
                    .frame(width: 60, height: 60)
                    .background(Color.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Settings button
                    Button(action: { showSettingsModal = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.white)
                    }
                    .frame(width: 60, height: 60)
                    .background(Color.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // User button
                    Button(action: { showUserModal = true }) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.white)
                    }
                    .frame(width: 60, height: 60)
                    .background(Color.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.trailing, 5) // Right margin only

                Spacer()
            }
            
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
                // 20px roads fade out from top
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black, location: 0.0),           // Fully black at top
                        .init(color: .black.opacity(0.5), location: 0.7), // Start fading
                        .init(color: .clear, location: 1.0)            // Transparent at bottom of 20px
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 20) // Fixed 20px height
                .allowsHitTesting(false) // Don't intercept touches

                Spacer()

                // 100px black gradient from bottom (ignoring safe area)
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),          // Transparent at top of 100px
                        .init(color: .black.opacity(0.3), location: 0.5), // Start fading
                        .init(color: .black.opacity(0.8), location: 0.8), // More opacity
                        .init(color: .black, location: 1.0)           // Fully black at bottom
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100) // Fixed 100px height
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
                    stepCount: pathStorage.currentPath.count,
                    nearestCity: nearestCityText,
                    currentLocation: locationManager.currentLocation != nil ?
                        "\(locationManager.currentLocation!.coordinate.latitude),\(locationManager.currentLocation!.coordinate.longitude)" : nil,
                    onLocationTapped: {
                        print("[map] 📍 ZOOM TO CURRENT LOCATION")
                        zoomToUserLocation()
                    },
                    onLatestMessageChanged: { message in
                        latestAIMessage = message
                        print("[typewriter] 📨 Latest AI message updated: \"\(String(message.prefix(50)))...\"")
                    }
                )
                .padding(.horizontal, 5) // 5px from left/right safe areas
                .padding(.bottom, 5) // 5px from bottom safe area
            }
            
            // Compass beam overlay - shows direction you're facing
            CompassBeamView(
                heading: compassHeading,
                isVisible: showCompassBeam
            )
            .allowsHitTesting(false) // Don't block map touches
            
            // Typewriter message display in the sky - TEMPORARILY HIDDEN
            // TypewriterMessageView(latestMessage: latestAIMessage)
            // .allowsHitTesting(false) // Don't block map touches
            
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
                sessionXid: $sessionXid,
                onSessionClear: clearSessionData
            )
        }
        .sheet(isPresented: $showSettingsModal) {
            SettingsModalView(
                userSettings: userSettings,
                dynamicTopPadding: $dynamicTopPadding,
                dynamicBottomPadding: $dynamicBottomPadding,
                defaultPitch: $defaultPitch,
                defaultZoom: $defaultZoom,
                mapCoordinator: mapCoordinator,
                userLocation: locationManager.currentLocation?.coordinate,
                generatedImages: $generatedImages,
                currentXid: $currentXid
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

            // Initialize synth ADSR from user settings
            if let synth = metalSynth {
                print("[audio] 🎛️ Initializing synth ADSR from settings: A=\(userSettings.synthAttack) D=\(userSettings.synthDecay) S=\(userSettings.synthSustain) R=\(userSettings.synthRelease)")
                synth.updateADSR(
                    attack: userSettings.synthAttack,
                    decay: userSettings.synthDecay,
                    sustain: userSettings.synthSustain,
                    release: userSettings.synthRelease
                )
                print("[audio] 🎛️ Initialized synth with ADSR from settings")

                // Also apply ADSR after a short delay to ensure it sticks
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    synth.updateADSR(
                        attack: userSettings.synthAttack,
                        decay: userSettings.synthDecay,
                        sustain: userSettings.synthSustain,
                        release: userSettings.synthRelease
                    )
                    print("[audio] 🎛️ Re-applied synth ADSR after delay")
                }
            }

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
            
            // Set up location updates for auto-centering timer and city distance
            locationManager.onLocationUpdate = { coordinate in
                checkAutoCenterTimer(userLocation: coordinate)
                updateNearestCity(coordinate)
            }
            
            // Auto-center timer disabled per user request
            // startAutoCenterTimer()
            
            setupAlwaysOnPathTracking()
            
            // Restore session data first
            restoreSessionData()

            // Add initial journey message only if no session was restored
            if chatMessages.isEmpty {
                chatMessages.append(ChatMessage(role: "assistant", content: "🌟 walk forth, create wonder ✨ what calls to your spirit? 🚶‍♂️💫"))
            }
            
            // Try to start at user location if available
            if let userLocation = locationManager.currentLocation {
                print("[map] 📍 Starting at user location using anchor-based positioning")
                // Update nearest city initially
                updateNearestCity(userLocation.coordinate)
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

            // Start live clock timer for debug display
            clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                currentTime = Date()
            }
        }
        .onDisappear {
            // Clean up timers
            autoCenterTimer?.invalidate()
            autoCenterTimer = nil
            clockTimer?.invalidate()
            clockTimer = nil
            print("[map] 🗑️ Cleaned up timers")
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
        .onChange(of: [userSettings.synthAttack, userSettings.synthDecay, userSettings.synthSustain, userSettings.synthRelease]) { _, newValues in
            // Update synth ADSR when settings change
            metalSynth?.updateADSR(
                attack: newValues[0],
                decay: newValues[1],
                sustain: newValues[2],
                release: newValues[3]
            )
            print("[settings] 🎛️ Updated synth ADSR from settings")
        }
        .onChange(of: chatMessages) { _, _ in
            // Save session when chat messages change
            saveSessionData()
        }
        .onChange(of: generatedImages) { oldValue, newValue in
            // Save session when generated images change
            saveSessionData()

            // Load new images into hologram (with final safety check)
            if let latestImageURL = newValue.last, !oldValue.contains(latestImageURL) {
                // Final safety check - ensure it's actually an image file
                let isImageFile = latestImageURL.hasSuffix(".jpg") || latestImageURL.hasSuffix(".jpeg") ||
                                latestImageURL.hasSuffix(".png") || latestImageURL.hasSuffix(".gif") ||
                                latestImageURL.hasSuffix(".webp") || latestImageURL.hasSuffix(".bmp") ||
                                latestImageURL.hasSuffix(".tiff") || latestImageURL.hasSuffix(".svg")

                if isImageFile {
                    print("[hologram] 🆕 New image detected: \(latestImageURL)")
                    hologramCoordinator?.loadHologramFromURL(latestImageURL)
                } else {
                    print("[hologram] 🚫 Blocked non-image file from hologram: \(latestImageURL)")
                    print("[hologram]    → This should not happen - check layer processing logic")

                    // Remove the non-image URL from generatedImages to prevent future issues
                    if let index = generatedImages.firstIndex(of: latestImageURL) {
                        generatedImages.remove(at: index)
                        print("[hologram] 🧹 Cleaned up non-image URL from generatedImages")
                    }
                }
            }
        }
        .onChange(of: sessionXid) { _, _ in
            // Save session when session ID changes
            saveSessionData()
        }
        .onChange(of: currentXid) { _, _ in
            // Save session when current XID changes
            saveSessionData()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // Save session when app goes to background
            saveSessionData()
            print("[session] 💾 Saved session data on app background")
        }
    }

    // MARK: - Session Persistence

    private func saveSessionData() {
        // Save chat messages
        if let chatData = try? JSONEncoder().encode(chatMessages.map { ChatMessageData(role: $0.role, content: $0.content) }) {
            UserDefaults.standard.set(chatData, forKey: "persistentChatMessages")
        }

        // Save session IDs
        UserDefaults.standard.set(sessionXid, forKey: "persistentSessionXid")
        UserDefaults.standard.set(currentXid, forKey: "persistentCurrentXid")

        // Save generated images
        UserDefaults.standard.set(generatedImages, forKey: "persistentGeneratedImages")

        print("[session] 💾 Saved session data: \(chatMessages.count) messages, sessionXid: \(sessionXid ?? "nil"), currentXid: \(currentXid ?? "nil"), \(generatedImages.count) images")
    }

    private func restoreSessionData() {
        // Restore chat messages
        if let chatData = UserDefaults.standard.data(forKey: "persistentChatMessages"),
           let chatDataArray = try? JSONDecoder().decode([ChatMessageData].self, from: chatData) {
            chatMessages = chatDataArray.map { ChatMessage(role: $0.role, content: $0.content) }
            print("[session] 📱 Restored \(chatMessages.count) chat messages")
        }

        // Restore session IDs
        sessionXid = UserDefaults.standard.string(forKey: "persistentSessionXid")
        currentXid = UserDefaults.standard.string(forKey: "persistentCurrentXid")

        // Restore generated images
        let restoredImages = UserDefaults.standard.stringArray(forKey: "persistentGeneratedImages") ?? []

        // Filter out any audio/music URLs that might have been incorrectly saved
        generatedImages = restoredImages.filter { url in
            let isAudioFile = url.hasSuffix(".mp3") || url.hasSuffix(".wav") || url.hasSuffix(".m4a") || url.hasSuffix(".aac") || url.hasSuffix(".flac") || url.hasSuffix(".ogg")
            if isAudioFile {
                print("[session] 🎵 Filtered out audio/music URL from restored images: \(url)")
                return false
            }
            return true
        }

        print("[session] 📱 Restored session data: sessionXid: \(sessionXid ?? "nil"), currentXid: \(currentXid ?? "nil"), \(generatedImages.count) images (filtered \(restoredImages.count - generatedImages.count) audio URLs)")
    }

    private func clearSessionData() {
        // Clear in-memory data
        chatMessages.removeAll()
        generatedImages.removeAll()
        sessionXid = nil
        currentXid = nil

        // Clear persistent data
        UserDefaults.standard.removeObject(forKey: "persistentChatMessages")
        UserDefaults.standard.removeObject(forKey: "persistentSessionXid")
        UserDefaults.standard.removeObject(forKey: "persistentCurrentXid")
        UserDefaults.standard.removeObject(forKey: "persistentGeneratedImages")

        // Add initial welcome message
        chatMessages.append(ChatMessage(role: "assistant", content: "🌟 walk forth, create wonder ✨ what calls to your spirit? 🚶‍♂️💫"))

        print("[session] 🗑️ Cleared session data and reset to initial state")
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
        // BUT ignore compass in globe mode - keep north at top
        if let coordinator = mapCoordinator,
           let userLocation = locationManager.currentLocation,
           coordinator.mode == .neon { // Only rotate in neon mode
            isCompassRotating = true
            coordinator.updateBearingWithUserLocation(heading, userLocation: userLocation.coordinate)
            // Live rotating map to compass heading

            // Reset flag after rotation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isCompassRotating = false
            }
        } else if mapCoordinator?.mode == .globe {
            print("[compass] 🌍 Ignoring compass in globe mode - keeping north at top")
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
        print("🔥 ContentView: Setting up Firebase listeners for xid: \(xid)")
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
            print("🔥 ContentView: Firebase editObject listener triggered")
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

                    print("🔍 Firebase: Processing \(layers.count) layers from item")

                    // Process all layers - both image and audio
                    for (index, layer) in layers.enumerated() {
                        print("🔍 Firebase: Layer \(index): \(layer)")

                        guard let layerUrl = layer["url"] as? String else {
                            print("⚠️ Firebase: Layer \(index) missing URL")
                            continue
                        }

                        // Check layer type
                        let layerType = layer["type"] as? String ?? "image"
                        print("🔍 Firebase: Layer \(index) type: '\(layerType)'")

                        // Check if this is an audio/music layer
                        if layerType == "audio" || layerType == "music" {
                            // Handle audio layer
                            let layerId = layer["id"] as? String ?? "layer_\(index)"
                            let volume = layer["volume"] as? Float ?? 1.0
                            let shouldLoop = layer["loop"] as? Bool ?? true
                            let autoplay = layer["autoplay"] as? Bool ?? true

                            print("🎵 Firebase: Processing \(layerType) layer!")
                            print("   - ID: \(layerId)")
                            print("   - URL: \(layerUrl)")
                            print("   - Volume: \(volume)")
                            print("   - Loop: \(shouldLoop)")
                            print("   - Autoplay: \(autoplay)")

                            if let url = URL(string: layerUrl) {
                                Task {
                                    print("🎵 Firebase: Starting async load for \(layerId)")
                                    await layerAudioEngine.loadAudioLayer(layerId: layerId, url: url, volume: volume)

                                    // Auto-play if specified
                                    if autoplay {
                                        await MainActor.run {
                                            print("🎵 Firebase: Auto-playing layer \(layerId)")
                                            layerAudioEngine.playLayer(layerId: layerId, loop: shouldLoop)
                                        }
                                    } else {
                                        print("🎵 Firebase: Layer \(layerId) loaded but autoplay disabled")
                                    }
                                }
                            } else {
                                print("❌ Firebase: Invalid URL for audio layer: \(layerUrl)")
                            }
                        } else {
                            // Handle image layer - verify it's actually an image file
                            let isImageFile = layerUrl.hasSuffix(".jpg") || layerUrl.hasSuffix(".jpeg") ||
                                            layerUrl.hasSuffix(".png") || layerUrl.hasSuffix(".gif") ||
                                            layerUrl.hasSuffix(".webp") || layerUrl.hasSuffix(".bmp") ||
                                            layerUrl.hasSuffix(".tiff") || layerUrl.hasSuffix(".svg")

                            if isImageFile {
                                print("🖼️ Firebase: Processing \(layerType) layer: \(layerUrl)")
                                if !generatedImages.contains(layerUrl) {
                                    generatedImages.append(layerUrl)
                                    print("✅ Firebase: Added image URL to generatedImages: \(layerUrl)")
                                } else {
                                    print("⚠️ Firebase: Image URL already exists in generatedImages: \(layerUrl)")
                                }
                            } else {
                                print("🚫 Firebase: Skipping non-image file \(layerType) layer: \(layerUrl)")
                                print("   → File extension not recognized as image format")
                            }
                        }
                    }
                } else {
                    print("⚠️ Firebase: No item/layers found in edit data")
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

    private func updateNearestCity(_ coordinate: CLLocationCoordinate2D) {
        let userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        var nearestCity: WorldCity?
        var nearestDistance: CLLocationDistance = Double.infinity

        for city in majorCities {
            let cityLocation = CLLocation(latitude: city.coordinate.latitude, longitude: city.coordinate.longitude)
            let distance = userLocation.distance(from: cityLocation)

            if distance < nearestDistance {
                nearestDistance = distance
                nearestCity = city
            }
        }

        if let city = nearestCity {
            let distanceMiles = nearestDistance / 1609.34  // Convert meters to miles
            let distanceText: String

            if distanceMiles < 0.1 {
                distanceText = "\(Int(nearestDistance * 3.28084))FT"  // Show feet for very close distances
            } else if distanceMiles < 1.0 {
                distanceText = String(format: "%.1fMI", distanceMiles)
            } else if distanceMiles < 10.0 {
                distanceText = String(format: "%.1fMI", distanceMiles)
            } else {
                distanceText = "\(Int(distanceMiles))MI"
            }

            nearestCityText = "\(distanceText) NO OF \(city.name.uppercased())"
        } else {
            nearestCityText = "LOCATION UNKNOWN"
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