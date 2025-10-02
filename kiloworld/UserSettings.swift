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
    
    @Published var hologramBgMin: Float = 0.0 {
        didSet { userDefaults.set(hologramBgMin, forKey: "hologram_bg_min") }
    }

    @Published var hologramBgMax: Float = 1.0 {
        didSet { userDefaults.set(hologramBgMax, forKey: "hologram_bg_max") }
    }
    
    @Published var arcRadius: Float = 100.0 {
        didSet { userDefaults.set(arcRadius, forKey: "arc_radius")}
    }
    
    @Published var hologramDissolve: Float = 0.0 {
        didSet { userDefaults.set(hologramDissolve, forKey: "hologram_dissolve") }
    }
    
    @Published var hologramWobble: Float = 0.0 {
        didSet { userDefaults.set(hologramWobble, forKey: "hologram_wobble") }
    }

    @Published var hologramWobbleSpeed: Float = 1.0 {
        didSet { userDefaults.set(hologramWobbleSpeed, forKey: "hologram_wobble_speed") }
    }

    @Published var hologramYPosition: Float = 0.0 {
        didSet { userDefaults.set(hologramYPosition, forKey: "hologram_y_position") }
    }

    @Published var hologramParticleCount: Float = 30000.0 {
        didSet { userDefaults.set(hologramParticleCount, forKey: "hologram_particle_count") }
    }

    @Published var hologramEmissionDensity: Float = 0.08 {
        didSet { userDefaults.set(hologramEmissionDensity, forKey: "hologram_emission_density") }
    }

    @Published var hologramEmissionSpeed: Float = 0.5 {
        didSet { userDefaults.set(hologramEmissionSpeed, forKey: "hologram_emission_speed") }
    }

    @Published var particleBlink: Float = 0.0 {
        didSet { userDefaults.set(particleBlink, forKey: "particle_blink") }
    }

    @Published var particleRandomSize: Float = 0.0 {
        didSet { userDefaults.set(particleRandomSize, forKey: "particle_random_size") }
    }

    @Published var particleGlow: Float = 0.0 {
        didSet { userDefaults.set(particleGlow, forKey: "particle_glow") }
    }

    @Published var horizonWidth: Float = 0.4 {
        didSet { userDefaults.set(horizonWidth, forKey: "horizon_width") }
    }

    @Published var horizonStart: Float = 2.0 {
        didSet { userDefaults.set(horizonStart, forKey: "horizon_start") }
    }

    @Published var horizonFeather: Float = 0.06 {
        didSet { userDefaults.set(horizonFeather, forKey: "horizon_feather") }
    }

    // MARK: - Synth ADSR Settings

    @Published var synthAttack: Float = 0.1 {
        didSet { userDefaults.set(synthAttack, forKey: "synth_attack") }
    }

    @Published var synthDecay: Float = 0.3 {
        didSet { userDefaults.set(synthDecay, forKey: "synth_decay") }
    }

    @Published var synthSustain: Float = 0.7 {
        didSet { userDefaults.set(synthSustain, forKey: "synth_sustain") }
    }

    @Published var synthRelease: Float = 0.5 {
        didSet { userDefaults.set(synthRelease, forKey: "synth_release") }
    }

    // MARK: - Audio Playback Settings

    @Published var audioPlaybackPitch: Float = 1.0 {
        didSet { userDefaults.set(audioPlaybackPitch, forKey: "audio_playback_pitch") }
    }

    @Published var audioPlaybackSpeed: Float = 1.0 {
        didSet { userDefaults.set(audioPlaybackSpeed, forKey: "audio_playback_speed") }
    }

    @Published var audioPlaybackVarispeed: Float = 1.0 {
        didSet { userDefaults.set(audioPlaybackVarispeed, forKey: "audio_playback_varispeed") }
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
        if userDefaults.object(forKey: "hologram_bg_min") != nil {
            hologramBgMin = userDefaults.float(forKey: "hologram_bg_min")
        }
        if userDefaults.object(forKey: "hologram_bg_max") != nil {
            hologramBgMax = userDefaults.float(forKey: "hologram_bg_max")
        }
        if userDefaults.object(forKey: "arc_radius") != nil {
            arcRadius = userDefaults.float(forKey: "arc_radius")
        }
        if userDefaults.object(forKey: "hologram_dissolve") != nil {
            hologramDissolve = userDefaults.float(forKey: "hologram_dissolve")
        }
        if userDefaults.object(forKey: "hologram_wobble") != nil {
            hologramWobble = userDefaults.float(forKey: "hologram_wobble")
        }
        if userDefaults.object(forKey: "hologram_wobble_speed") != nil {
            hologramWobbleSpeed = userDefaults.float(forKey: "hologram_wobble_speed")
        }
        if userDefaults.object(forKey: "hologram_y_position") != nil {
            hologramYPosition = userDefaults.float(forKey: "hologram_y_position")
        }
        if userDefaults.object(forKey: "hologram_particle_count") != nil {
            hologramParticleCount = userDefaults.float(forKey: "hologram_particle_count")
        }
        if userDefaults.object(forKey: "hologram_emission_density") != nil {
            hologramEmissionDensity = userDefaults.float(forKey: "hologram_emission_density")
        }
        if userDefaults.object(forKey: "hologram_emission_speed") != nil {
            hologramEmissionSpeed = userDefaults.float(forKey: "hologram_emission_speed")
        }
        if userDefaults.object(forKey: "particle_blink") != nil {
            particleBlink = userDefaults.float(forKey: "particle_blink")
        }
        if userDefaults.object(forKey: "particle_random_size") != nil {
            particleRandomSize = userDefaults.float(forKey: "particle_random_size")
        }
        if userDefaults.object(forKey: "particle_glow") != nil {
            particleGlow = userDefaults.float(forKey: "particle_glow")
        }
        if userDefaults.object(forKey: "horizon_width") != nil {
            horizonWidth = userDefaults.float(forKey: "horizon_width")
        }
        if userDefaults.object(forKey: "horizon_start") != nil {
            horizonStart = userDefaults.float(forKey: "horizon_start")
        }
        if userDefaults.object(forKey: "horizon_feather") != nil {
            horizonFeather = userDefaults.float(forKey: "horizon_feather")
        }
        if userDefaults.object(forKey: "synth_attack") != nil {
            synthAttack = userDefaults.float(forKey: "synth_attack")
        }
        if userDefaults.object(forKey: "synth_decay") != nil {
            synthDecay = userDefaults.float(forKey: "synth_decay")
        }
        if userDefaults.object(forKey: "synth_sustain") != nil {
            synthSustain = userDefaults.float(forKey: "synth_sustain")
        }
        if userDefaults.object(forKey: "synth_release") != nil {
            synthRelease = userDefaults.float(forKey: "synth_release")
        }
        if userDefaults.object(forKey: "audio_playback_pitch") != nil {
            audioPlaybackPitch = userDefaults.float(forKey: "audio_playback_pitch")
        }
        if userDefaults.object(forKey: "audio_playback_speed") != nil {
            audioPlaybackSpeed = userDefaults.float(forKey: "audio_playback_speed")
        }
        if userDefaults.object(forKey: "audio_playback_varispeed") != nil {
            audioPlaybackVarispeed = userDefaults.float(forKey: "audio_playback_varispeed")
        }

        print("[settings] 📱 Loaded ADSR: A=\(synthAttack) D=\(synthDecay) S=\(synthSustain) R=\(synthRelease)")
        print("[settings] 📱 Loaded Audio Playback: Pitch=\(audioPlaybackPitch) Speed=\(audioPlaybackSpeed) Varispeed=\(audioPlaybackVarispeed)")
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
        hologramBgMin = 0.0
        hologramBgMax = 1.0
        arcRadius = 100.0
        hologramDissolve = 0.0
        hologramWobble = 0.0
        hologramWobbleSpeed = 1.0
        hologramYPosition = 0.0
        hologramParticleCount = 30000.0
        hologramEmissionDensity = 0.08
        hologramEmissionSpeed = 0.5
        particleBlink = 0.0
        particleRandomSize = 0.0
        particleGlow = 0.0
        horizonWidth = 0.4
        horizonStart = 2.0
        horizonFeather = 0.06
        synthAttack = 0.1
        synthDecay = 0.3
        synthSustain = 0.7
        synthRelease = 0.5
        audioPlaybackPitch = 1.0
        audioPlaybackSpeed = 1.0
        audioPlaybackVarispeed = 1.0
        print("[settings] 🔄 Reset to default settings")
    }
}
