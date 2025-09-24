//
//  SkyGateRecognizer.swift
//  kiloworld
//
//  Created by Claude on 9/22/25.
//

import UIKit
import MapboxMaps

// MARK: - SkyGateRecognizer
final class SkyGateRecognizer: UIGestureRecognizer {
    
    private weak var mapLoaded: AnyObject?
    private weak var metalSynth: MetalWavetableSynth?
    private var onSkyTouchCountChanged: ((Int) -> Void)?
    private weak var hologramCoordinator: AnyObject? // Store as AnyObject to avoid circular imports
    
    private var activeTouches: Set<UITouch> = []
    private var synthNotes: [UITouch: Int] = [:]
    private var touchVoices: [UITouch: Int] = [:]
    
    init(mapLoaded: AnyObject, metalSynth: MetalWavetableSynth?, onSkyTouchCountChanged: @escaping (Int) -> Void) {
        self.mapLoaded = mapLoaded
        self.metalSynth = metalSynth
        self.onSkyTouchCountChanged = onSkyTouchCountChanged
        super.init(target: nil, action: nil)
        
        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
        
        print("[map] 🚪 SkyGateRecognizer initialized with mapLoaded: \(mapLoaded) and synth: \(metalSynth != nil ? "✅" : "❌")")
    }
    
    // Method to update the synth after initialization
    func updateMetalSynth(_ newSynth: MetalWavetableSynth?) {
        self.metalSynth = newSynth
        print("[map] 🔄 SkyGateRecognizer synth updated: \(newSynth != nil ? "✅" : "❌")")
    }
    
