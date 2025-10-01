//
//  LocationManager.swift
//  kiloworld
//
//  Created by Claude on 9/22/25.
//

import Foundation
import CoreLocation
import CoreMotion
import Combine

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let motionActivityManager = CMMotionActivityManager()
    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isTracking: Bool = false
    @Published var currentCourse: Double = 0.0 // Direction of travel in degrees
    @Published var currentHeading: Double = 0.0 // Compass heading in degrees
    @Published var currentActivity: CMMotionActivity? = nil
    @Published var isValidFitnessActivity: Bool = true // Whether current activity is walking/running
    
    // Callback for continuous location updates
    var onLocationUpdate: ((CLLocationCoordinate2D) -> Void)?
    
    // Callback for course/heading updates
    var onCourseUpdate: ((Double) -> Void)?
    
    // Callback for compass heading updates
    var onHeadingUpdate: ((Double) -> Void)?
    
    // Callback for activity validation changes
    var onActivityValidationChanged: ((Bool, String) -> Void)?
    
    // Reference to the journey path storage
    weak var pathStorage: JourneyPathStorage?
    
    // Callback for initial location (used to center map)
    var onInitialLocationReceived: ((CLLocationCoordinate2D) -> Void)?
    private var hasReceivedInitialLocation = false
    
    override init() {
        super.init()
        locationManager.delegate = self
        
        // Optimize for walking/running with battery efficiency
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation // Best for continuous tracking
        locationManager.distanceFilter = 2.0 // 2 meters - good balance for walking/running
        locationManager.activityType = .fitness // Optimized for walking/running
        locationManager.pausesLocationUpdatesAutomatically = true // Auto-pause when not moving
        
        // Always start tracking immediately for fitness apps
        requestLocationPermission()
        startAlwaysOnTracking()
        
        // Start motion activity monitoring for anti-cheat
        startActivityMonitoring()
        
        // Start compass heading updates
        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
            print("[location] 🧭 Started compass heading updates")
        }
    }
    
    func requestLocationPermission() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            print("[location] Location access denied")
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        @unknown default:
            break
        }
    }
    
    func requestLocation() {
        guard locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways else {
            print("[location] Location not authorized")
            return
        }
        locationManager.requestLocation()
    }
    
    // Start continuous high-accuracy tracking
    func startContinuousTracking() {
        guard locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways else {
            print("[location] Location not authorized for continuous tracking")
            return
        }
        
        isTracking = true
        locationManager.startUpdatingLocation()
        print("[location] 🎯 Started continuous tracking (best accuracy, 0.5m filter)")
    }
    
    // Stop continuous tracking
    func stopContinuousTracking() {
        isTracking = false
        locationManager.stopUpdatingLocation()
        print("[location] 🛑 Stopped continuous tracking")
    }
    
    // Always-on efficient tracking for walking/running
    func startAlwaysOnTracking() {
        guard locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways else {
            print("[location] 📱 Waiting for location authorization for always-on tracking")
            return
        }
        
        isTracking = true
        locationManager.startUpdatingLocation()
        print("[location] 🏃 Started always-on fitness tracking (2m filter, auto-pause enabled)")
    }
    
    // MARK: - CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        // Filter out old or inaccurate locations
        let age = abs(location.timestamp.timeIntervalSinceNow)
        if age > 5.0 { // Ignore locations older than 5 seconds
            print("[location] ⚠️ Ignoring old location (age: \(age)s)")
            return
        }
        
        if location.horizontalAccuracy > 20.0 { // More permissive accuracy threshold
            print("[location] ⚠️ Ignoring inaccurate location (accuracy: \(location.horizontalAccuracy)m)")
            return
        }
        
        currentLocation = location
        
        // Track course/heading changes for map bearing
        if location.course >= 0 && location.speed > 0.3 { // Lower speed threshold (0.3 m/s = slow walking)
            let newCourse = location.course
            if abs(newCourse - currentCourse) > 5.0 { // Lower degree threshold (5 degrees for more responsive)
                currentCourse = newCourse
                onCourseUpdate?(newCourse)
                print("[location] 🧭 Course updated: \(String(format: "%.1f", newCourse))° (speed: \(String(format: "%.1f", location.speed)) m/s)")
            }
        } else {
            print("[location] ⏸️ Not updating course: speed=\(String(format: "%.1f", location.speed)) m/s, course=\(location.course)")
        }
        
        // Track that we've received initial location (for reference)
        if !hasReceivedInitialLocation {
            hasReceivedInitialLocation = true
            print("[location] 🎯 First location received: \(location.coordinate)")
        }
        
        if isTracking {
            print("[location] 📍 High-accuracy update: \(location.coordinate), accuracy: \(String(format: "%.1f", location.horizontalAccuracy))m")
            onLocationUpdate?(location.coordinate)
            
            // Only save to path storage if activity is valid for fitness (anti-cheat)
            if isValidFitnessActivity {
                pathStorage?.addCoordinate(location.coordinate)
            } else {
                print("[location] 🚫 Path tracking skipped - not walking/running activity")
            }
        } else {
            print("[location] 📍 Location updated: \(location.coordinate)")
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[location] Location error: \(error)")
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        authorizationStatus = status
        print("[location] Authorization status changed: \(status)")
        
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            // Start always-on tracking when permission is granted
            startAlwaysOnTracking()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else {
            print("[location] ⚠️ Ignoring inaccurate heading (accuracy: \(newHeading.headingAccuracy))")
            return
        }
        
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        
        if abs(heading - currentHeading) > 2.0 { // More responsive - update every 2 degrees
            currentHeading = heading
            onHeadingUpdate?(heading)
            // Compass heading updated
        }
    }
    
    // MARK: - Core Motion Activity Monitoring (Anti-Cheat)
    
    private func startActivityMonitoring() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            print("[location] ⚠️ Motion activity not available on this device")
            return
        }
        
        motionActivityManager.startActivityUpdates(to: OperationQueue.main) { [weak self] activity in
            guard let self = self, let activity = activity else { return }
            
            self.currentActivity = activity
            let wasValid = self.isValidFitnessActivity
            
            // Determine if activity is valid for fitness tracking (strict anti-cheat)
            self.isValidFitnessActivity = (activity.walking || activity.running) && !activity.automotive
            
            let activityString = self.getActivityString(activity)
            
            if wasValid != self.isValidFitnessActivity {
                self.onActivityValidationChanged?(self.isValidFitnessActivity, activityString)
                
                if self.isValidFitnessActivity {
                    print("[location] ✅ Valid fitness activity: \(activityString)")
                } else {
                    print("[location] 🚫 Invalid activity: \(activityString) - path tracking blocked")
                }
            }
        }
        
        print("[location] 🏃 Started motion activity monitoring (anti-cheat enabled)")
    }
    
    private func getActivityString(_ activity: CMMotionActivity) -> String {
        var activities: [String] = []
        if activity.walking { activities.append("walking") }
        if activity.running { activities.append("running") }
        if activity.cycling { activities.append("cycling") }
        if activity.automotive { activities.append("driving") }
        if activity.stationary { activities.append("stationary") }
        if activity.unknown { activities.append("unknown") }
        
        return activities.isEmpty ? "unknown" : activities.joined(separator: ", ")
    }
    
    func stopActivityMonitoring() {
        motionActivityManager.stopActivityUpdates()
        print("[location] 🛑 Stopped motion activity monitoring")
    }
}