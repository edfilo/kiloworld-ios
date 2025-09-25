//
//  UserModalView.swift
//  kiloworld
//
//  Created by Claude on 9/22/25.
//

import SwiftUI
import CoreLocation

struct UserModalView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var pathStorage: JourneyPathStorage
    let mapCoordinator: NeonGridMapView.Coordinator?
    let userLocation: CLLocationCoordinate2D?
    @Binding var dynamicTopPadding: Double // Binding to control camera top padding
    @Binding var dynamicBottomPadding: Double // Binding to control camera bottom padding
    @Binding var defaultPitch: Double // Binding to control default pitch
    @Binding var defaultZoom: Double // Binding to control default zoom
    @Binding var globalSize: Float // Binding to control particle size
    @Binding var depthAmount: Float // Binding to control particle depth
    @ObservedObject var userSettings: UserSettings // User settings for hologram controls
    @Binding var generatedImages: [String] // Generated images from Firebase
    @Binding var sessionXid: String? // Current session XID
    @State private var showingDeleteAlert = false
    @State private var journeyToDelete: JourneySession?
    
    // Test sliders state  
    @State private var testZoom: Double = 16
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Debug Section (top)
                    debugSection
                    
                    // Hologram Controls Section
                    hologramControlsSection
                    
                    // Current Journey Section
                    currentJourneySection
                    
                    // Statistics Section
                    statisticsSection
                    
                    // All Journeys Section
                    allJourneysSection
                    
                    // Test Sliders Section
                    testSlidersSection
                    
                    Spacer()
                }
                .padding()
            }
            .background(Color.black.opacity(0.3)) // Semi-transparent background
            .navigationTitle("My Walks")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
        }
        .background(Color.clear) // Transparent modal background
        .presentationBackground(Color.black.opacity(0.3)) // Semi-transparent sheet background
        .alert("Delete Walk", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let walk = journeyToDelete {
                    pathStorage.deleteJourney(walk)
                }
            }
        } message: {
            Text("Are you sure you want to delete this journey? This action cannot be undone.")
        }
    }
    
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Firebase Debug")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            VStack(alignment: .leading, spacing: 8) {
                // Session XID
                HStack {
                    Text("Session XID:")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text(sessionXid ?? "None")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                
                // Generated Images Count
                HStack {
                    Text("Generated Images:")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("\(generatedImages.count)")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                
                // Generated Images URLs
                if !generatedImages.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Image URLs:")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        
                        ForEach(generatedImages, id: \.self) { imageUrl in
                            Text(imageUrl)
                                .font(.system(size: 10))
                                .foregroundColor(.cyan)
                                .lineLimit(3)
                        }
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }
        .padding()
        .background(Color.black.opacity(0.05))
        .cornerRadius(12)
    }
    
    private var currentJourneySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Journey")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            if pathStorage.currentPath.isEmpty {
                Text("No active walk")
                    .foregroundColor(.white.opacity(0.7))
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Distance:")
                            .foregroundColor(.white)
                        Spacer()
                        Text(pathStorage.formattedDistance(pathStorage.currentDistance))
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                    
                    HStack {
                        Text("Points:")
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(pathStorage.currentPath.count)")
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                
                VStack(spacing: 8) {
                    // Main save button - prominent
                    Button("Save Journey & Start New") {
                        pathStorage.publishCurrentJourney()
                        // Start a new journey automatically after saving
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            pathStorage.clearCurrentPath()
                        }
                    }
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(8)
                    .disabled(pathStorage.currentPath.isEmpty)
                    
                    // Secondary buttons - smaller
                    HStack(spacing: 8) {
                        Button("Just Publish") {
                            pathStorage.publishCurrentJourney()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.green)
                        .cornerRadius(6)
                        .disabled(pathStorage.currentPath.isEmpty)
                        
                        Button("Clear Only") {
                            pathStorage.clearCurrentPath()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red)
                        .cornerRadius(6)
                        .disabled(pathStorage.currentPath.isEmpty)
                    }
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.05))
        .cornerRadius(12)
    }
    
    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                StatCard(
                    title: "Total Distance",
                    value: pathStorage.formattedDistance(pathStorage.totalPublishedDistance),
                    icon: "figure.walk"
                )
                
                StatCard(
                    title: "Journeys",
                    value: "\(pathStorage.totalJourneySessions)",
                    icon: "list.number"
                )
                
                StatCard(
                    title: "Average",
                    value: pathStorage.formattedDistance(pathStorage.averageJourneyDistance),
                    icon: "chart.line.uptrend.xyaxis"
                )
                
                StatCard(
                    title: "Current",
                    value: pathStorage.formattedDistance(pathStorage.currentDistance),
                    icon: "location"
                )
            }
        }
        .padding()
        .background(Color.black.opacity(0.05))
        .cornerRadius(12)
    }
    
    private var allJourneysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("All Journeys (\(pathStorage.allJourneys.count))")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            if pathStorage.allJourneys.isEmpty {
                Text("No published walks yet")
                    .foregroundColor(.white.opacity(0.7))
                    .italic()
                    .padding()
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(pathStorage.allJourneys.reversed()) { journey in
                        JourneyRow(journey: journey) {
                            journeyToDelete = journey
                            showingDeleteAlert = true
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.05))
        .cornerRadius(12)
    }
    
    private var testSlidersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Test Controls")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            // Dynamic Top Camera Padding Slider (controls puck position)
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
                    .onChange(of: dynamicTopPadding) { _, newValue in
                        print("[modal] 🎛️ Top camera padding changed to: \(newValue)px - Puck positioning updated!")
                        // No need for updateCameraPadding - the binding automatically updates the camera system
                    }
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
                    .onChange(of: dynamicBottomPadding) { _, newValue in
                        print("[modal] 🎛️ Bottom camera padding changed to: \(newValue)px")
                        // The binding automatically updates the camera system
                    }
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
                    .onChange(of: defaultPitch) { _, newValue in
                        print("[modal] 🎛️ Default pitch changed to: \(newValue)°")
                        // The binding automatically updates the camera system
                    }
            }
            
            // Default Zoom Slider
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
                    .onChange(of: defaultZoom) { _, newValue in
                        print("[modal] 🎛️ Default zoom changed to: \(newValue)")
                        // The binding automatically updates the camera system
                    }
            }
            
            
            // Test Zoom Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Map Zoom")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.1f", testZoom))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                
                Slider(value: $testZoom, in: 8...20, step: 0.5)
                    .onChange(of: testZoom) { _, newValue in
                        updateCameraZoom(newValue)
                    }
            }
        }
        .padding()
        .background(Color.black.opacity(0.05))
        .cornerRadius(12)
    }
    
    private var hologramControlsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hologram Controls")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            // Rotation Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Rotation")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramRotation))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramRotation, in: 0...6.28, step: 0.1)
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
                Slider(value: $userSettings.hologramRotSpeed, in: 0...3.0, step: 0.1)
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
            }
            
            // Depth Slider
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
                Slider(value: $userSettings.hologramDepth, in: -10.0...10.0, step: 0.1)
            }
            
            // Background Hide Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("BG Hide")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramBgHide))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramBgHide, in: 0.0...1.0, step: 0.05)
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
                Slider(value: $userSettings.hologramDissolve, in: 0.0...1.0, step: 0.05)
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
                Slider(value: $userSettings.hologramWobble, in: 0.0...10.0, step: 0.1)
            }
            
            // Y Position Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Y Position")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text(String(format: "%.2f", userSettings.hologramYPosition))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                Slider(value: $userSettings.hologramYPosition, in: -1.0...1.0, step: 0.05)
            }

            // Particle Count Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Particle Count")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatParticleCount(userSettings.hologramParticleCount))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                        Text(getPerformanceIndicator(userSettings.hologramParticleCount))
                            .font(.system(size: 9))
                            .foregroundColor(getPerformanceColor(userSettings.hologramParticleCount))
                    }
                }
                Slider(value: $userSettings.hologramParticleCount, in: 1000...100000, step: 1000, onEditingChanged: { editing in
                    if !editing {
                        // User released the slider - trigger particle system rebuild
                        print("🔄 Particle count changed to \(Int(userSettings.hologramParticleCount)) - will rebuild system")
                        // TODO: Implement particle system rebuild logic
                    }
                })

                // Preset buttons for common particle counts
                HStack(spacing: 8) {
                    Button("Fast (5K)") {
                        userSettings.hologramParticleCount = 5000
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(4)

                    Button("Balanced (30K)") {
                        userSettings.hologramParticleCount = 30000
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.2))
                    .foregroundColor(.blue)
                    .cornerRadius(4)

                    Button("Beautiful (75K)") {
                        userSettings.hologramParticleCount = 75000
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.2))
                    .foregroundColor(.purple)
                    .cornerRadius(4)

                    Spacer()
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.2))
        .cornerRadius(12)
    }
    
    private func updateCameraZoom(_ zoom: Double) {
        guard let userLocation = userLocation else {
            print("[modal] ❌ No user location for zoom update")
            return
        }
        mapCoordinator?.updateCameraZoom(zoom, userLocation: userLocation)
    }

    // Particle count formatting and performance helpers
    private func formatParticleCount(_ count: Float) -> String {
        let intCount = Int(count)
        if intCount >= 1000 {
            return String(format: "%.0fK", count / 1000)
        } else {
            return "\(intCount)"
        }
    }

    private func getPerformanceIndicator(_ count: Float) -> String {
        switch count {
        case 0...15000:
            return "Fast"
        case 15001...50000:
            return "Balanced"
        case 50001...75000:
            return "Detailed"
        default:
            return "Intensive"
        }
    }

    private func getPerformanceColor(_ count: Float) -> Color {
        switch count {
        case 0...15000:
            return .green
        case 15001...50000:
            return .blue
        case 50001...75000:
            return .orange
        default:
            return .red
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
            
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
        }
        .padding()
        .background(Color.white)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

struct JourneyRow: View {
    let journey: JourneySession
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(journey.startTime, style: .date)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    if journey.isPublished {
                        Text("Published")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }
                
                HStack {
                    Text("Distance: \(JourneyPathStorage().formattedDistance(journey.totalDistance))")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    Text("•")
                        .foregroundColor(.gray)
                    
                    Text("Points: \(journey.coordinates.count)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    if let duration = journey.duration {
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Text("Duration: \(JourneyPathStorage().formattedDuration(duration))")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            
            Spacer()
            
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
    }
}