    // Method to update the hologram coordinator after initialization
    func updateHologramCoordinator(_ coordinator: AnyObject?) {
        self.hologramCoordinator = coordinator
        print("[map] 🌌 SkyGateRecognizer hologram coordinator updated: \(coordinator != nil ? "✅" : "❌")")
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("[map] 🚪 SkyGateRecognizer.touchesBegan called with \(touches.count) touches")
        
        // Close keyboard when touching map or sky
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        guard let view = self.view else { return }
        
        for touch in touches {
            let location = touch.location(in: view)
            
            // Check if touch is in "sky" area (upper 40% of screen)
            let skyThreshold = view.bounds.height * 0.4
            
            if location.y <= skyThreshold {
                print("[map] 🌌 SKY TOUCH detected at y=\(location.y) (threshold=\(skyThreshold))")
                
                activeTouches.insert(touch)
                
                // Start synth note if synth is available
                if let metalSynth = metalSynth {
                    let noteNumber = calculateNoteFromPosition(location, in: view)
                    
                    // Find an available voice or use polyphonic allocation
                    let voiceIndex = metalSynth.findAvailableVoice() ?? 0
                    
                    metalSynth.noteOnWithVoice(voiceIndex: voiceIndex, noteNumber: noteNumber, velocity: 0.7, wavetablePosition: Float(location.x / view.bounds.width))
                    synthNotes[touch] = noteNumber
                    touchVoices[touch] = voiceIndex
                    print("[map] 🎵 Started note \(noteNumber) on voice \(voiceIndex) for sky touch with synth: ✅")
                } else {
                    print("[map] ❌ No metalSynth available for sky touch!")
                }
                
                // Control hologram if available
                if let hologramCoordinator = hologramCoordinator {
                    // Use perform selector to call the method without direct import
                    if hologramCoordinator.responds(to: Selector(("onSkyTouchBegan:in:"))) {
                        hologramCoordinator.perform(Selector(("onSkyTouchBegan:in:")), with: NSValue(cgPoint: location), with: view)
                        print("[map] 🌌 Triggered hologram sky touch began")
                    }
                }
                
                // Block ALL gestures and events when in sky - no map activity at all
                self.state = .began
                
                // Cancel the touch event entirely to prevent any map/location updates
                self.cancelsTouchesInView = true
                
            } else {
                print("[map] 🗺️ GROUND TOUCH detected at y=\(location.y) (threshold=\(skyThreshold))")
                // Allow map touches to pass through normally
                self.cancelsTouchesInView = false
                if let event = event {
                    self.ignore(touch, for: event)
                }
            }
        }
        
        // Update touch count
        onSkyTouchCountChanged?(activeTouches.count)
        
        if activeTouches.isEmpty {
            // No sky touches, fail the recognizer to allow map gestures
            self.state = .failed
            self.cancelsTouchesInView = false
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("[map] 🚪 SkyGateRecognizer.touchesMoved called with \(touches.count) touches, state: \(state.rawValue)")
        
        guard let view = self.view else { return }
        
        for touch in touches {
            if activeTouches.contains(touch) {
                let location = touch.location(in: view)
                
                // Calculate new note based on current position
                let newNoteNumber = calculateNoteFromPosition(location, in: view)
                let wavetablePos = Float(location.x / view.bounds.width)
                
                // Update synth note if available - use portamento instead of hard transitions
                if let currentNoteNumber = synthNotes[touch], 
                   let voiceIndex = touchVoices[touch],
                   let metalSynth = metalSynth {
                    
                    // Always update the voice with new pitch and wavetable position
                    // Use portamento/glide for smooth pitch transitions
                    metalSynth.updateVoicePitch(voiceIndex: voiceIndex, noteNumber: newNoteNumber, wavetablePosition: wavetablePos)
                    synthNotes[touch] = newNoteNumber
                    
                    if newNoteNumber != currentNoteNumber {
                        print("[map] 🎵 SKY PITCH GLIDE: \(currentNoteNumber) → \(newNoteNumber) on voice \(voiceIndex)")
                    } else {
                        print("[map] 🎵 Updated SKY voice \(voiceIndex) wavetable: \(wavetablePos)")
                    }
                } else if synthNotes[touch] != nil {
                    print("[map] ❌ SKY move but no metalSynth available!")
                }
                
                // Update hologram if available
                if let hologramCoordinator = hologramCoordinator {
                    if hologramCoordinator.responds(to: Selector(("onSkyTouchMoved:in:"))) {
                        hologramCoordinator.perform(Selector(("onSkyTouchMoved:in:")), with: NSValue(cgPoint: location), with: view)
                    }
                }
                
                self.state = .changed
            }
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("[map] 🚪 SkyGateRecognizer.touchesEnded called with \(touches.count) touches, state: \(state.rawValue)")
        
        for touch in touches {
            if activeTouches.contains(touch) {
                activeTouches.remove(touch)
                
                // End synth note if available - release specific voice
                if let noteNumber = synthNotes[touch], 
                   let voiceIndex = touchVoices[touch],
                   let metalSynth = metalSynth {
                    
                    metalSynth.noteOffVoice(voiceIndex: voiceIndex)
                    synthNotes.removeValue(forKey: touch)
                    touchVoices.removeValue(forKey: touch)
                    print("[map] 🎵 Released SKY voice \(voiceIndex) (note \(noteNumber)) - envelope will complete release")
                } else if synthNotes[touch] != nil {
                    print("[map] ❌ SKY end but no metalSynth available!")
                }
                
                // End hologram effect if this was the last touch
                if activeTouches.count == 1 { // Will become 0 after removal
                    if let hologramCoordinator = hologramCoordinator {
                        if hologramCoordinator.responds(to: Selector(("onSkyTouchEnded"))) {
                            hologramCoordinator.perform(Selector(("onSkyTouchEnded")))
                        }
                    }
                }
            }
        }
        
        // Update touch count
        onSkyTouchCountChanged?(activeTouches.count)
        
        if activeTouches.isEmpty {
            self.state = .ended
        }
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("[map] 🚪 SkyGateRecognizer.touchesCancelled called with \(touches.count) touches, state: \(state.rawValue)")
        
        for touch in touches {
            if activeTouches.contains(touch) {
                activeTouches.remove(touch)
                
                // End synth note if available - release specific voice
                if let noteNumber = synthNotes[touch], 
                   let voiceIndex = touchVoices[touch],
                   let metalSynth = metalSynth {
                    
                    metalSynth.noteOffVoice(voiceIndex: voiceIndex)
                    synthNotes.removeValue(forKey: touch)
                    touchVoices.removeValue(forKey: touch)
                    print("[map] 🎵 Cancelled SKY voice \(voiceIndex) (note \(noteNumber)) - envelope will complete release")
                }
            }
        }
        
        // Update touch count
        onSkyTouchCountChanged?(activeTouches.count)
        
        self.state = .cancelled
    }
    
    private func calculateNoteFromPosition(_ location: CGPoint, in view: UIView) -> Int {
        // Convert location to normalized coordinates
        let x = Float(location.x / view.bounds.width)
        let y = Float(location.y / view.bounds.height)
        
        // Use same celestial scale logic
        let celestialScale = [0, 2, 4, 7, 9] // Pentatonic major
        let baseNote = 60 // Middle C
        
        // Y controls octave shift (inverted since y=0 is top)
        let octaveShift = Int((1.0 - y) * 24.0 - 12.0) // Range: -12 to +12 semitones
        
        // X selects note within scale
        let scaleIndex = Int(x * Float(celestialScale.count - 1))
        let noteOffset = celestialScale[scaleIndex]
        
        let midiNote = baseNote + octaveShift + noteOffset
        let finalNote = max(0, min(127, midiNote))
        
        print("[map] 🎵 [DEBUG] Touch at x=\(String(format: "%.2f", x)), y=\(String(format: "%.2f", y)) -> MIDI note \(finalNote) (base: \(baseNote), octave: \(octaveShift), scale: \(noteOffset))")
        
        return finalNote
    }
}