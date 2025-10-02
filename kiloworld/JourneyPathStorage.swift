//
//  JourneyPathStorage.swift
//  kiloworld
//
//  Journey and path tracking storage - now using UserSettings base class
//

import Foundation
import CoreLocation
import UIKit

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

struct PathSegment: Codable, Identifiable {
    let id: UUID
    var coordinates: [StoredCoordinate]
    var distance: Double

    init(coordinates: [CLLocationCoordinate2D], distance: Double) {
        self.id = UUID()
        self.coordinates = coordinates.map { StoredCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        self.distance = distance
    }

    var clLocationCoordinates: [CLLocationCoordinate2D] {
        return coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
}

class JourneyPathStorage: ObservableObject {
    @Published var currentPathSegments: [PathSegment] = []  // Multiple active path segments
    @Published var allJourneys: [JourneySession] = []
    @Published var currentDistance: Double = 0.0

    private let userDefaults = UserDefaults.standard
    private let currentSegmentsKey = "current_path_segments"
    private let allJourneysKey = "all_journey_sessions"
    private let currentDistanceKey = "current_journey_distance"
    private let lastLocationTimeKey = "last_location_time"

    private var lastLocationTime: Date?
    private let minSegmentDistance: Double = 50.0  // Minimum distance to create new segment
    private let gapTimeThreshold: TimeInterval = 300  // 5 minutes - start new segment if gap is longer

    init() {
        loadCurrentSegments()
        loadAllJourneys()
        loadCurrentDistance()
        loadLastLocationTime()
        setupAppLifecycleObservers()
    }

    // MARK: - Current Path Management

    var currentPath: [CLLocationCoordinate2D] {
        return currentPathSegments.flatMap { $0.clLocationCoordinates }
    }

    func addCoordinate(_ coordinate: CLLocationCoordinate2D) {
        let now = Date()

        // Check if there's been a significant time gap - start new segment but DON'T reset
        var shouldStartNewSegment = false
        if let lastTime = lastLocationTime {
            let timeGap = now.timeIntervalSince(lastTime)
            if timeGap > gapTimeThreshold {
                print("[storage] ⏰ Time gap detected: \(timeGap)s > \(gapTimeThreshold)s - will start new segment")
                shouldStartNewSegment = true
            }
        }

        // Get or create current active segment
        var currentSegment: PathSegment
        var segmentDistance: Double = 0.0

        if shouldStartNewSegment || currentPathSegments.isEmpty {
            // Start a new segment
            currentSegment = PathSegment(coordinates: [], distance: 0.0)
            segmentDistance = 0.0
        } else {
            // Continue existing segment
            currentSegment = currentPathSegments.removeLast()
            segmentDistance = currentSegment.distance
        }

        // Add point if it's far enough from the last point (avoid GPS jitter)
        let coords = currentSegment.clLocationCoordinates
        if let lastPoint = coords.last {
            let lastLocation = CLLocation(latitude: lastPoint.latitude, longitude: lastPoint.longitude)
            let newLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let distance = lastLocation.distance(from: newLocation)

            if distance > 5.0 {
                let storedCoord = StoredCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
                currentSegment.coordinates.append(storedCoord)
                currentSegment.distance += distance
                currentDistance += distance
                currentPathSegments.append(currentSegment)
                saveCurrentSegments()
                saveCurrentDistance()
                print("[storage] 📍 Added point: segment=\(currentPathSegments.count), points=\(currentSegment.coordinates.count), dist=\(distance)m")
            } else {
                currentPathSegments.append(currentSegment)
            }
        } else {
            // First point in this segment
            let storedCoord = StoredCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
            currentSegment.coordinates.append(storedCoord)
            currentPathSegments.append(currentSegment)
            saveCurrentSegments()
            print("[storage] 📍 Started new segment #\(currentPathSegments.count)")
        }

        lastLocationTime = now
        saveLastLocationTime()
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

        clearCurrentPath()

        print("[storage] 📤 Published journey with \(session.coordinates.count) points, distance: \(session.totalDistance)m")
    }

    func clearCurrentPath() {
        currentPathSegments.removeAll()
        currentDistance = 0.0
        lastLocationTime = nil
        saveCurrentSegments()
        saveCurrentDistance()
        saveLastLocationTime()
        print("[storage] 🧹 Cleared all path segments")
    }
    
    // MARK: - Persistence

    private func saveCurrentSegments() {
        if let data = try? JSONEncoder().encode(currentPathSegments) {
            userDefaults.set(data, forKey: currentSegmentsKey)
        }
    }

    private func loadCurrentSegments() {
        guard let data = userDefaults.data(forKey: currentSegmentsKey),
              let segments = try? JSONDecoder().decode([PathSegment].self, from: data) else {
            print("[storage] 📱 No saved path segments found")
            return
        }

        currentPathSegments = segments
        print("[storage] 📱 Loaded \(currentPathSegments.count) path segments")
    }
    
    private func saveCurrentDistance() {
        userDefaults.set(currentDistance, forKey: currentDistanceKey)
    }
    
    private func loadCurrentDistance() {
        currentDistance = userDefaults.double(forKey: currentDistanceKey)
        print("[storage] 📱 Loaded current distance: \(currentDistance)m")
    }

    private func saveLastLocationTime() {
        if let time = lastLocationTime {
            userDefaults.set(time.timeIntervalSince1970, forKey: lastLocationTimeKey)
        } else {
            userDefaults.removeObject(forKey: lastLocationTimeKey)
        }
    }

    private func loadLastLocationTime() {
        let timeInterval = userDefaults.double(forKey: lastLocationTimeKey)
        if timeInterval > 0 {
            lastLocationTime = Date(timeIntervalSince1970: timeInterval)
            print("[storage] 📱 Loaded last location time: \(lastLocationTime!)")
        }
    }

    private func setupAppLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onAppWillBackground()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onAppDidForeground()
        }
    }

    private func onAppWillBackground() {
        saveCurrentSegments()
        saveCurrentDistance()
        saveLastLocationTime()
        print("[storage] 📱 App backgrounded - saved \(currentPathSegments.count) segments")
    }

    private func onAppDidForeground() {
        if let lastTime = lastLocationTime {
            let timeGap = Date().timeIntervalSince(lastTime)
            if timeGap > gapTimeThreshold {
                print("[storage] 📱 App foregrounded after \(timeGap)s - will start new segment on next location")
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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