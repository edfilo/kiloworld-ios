//
//  SettingsModalView.swift
//  kiloworld
//
//  Created by Claude on 9/25/25.
//

import SwiftUI
import CoreLocation
import FirebaseDatabase

struct SettingsModalView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var userSettings: UserSettings
    @Binding var dynamicTopPadding: Double
    @Binding var dynamicBottomPadding: Double
    @Binding var defaultPitch: Double
    @Binding var defaultZoom: Double
    let mapCoordinator: CustomMapView.Coordinator?
    let userLocation: CLLocationCoordinate2D?
    @Binding var generatedImages: [String]
    @Binding var currentXid: String?

    @State private var editObjectJSON: String = "Loading..."
    private let database = Database.database().reference()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Edit Object Debug Section
                    editObjectSection

                    // Hologram Controls Section
                    hologramControlsSection

                    // Map Controls Section
                    mapControlsSection

                    // Camera Controls Section
                    cameraControlsSection

                    // Synth Controls Section
                    synthControlsSection

                    // Debug Section
                    debugSection
                }
                .padding()
            }
            .scrollContentBackground(.hidden) // Hide default ScrollView background
            .background(Color.clear)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .toolbarBackground(.clear, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .background(Color.clear) // Transparent modal background
        .presentationBackground(.clear) // Fully transparent sheet background for iOS 18
    }

    private var hologramControlsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HOLOGRAM CONTROLS")
                .font(.headline)
                .foregroundColor(.pink)
                .padding(.bottom, 8)

            // Particle Count Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Particles")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.0f", userSettings.hologramParticleCount))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramParticleCount, in: 1000.0...50000.0, step: 1000.0)
                    .accentColor(.pink)
            }

            // Depth Slider (-50 to +50)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Depth")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramDepth))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramDepth, in: -1.0...1.0, step: 0.01)
                    .accentColor(.pink)
                Text("Range: -1 to +1 (0=flat, +1=forward, -1=reverse)")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            // Size Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Size")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramSize))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramSize, in: 0.1...2.0, step: 0.1)
                    .accentColor(.pink)
            }

            // Zoom Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Zoom")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramZoom))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramZoom, in: 0.01...1.0, step: 0.01)
                    .accentColor(.pink)
            }

            // Rotation Speed Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Rotation Speed")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramRotSpeed))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramRotSpeed, in: 0.0...3.0, step: 0.1)
                    .accentColor(.pink)
            }

            // Y Position Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Y Position")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.0f", userSettings.hologramYPosition * 500.0))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramYPosition, in: -1.0...1.0, step: 0.1)
                    .accentColor(.pink)
                Text("Range: -500 to +500 units")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            // Background Fade Min Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Background Min")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramBgMin))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramBgMin, in: 0.0...1.0, step: 0.01)
                    .accentColor(.pink)
                Text("Start of smoothstep fade")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            // Background Fade Max Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Background Max")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramBgMax))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramBgMax, in: 0.0...1.0, step: 0.01)
                    .accentColor(.pink)
                Text("End of smoothstep fade")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            
            //arcradius
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Radius")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.arcRadius))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.arcRadius, in: 0.0...500.0, step: 1.0)
                    .accentColor(.pink)
                Text("Arc Radius")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            // Dissolve Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Dissolve")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramDissolve))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramDissolve, in: 0.0...1.0, step: 0.1)
                    .accentColor(.pink)
            }

            // Wobble Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Wobble")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramWobble))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramWobble, in: 0.0...1.0, step: 0.01)
                    .accentColor(.pink)
            }

            // Wobble Speed Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Wobble Speed")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramWobbleSpeed))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramWobbleSpeed, in: 0.01...1.0, step: 0.01)
                    .accentColor(.pink)
            }

            // Emission Density Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Emission Density")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.3f", userSettings.hologramEmissionDensity))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramEmissionDensity, in: 0.001...0.5, step: 0.001)
                    .accentColor(.pink)
            }

            // Emission Speed Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Emission Speed")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramEmissionSpeed))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramEmissionSpeed, in: 0.0...1.0, step: 0.1)
                    .accentColor(.pink)
            }

            // Particle Blink Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Particle Blink")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.particleBlink))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.particleBlink, in: 0.0...1.0, step: 0.01)
                    .accentColor(.pink)
                Text("Random blink rate: 0.5-5.0 seconds")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            // Particle Random Size Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Random Size")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.particleRandomSize))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.particleRandomSize, in: 0.0...1.0, step: 0.01)
                    .accentColor(.pink)
                Text("Size variation: 0=uniform, 1=varied")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            // Particle Glow Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Particle Glow")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.particleGlow))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.particleGlow, in: 0.0...1.0, step: 0.01)
                    .accentColor(.pink)
                Text("Glow effect: 0=sharp circles, 1=soft glow")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
        .padding()
        .background(Color.clear)
        .cornerRadius(12)
    }

    private var mapControlsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MAP CONTROLS")
                .font(.headline)
                .foregroundColor(.pink)
                .padding(.bottom, 8)

            // Horizon Width Slider (km-based thickness)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Horizon Width")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f km", userSettings.horizonWidth))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.horizonWidth, in: 0.15...1.2, step: 0.05)
                    .accentColor(.pink)
                Text("Band thickness: 0.15-0.25=razor, 0.4=thin, 0.8-1.2=thick")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            // Horizon Start Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Horizon Start")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f km", userSettings.horizonStart))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.horizonStart, in: 1.0...20.0, step: 0.1)
                    .accentColor(.pink)
                Text("Distance from camera: 1.0=close, 4.0=horizon, 20.0=very far")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            // Horizon Feather Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Horizon Feather")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.3f", userSettings.horizonFeather))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.horizonFeather, in: 0.0...0.6, step: 0.01)
                    .accentColor(.pink)
                Text("Edge softness: 0.0=sharp, 0.6=soft blend")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
        .padding()
        .background(Color.clear)
        .cornerRadius(12)
    }

    private var cameraControlsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CAMERA CONTROLS")
                .font(.headline)
                .foregroundColor(.pink)
                .padding(.bottom, 8)

            // Dynamic Top Camera Padding Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Top Camera Padding")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(Int(dynamicTopPadding))px")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $dynamicTopPadding, in: 0...600, step: 10)
                    .accentColor(.pink)
                Text("Controls puck positioning and camera anchor")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            // Dynamic Bottom Camera Padding Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Bottom Camera Padding")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(Int(dynamicBottomPadding))px")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $dynamicBottomPadding, in: 0...200, step: 10)
                    .accentColor(.pink)
                Text("Bottom camera offset")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            // Default Pitch Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Default Pitch")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(Int(defaultPitch))°")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $defaultPitch, in: 0...85, step: 5)
                    .accentColor(.pink)
                Text("Camera tilt angle: 0°=top-down, 85°=horizon view")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            // Default Zoom Slider (controls both location button and default zoom)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Default Zoom")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.1f", defaultZoom))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $defaultZoom, in: 8...20, step: 0.5)
                    .accentColor(.pink)
                    .onChange(of: defaultZoom) { _, newValue in
                        updateCameraZoom(newValue)
                    }
                Text("Default zoom for location button and app launch")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
        .padding()
        .background(Color.clear)
        .cornerRadius(12)
    }

    private var synthControlsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AUDIO SETTINGS")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.white)

            // Audio Playback Controls
            VStack(alignment: .leading, spacing: 12) {
                Text("Looping Playback")
                    .font(.subheadline)
                    .foregroundColor(.cyan)
                    .padding(.bottom, 4)

                // Pitch Slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Pitch")
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Spacer()
                        Text(String(format: "%.2fx", userSettings.audioPlaybackPitch))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                    }
                    Slider(value: $userSettings.audioPlaybackPitch, in: 0.5...2.0, step: 0.01)
                        .accentColor(.cyan)
                    Text("0.5x = lower pitch, 2.0x = higher pitch")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                // Speed Slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Speed")
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Spacer()
                        Text(String(format: "%.2fx", userSettings.audioPlaybackSpeed))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                    }
                    Slider(value: $userSettings.audioPlaybackSpeed, in: 0.5...2.0, step: 0.01)
                        .accentColor(.cyan)
                    Text("0.5x = slower, 2.0x = faster")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                // Varispeed Slider (record player style)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Varispeed")
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Spacer()
                        Text(String(format: "%.2fx", userSettings.audioPlaybackVarispeed))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                    }
                    Slider(value: $userSettings.audioPlaybackVarispeed, in: 0.5...2.0, step: 0.01)
                        .accentColor(.cyan)
                    Text("Record player style: changes pitch and speed together")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            .padding(.bottom, 8)

            // ADSR Envelope Controls
            VStack(alignment: .leading, spacing: 12) {
                Text("Synth ADSR Envelope")
                    .font(.subheadline)
                    .foregroundColor(.cyan)
                    .padding(.bottom, 4)

                // Attack
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Attack")
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Spacer()
                        Text(String(format: "%.3fs", userSettings.synthAttack))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                    }
                    Slider(value: $userSettings.synthAttack, in: 0.001...3.0, step: 0.001)
                        .accentColor(.cyan)
                    Text("Time to reach peak volume after note start")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                // Decay
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Decay")
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Spacer()
                        Text(String(format: "%.3fs", userSettings.synthDecay))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                    }
                    Slider(value: $userSettings.synthDecay, in: 0.001...3.0, step: 0.001)
                        .accentColor(.cyan)
                    Text("Time to decay from peak to sustain level")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                // Sustain
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Sustain")
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Spacer()
                        Text(String(format: "%.3f", userSettings.synthSustain))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                    }
                    Slider(value: $userSettings.synthSustain, in: 0.0...1.0, step: 0.001)
                        .accentColor(.cyan)
                    Text("Volume level while note is held")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                // Release
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Release")
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Spacer()
                        Text(String(format: "%.3fs", userSettings.synthRelease))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                    }
                    Slider(value: $userSettings.synthRelease, in: 0.001...3.0, step: 0.001)
                        .accentColor(.cyan)
                    Text("Time to fade to silence after note release")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding()
        .background(Color.clear)
        .cornerRadius(12)
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DEBUG INFO")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 12) {
                // Current XID
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current XID")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Text(currentXid ?? "nil")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(8)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(4)
                }

                // Generated Images Count
                VStack(alignment: .leading, spacing: 8) {
                    Text("Generated Images Count")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Text("\(generatedImages.count)")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(8)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(4)
                }

                // Print Layers Button
                Button(action: {
                    printLayersDebugInfo()
                }) {
                    Text("Print Layers Debug Info")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.blue)
                        .cornerRadius(8)
                }

                // Generated Images URLs
                if !generatedImages.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Generated Images URLs")
                            .font(.subheadline)
                            .foregroundColor(.white)

                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(generatedImages.indices, id: \.self) { index in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("[\(index)]")
                                            .font(.caption2)
                                            .foregroundColor(.cyan)
                                        Text(generatedImages[index])
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                            .lineLimit(3)
                                    }
                                    .padding(8)
                                    .background(Color.black.opacity(0.3))
                                    .cornerRadius(4)
                                    .frame(width: 200)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.clear)
        .cornerRadius(12)
    }

    private var editObjectSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CURRENT EDIT OBJECT")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.cyan)

            ScrollView {
                Text(editObjectJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
        .padding()
        .background(Color.cyan.opacity(0.1))
        .cornerRadius(12)
        .onAppear {
            loadEditObject()
        }
    }

    private func printLayersDebugInfo() {
        print("🔍 [DEBUG] === LAYERS DEBUG INFO ===")
        print("🔍 [DEBUG] Current XID: \(currentXid ?? "nil")")
        print("🔍 [DEBUG] Generated Images Count: \(generatedImages.count)")

        for (index, imageUrl) in generatedImages.enumerated() {
            print("🔍 [DEBUG] Image [\(index)]: \(imageUrl)")
        }

        print("🔍 [DEBUG] === END LAYERS DEBUG ===")
    }

    private func updateCameraZoom(_ zoom: Double) {
        guard let userLocation = userLocation else {
            print("[modal] ❌ No user location for zoom update")
            return
        }
        mapCoordinator?.updateCamera(userLocation: userLocation, zoom: zoom, duration: 0.5)
    }

    private func loadEditObject() {
        guard let xid = currentXid else {
            editObjectJSON = "No XID available"
            return
        }

        // First, log the entire exhibit structure
        let exhibitRef = database.child("exhibits").child(xid)
        exhibitRef.observe(.value) { snapshot in
            if let value = snapshot.value {
                print("[firebase] 🏛️ Complete Exhibit Structure at exhibits/\(xid)/:")
                print("[firebase] 🏛️ Exhibit type: \(type(of: value))")

                if let dict = value as? [String: Any] {
                    print("[firebase] 🏛️ Exhibit keys: \(dict.keys.sorted())")
                    for (key, val) in dict {
                        print("[firebase] 🔑 exhibits/\(xid)/\(key): \(type(of: val))")
                        if !(val is NSNull) {
                            print("[firebase] 📄 Content: \(val)")
                        } else {
                            print("[firebase] 📄 Content: <null>")
                        }
                    }
                } else {
                    print("[firebase] 🏛️ Exhibit value: \(value)")
                }
            } else {
                print("[firebase] ❌ No exhibit found at exhibits/\(xid)")
            }
        }

        // Then continue with editObject specific logging
        let editObjectRef = database.child("exhibits").child(xid).child("editObject")
        editObjectRef.observe(.value) { snapshot in
            if let value = snapshot.value {
                // Log the complete Firebase RTDB object structure
                print("[firebase] 🔥 Complete RTDB editObject:")
                print("[firebase] 🔥 Raw value type: \(type(of: value))")
                print("[firebase] 🔥 Raw value: \(value)")

                // Handle the case where the entire object is NSNull
                if value is NSNull {
                    editObjectJSON = "editObject exists but is null - no data at this path"
                    print("[firebase] ⚠️ editObject is NSNull - path exists but no data")
                    return
                }

                // Check if it's a dictionary and log key structure
                if let dict = value as? [String: Any] {
                    print("[firebase] 🔥 Object keys: \(dict.keys.sorted())")

                    // Look specifically for messages key
                    if let messages = dict["messages"] {
                        print("[firebase] 💬 Messages found - type: \(type(of: messages))")
                        print("[firebase] 💬 Messages content: \(messages)")
                    }

                    // Look for layers or other structure
                    for (key, val) in dict {
                        print("[firebase] 🔑 Key '\(key)': \(type(of: val)) = \(val)")
                    }
                }

                // Convert Firebase data to JSON-safe format, handling NSNull values
                let jsonSafeValue = convertToJSONSafe(value)

                do {
                    let jsonData = try JSONSerialization.data(withJSONObject: jsonSafeValue, options: .prettyPrinted)
                    editObjectJSON = String(data: jsonData, encoding: .utf8) ?? "Failed to parse JSON"
                } catch {
                    editObjectJSON = "JSON Serialization Error: \(error.localizedDescription)"
                }
            } else {
                editObjectJSON = "No edit object found"
                print("[firebase] ⚠️ No editObject found in RTDB")
            }
        }
    }

    // Helper function to convert Firebase data to JSON-safe format
    private func convertToJSONSafe(_ value: Any) -> Any {
        if value is NSNull {
            return NSNull() // Convert Firebase NSNull to JSON null
        } else if let dict = value as? [String: Any] {
            var jsonSafeDict: [String: Any] = [:]
            for (key, val) in dict {
                jsonSafeDict[key] = convertToJSONSafe(val)
            }
            return jsonSafeDict
        } else if let array = value as? [Any] {
            return array.map { convertToJSONSafe($0) }
        } else {
            // For primitive types (String, Number, Bool), return as-is
            return value
        }
    }
}

#Preview {
    SettingsModalView(
        userSettings: UserSettings(),
        dynamicTopPadding: .constant(100.0),
        dynamicBottomPadding: .constant(50.0),
        defaultPitch: .constant(85.0),
        defaultZoom: .constant(16.0),
        mapCoordinator: nil,
        userLocation: nil,
        generatedImages: .constant(["https://example.com/image1.jpg", "https://example.com/image2.jpg"]),
        currentXid: .constant("test-xid-123")
    )
}
