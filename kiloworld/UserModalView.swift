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
    let mapCoordinator: CustomMapView.Coordinator?
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
    let onSessionClear: () -> Void // Callback to clear session data
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

                    // Current Journey Section
                    currentJourneySection

                    // Statistics Section
                    statisticsSection

                    // All Journeys Section
                    allJourneysSection

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
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
                        onSessionClear() // Clear chat and creative session
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
                            onSessionClear() // Clear chat and creative session
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.green)
                        .cornerRadius(6)
                        .disabled(pathStorage.currentPath.isEmpty)
                        
                        Button("Clear Only") {
                            pathStorage.clearCurrentPath()
                            onSessionClear() // Clear chat and creative session
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
            return "Intense"
        default:
            return "Extreme"
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

    // Helper view for StatCard
    private func StatCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .center, spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text(value)
                .font(.headline)
                .fontWeight(.bold)
        }
        .padding()
        .background(Color.white)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }

    // Helper view for JourneyRow
    private func JourneyRow(journey: JourneySession, onDelete: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Journey \(journey.id.uuidString.prefix(8))")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.black)

                if let duration = journey.duration {
                    Text("Duration: \(pathStorage.formattedDuration(duration))")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

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
