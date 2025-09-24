//
//  SynthesizerView.swift
//  kiloworld
//
//  Created by Claude on 9/22/25.
//

import SwiftUI
import Metal

struct SynthesizerView: View {
    // Synthesizer controls
    @State var wavetablePosition: Float = 0.0
    @State var filterCutoff: Float = 8000.0
    @State var synthVolume: Float = 0.5
    @State var lfoRate: Float = 2.0
    @State var synthEnabled: Bool = false
    
    // Track active synth notes for proper note-off - support polyphony
    @State private var activeSynthNotes: [Int: Int] = [:] // Map note numbers to voice IDs
    @State private var nextVoiceID: Int = 0
    
    // Track active sky touches from SkyGateRecognizer
    @Binding var activeSkyTouches: Int
    
    private let metalSynth: MetalWavetableSynth?
    
    init(activeSkyTouches: Binding<Int>) {
        self._activeSkyTouches = activeSkyTouches
        
        print("🔧 SynthesizerView: Initializing MetalWavetableSynth...")
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("❌ SynthesizerView: Failed to create Metal device")
            self.metalSynth = nil
            return
        }
        
        let synth = MetalWavetableSynth(device: device)
        if synth != nil {
            print("✅ SynthesizerView: MetalWavetableSynth created successfully")
        } else {
            print("❌ SynthesizerView: MetalWavetableSynth initialization failed")
        }
        self.metalSynth = synth
    }
    
    var body: some View {
        VStack {
            Text("SYNTH: \(activeSkyTouches) notes")
                .font(.caption)
                .foregroundColor(.white)
                .opacity(0.7)
        }
    }
    
    // MARK: - Public Access
    
    func getMetalSynth() -> MetalWavetableSynth? {
        return metalSynth
    }
    
    // MARK: - Synthesizer Functions
    
    func startSynthNote(at location: CGPoint) -> Int {
        guard let metalSynth = metalSynth else { return -1 }
        
        // Convert location to normalized coordinates (0-1)
        let screenBounds = UIScreen.main.bounds
        let x = Float(location.x / screenBounds.width)
        let y = Float(location.y / screenBounds.height)
        
        // Calculate note from position
        let midiNote = calculateNoteFromPosition(x: x, y: y)
        
        // Start note and track it
        metalSynth.noteOn(noteNumber: midiNote, velocity: Float(0.5 + x * 0.4), wavetablePosition: x)
        
        let voiceID = nextVoiceID
        nextVoiceID += 1
        activeSynthNotes[voiceID] = midiNote
        
        print("🎹 STARTED: Note \(midiNote), Voice \(voiceID)")
        return voiceID
    }
    
    func endSynthNote(voiceID: Int) {
        guard let metalSynth = metalSynth else { return }
        
        if let midiNote = activeSynthNotes[voiceID] {
            metalSynth.noteOff(noteNumber: midiNote)
            activeSynthNotes.removeValue(forKey: voiceID)
            print("🎹 ENDED: Note \(midiNote), Voice \(voiceID)")
        }
    }
    
    func endAllSynthNotes() {
        guard let metalSynth = metalSynth else { return }
        
        for (voiceID, midiNote) in activeSynthNotes {
            metalSynth.noteOff(noteNumber: midiNote)
            print("🎹 ENDED ALL: Note \(midiNote), Voice \(voiceID)")
        }
        activeSynthNotes.removeAll()
    }
    
    private func calculateNoteFromPosition(x: Float, y: Float) -> Int {
        // Same celestial scale logic as in Metal view
        let celestialScale = [0, 2, 4, 7, 9] // Pentatonic major
        let baseNote = 60 // Middle C
        
        // Y controls octave shift
        let octaveShift = Int((1.0 - y) * 24.0 - 12.0) // Range: -12 to +12 semitones
        
        // X selects note within scale
        let scaleIndex = Int(x * Float(celestialScale.count - 1))
        let noteOffset = celestialScale[scaleIndex]
        
        let midiNote = baseNote + octaveShift + noteOffset
        return max(0, min(127, midiNote))
    }
    
    // Helper function for note names
    private func noteToString(_ noteNumber: Int) -> String {
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (noteNumber / 12) - 1
        let noteName = noteNames[noteNumber % 12]
        return "\(noteName)\(octave)"
    }
}