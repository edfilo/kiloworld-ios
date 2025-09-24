//
//  JourneyPathStorage.swift
//  kiloworld
//
//  Journey and path tracking storage - now using UserSettings base class
//

import Foundation
import CoreLocation

struct JourneySession: Codable, Identifiable {
    let id: UUID
    let startTime: Date
    var endTime: Date?
    let coordinates: [StoredCoordinate]
    let totalDistance: Double
    var isPublished: Bool
    
    init(coordinates: [CLLocationCoordinate2D], totalDistance: Double) {
        self.id = UUID()
        self.startTime = Date()
        self.endTime = nil
        self.coordinates = coordinates.map { StoredCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        self.totalDistance = totalDistance
        self.isPublished = false
    }
    
    mutating func finish() {
        endTime = Date()
    }
    
    mutating func publish() {
        endTime = Date()
        isPublished = true
    }
    
    var duration: TimeInterval? {
        guard let endTime = endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }
    
    var clLocationCoordinates: [CLLocationCoordinate2D] {
        return coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
}

struct StoredCoordinate: Codable {
    let latitude: Double
    let longitude: Double
}

class JourneyPathStorage: ObservableObject {
    @Published var currentPath: [CLLocationCoordinate2D] = []
    @Published var allJourneys: [JourneySession] = []
    @Published var currentDistance: Double = 0.0
    
    private let userDefaults = UserDefaults.standard
    private let currentPathKey = "current_journey_path"
    private let allJourneysKey = "all_journey_sessions"
    private let currentDistanceKey = "current_journey_distance"
    
    init() {
        loadCurrentPath()
        loadAllJourneys()
        loadCurrentDistance()
    }
    
    // MARK: - Current Path Management
    
    func addCoordinate(_ coordinate: CLLocationCoordinate2D) {
        // Add point if it's far enough from the last point (avoid GPS jitter)
        if let lastPoint = currentPath.last {
            let lastLocation = CLLocation(latitude: lastPoint.latitude, longitude: lastPoint.longitude)
            let newLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let distance = lastLocation.distance(from: newLocation)
            
            if distance > 5.0 { // Only add if moved more than 5 meters
                currentPath.append(coordinate)
                currentDistance += distance
                saveCurrentPath()
                saveCurrentDistance()
                print("[storage] 📍 Added path point: distance=\(distance)m, total=\(currentPath.count), totalDistance=\(currentDistance)m")
            }
        } else {
            // First point
            currentPath.append(coordinate)
            saveCurrentPath()
            print("[storage] 📍 Added first path point")
        }
    }
    
    func publishCurrentJourney() {
        guard !currentPath.isEmpty else {
            print("[storage] ⚠️ No current path to publish")
            return
        }
        
        var session = JourneySession(coordinates: currentPath, totalDistance: currentDistance)
        session.publish()
        
        allJourneys.append(session)
        saveAllJourneys()
        
        // Clear current path
        clearCurrentPath()
        
        print("[storage] 📤 Published journey with \(session.coordinates.count) points, distance: \(session.totalDistance)m")
    }
    
    func clearCurrentPath() {
        currentPath.removeAll()
        currentDistance = 0.0
        saveCurrentPath()
        saveCurrentDistance()
        print("[storage] 🧹 Cleared current path")
    }
    
    // MARK: - Persistence
    
    private func saveCurrentPath() {
        let storedCoordinates = currentPath.map { StoredCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        if let data = try? JSONEncoder().encode(storedCoordinates) {
            userDefaults.set(data, forKey: currentPathKey)
        }
    }
    
    private func loadCurrentPath() {
        guard let data = userDefaults.data(forKey: currentPathKey),
              let storedCoordinates = try? JSONDecoder().decode([StoredCoordinate].self, from: data) else {
            print("[storage] 📱 No saved current path found")
            return
        }
        
        currentPath = storedCoordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        print("[storage] 📱 Loaded current path with \(currentPath.count) points")
    }
    
    private func saveCurrentDistance() {
        userDefaults.set(currentDistance, forKey: currentDistanceKey)
    }
    
    private func loadCurrentDistance() {
        currentDistance = userDefaults.double(forKey: currentDistanceKey)
        print("[storage] 📱 Loaded current distance: \(currentDistance)m")
    }
    
    private func saveAllJourneys() {
        if let data = try? JSONEncoder().encode(allJourneys) {
            userDefaults.set(data, forKey: allJourneysKey)
        }
    }
    
    private func loadAllJourneys() {
        guard let data = userDefaults.data(forKey: allJourneysKey),
              let journeys = try? JSONDecoder().decode([JourneySession].self, from: data) else {
            print("[storage] 📱 No saved journeys found")
            return
        }
        
        allJourneys = journeys
        print("[storage] 📱 Loaded \(allJourneys.count) saved journeys")
    }
    
    // MARK: - Computed Properties
    
    var totalPublishedDistance: Double {
        return allJourneys.filter { $0.isPublished }.reduce(0) { $0 + $1.totalDistance }
    }
    
    var totalJourneySessions: Int {
        return allJourneys.filter { $0.isPublished }.count
    }
    
    var averageJourneyDistance: Double {
        let publishedJourneys = allJourneys.filter { $0.isPublished }
        guard !publishedJourneys.isEmpty else { return 0 }
        return totalPublishedDistance / Double(publishedJourneys.count)
    }
    
    func deleteJourney(_ journey: JourneySession) {
        allJourneys.removeAll { $0.id == journey.id }
        saveAllJourneys()
        print("[storage] 🗑️ Deleted journey with \(journey.coordinates.count) points")
    }
    
    func formattedDistance(_ distance: Double) -> String {
        if distance < 1000 {
            return String(format: "%.0fm", distance)
        } else {
            return String(format: "%.2fkm", distance / 1000)
        }
    }
    
    func formattedDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration / 3600)
        let minutes = Int((duration.truncatingRemainder(dividingBy: 3600)) / 60)
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}