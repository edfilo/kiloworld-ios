//
//  UserSettings.swift
//  kiloworld
//
//  Simple settings storage for UI preferences
//

import Foundation
import SwiftUI

class UserSettings: ObservableObject {
    private let userDefaults = UserDefaults.standard
    
    // MARK: - UI Layout Settings
    
    @Published var topPadding: Float = 44.0 {
        didSet { userDefaults.set(topPadding, forKey: "top_padding") }
    }
    
    @Published var pixelSize: Float = 1.0 {
        didSet { userDefaults.set(pixelSize, forKey: "pixel_size") }
    }
    
    // MARK: - Hologram Settings
    
    @Published var hologramRotation: Float = 0.0 {
        didSet { userDefaults.set(hologramRotation, forKey: "hologram_rotation") }
    }
    
    @Published var hologramRotSpeed: Float = 0.6 {
        didSet { userDefaults.set(hologramRotSpeed, forKey: "hologram_rot_speed") }
    }
    
    @Published var hologramSize: Float = 0.4 {
        didSet { userDefaults.set(hologramSize, forKey: "hologram_size") }
    }
    
    @Published var hologramZoom: Float = 0.5 {
        didSet { userDefaults.set(hologramZoom, forKey: "hologram_zoom") }
    }
    
    @Published var hologramDepth: Float = 0.0 {
        didSet { userDefaults.set(hologramDepth, forKey: "hologram_depth") }
    }
    
    @Published var hologramBgHide: Float = 1.0 {
        didSet { userDefaults.set(hologramBgHide, forKey: "hologram_bg_hide") }
    }
    
    @Published var hologramDissolve: Float = 0.0 {
        didSet { userDefaults.set(hologramDissolve, forKey: "hologram_dissolve") }
    }
    
    @Published var hologramWobble: Float = 0.0 {
        didSet { userDefaults.set(hologramWobble, forKey: "hologram_wobble") }
    }
    
    @Published var hologramYPosition: Float = 0.0 {
        didSet { userDefaults.set(hologramYPosition, forKey: "hologram_y_position") }
    }

    @Published var hologramParticleCount: Float = 30000.0 {
        didSet { userDefaults.set(hologramParticleCount, forKey: "hologram_particle_count") }
    }
    
    // MARK: - Initialization
    
    init() {
        loadSettings()
        print("[settings] 📱 UserSettings initialized with saved preferences")
    }
    
    // MARK: - Load Settings
    
    private func loadSettings() {
        if userDefaults.object(forKey: "top_padding") != nil {
            topPadding = userDefaults.float(forKey: "top_padding")
        }
        if userDefaults.object(forKey: "pixel_size") != nil {
            pixelSize = userDefaults.float(forKey: "pixel_size")
        }
        
        // Load hologram settings
        if userDefaults.object(forKey: "hologram_rotation") != nil {
            hologramRotation = userDefaults.float(forKey: "hologram_rotation")
        }
        if userDefaults.object(forKey: "hologram_rot_speed") != nil {
            hologramRotSpeed = userDefaults.float(forKey: "hologram_rot_speed")
        }
        if userDefaults.object(forKey: "hologram_size") != nil {
            hologramSize = userDefaults.float(forKey: "hologram_size")
        }
        if userDefaults.object(forKey: "hologram_zoom") != nil {
            hologramZoom = userDefaults.float(forKey: "hologram_zoom")
        }
        if userDefaults.object(forKey: "hologram_depth") != nil {
            hologramDepth = userDefaults.float(forKey: "hologram_depth")
        }
        if userDefaults.object(forKey: "hologram_bg_hide") != nil {
            hologramBgHide = userDefaults.float(forKey: "hologram_bg_hide")
        }
        if userDefaults.object(forKey: "hologram_dissolve") != nil {
            hologramDissolve = userDefaults.float(forKey: "hologram_dissolve")
        }
        if userDefaults.object(forKey: "hologram_wobble") != nil {
            hologramWobble = userDefaults.float(forKey: "hologram_wobble")
        }
        if userDefaults.object(forKey: "hologram_y_position") != nil {
            hologramYPosition = userDefaults.float(forKey: "hologram_y_position")
        }
        if userDefaults.object(forKey: "hologram_particle_count") != nil {
            hologramParticleCount = userDefaults.float(forKey: "hologram_particle_count")
        }
        
        print("[settings] 📱 Loaded UI settings and hologram controls")
    }
    
    // MARK: - Utility Methods
    
    func resetToDefaults() {
        topPadding = 44.0
        pixelSize = 1.0
        hologramRotation = 0.0
        hologramRotSpeed = 0.6
        hologramSize = 0.4
        hologramZoom = 0.5
        hologramDepth = 0.0
        hologramBgHide = 1.0
        hologramDissolve = 0.0
        hologramWobble = 0.0
        hologramYPosition = 0.0
        hologramParticleCount = 30000.0
        print("[settings] 🔄 Reset to default settings")
    }
}