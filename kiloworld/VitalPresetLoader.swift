//
//  VitalPresetLoader.swift
//  kiloworld
//
//  Vital synth preset loader for wavetable extraction
//  Created by Claude on 9/22/25.
//

import Foundation

struct VitalPreset {
    let name: String
    let author: String
    let style: String
    let settings: VitalSettings
    let wavetables: [VitalWavetable]
}

struct VitalSettings {
    // Envelope settings from Vital
    let env1Attack: Float
    let env1Decay: Float  
    let env1Sustain: Float
    let env1Release: Float
    
    // Oscillator settings
    let osc1Level: Float
    let osc1Unison: Float
    let osc1Detune: Float
    let osc1Pan: Float
    let osc1On: Bool
    
    let osc2Level: Float
    let osc2Unison: Float
    let osc2Detune: Float
    let osc2Pan: Float
    let osc2On: Bool
    
    // Filter settings
    let filter1Cutoff: Float
    let filter1Resonance: Float
    let filter1On: Bool
    
    // Effects
    let chorusDryWet: Float
    let delayDryWet: Float
    let reverbDryWet: Float
}

struct VitalWavetable {
    let name: String
    let sampleRate: Int
    let length: Int
    let samples: [Float]
}

class VitalPresetLoader {
    
    static func loadPreset(from filePath: String) -> VitalPreset? {
        print("🎵 Loading Vital preset from: \(filePath)")
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            print("❌ Failed to read Vital preset file")
            return nil
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("❌ Failed to parse Vital preset JSON")
            return nil
        }
        
        // Extract basic preset info
        let name = json["preset_name"] as? String ?? "Unknown"
        let author = json["author"] as? String ?? "Unknown"
        let style = json["preset_style"] as? String ?? "Unknown"
        
        print("📋 Preset: '\(name)' by \(author) (\(style))")
        
        // Extract settings
        guard let settings = json["settings"] as? [String: Any] else {
            print("❌ No settings found in Vital preset")
            return nil
        }
        
        let vitalSettings = extractSettings(from: settings)
        
        // Extract wavetables
        let wavetables = extractWavetables(from: json)
        
        return VitalPreset(
            name: name,
            author: author, 
            style: style,
            settings: vitalSettings,
            wavetables: wavetables
        )
    }
    
    private static func extractSettings(from settings: [String: Any]) -> VitalSettings {
        // Extract ENV 1 (amp envelope) settings with Vital naming conventions
        let env1Attack = settings["env_1_attack"] as? Float ?? 0.5
        let env1Decay = settings["env_1_decay"] as? Float ?? 1.0
        let env1Sustain = settings["env_1_sustain"] as? Float ?? 1.0
        let env1Release = settings["env_1_release"] as? Float ?? 0.5
        
        // Extract additional envelope curve parameters (Vital-specific)
        let env1AttackCurve = settings["env_1_attack_curve"] as? Float ?? 0.0  // -1 to 1 (log to exp)
        let env1DecayCurve = settings["env_1_decay_curve"] as? Float ?? 0.0
        let env1ReleaseCurve = settings["env_1_release_curve"] as? Float ?? 0.0
        
        // Extract envelope trigger/legato settings
        let env1TriggerMode = settings["env_1_trigger_mode"] as? Float ?? 0.0  // 0=retrigger, 1=legato
        let env1Legato = settings["env_1_legato"] as? Float ?? 0.0
        
        print("🎛️ ENV 1 (Amp Envelope):")
        print("   ADSR: A=\(env1Attack)s D=\(env1Decay)s S=\(env1Sustain) R=\(env1Release)s")
        print("   Curves: Attack=\(env1AttackCurve) Decay=\(env1DecayCurve) Release=\(env1ReleaseCurve)")
        print("   Trigger: Mode=\(env1TriggerMode) Legato=\(env1Legato)")
        
        // Extract oscillator settings
        let osc1Level = settings["osc_1_level"] as? Float ?? 0.7
        let osc1Unison = settings["osc_1_unison_voices"] as? Float ?? 1.0
        let osc1Detune = settings["osc_1_unison_detune"] as? Float ?? 0.0
        let osc1Pan = settings["osc_1_pan"] as? Float ?? 0.0
        let osc1On = (settings["osc_1_on"] as? Float ?? 1.0) > 0.5
        
        let osc2Level = settings["osc_2_level"] as? Float ?? 0.7
        let osc2Unison = settings["osc_2_unison_voices"] as? Float ?? 1.0
        let osc2Detune = settings["osc_2_unison_detune"] as? Float ?? 0.0
        let osc2Pan = settings["osc_2_pan"] as? Float ?? 0.0
        let osc2On = (settings["osc_2_on"] as? Float ?? 0.0) > 0.5
        
        // Extract filter settings
        let filter1Cutoff = settings["filter_1_cutoff"] as? Float ?? 60.0
        let filter1Resonance = settings["filter_1_resonance"] as? Float ?? 0.5
        let filter1On = (settings["filter_1_on"] as? Float ?? 1.0) > 0.5
        
        // Extract effects
        let chorusDryWet = settings["chorus_dry_wet"] as? Float ?? 0.0
        let delayDryWet = settings["delay_dry_wet"] as? Float ?? 0.0
        let reverbDryWet = settings["reverb_dry_wet"] as? Float ?? 0.0
        
        print("🎤 OSC1: Level=\(osc1Level) Unison=\(osc1Unison) Detune=\(osc1Detune) On=\(osc1On)")
        print("🎤 OSC2: Level=\(osc2Level) Unison=\(osc2Unison) Detune=\(osc2Detune) On=\(osc2On)")
        print("🔧 Filter: Cutoff=\(filter1Cutoff) Resonance=\(filter1Resonance) On=\(filter1On)")
        print("🎭 FX: Chorus=\(chorusDryWet) Delay=\(delayDryWet) Reverb=\(reverbDryWet)")
        
        return VitalSettings(
            env1Attack: env1Attack,
            env1Decay: env1Decay,
            env1Sustain: env1Sustain,
            env1Release: env1Release,
            osc1Level: osc1Level,
            osc1Unison: osc1Unison,
            osc1Detune: osc1Detune,
            osc1Pan: osc1Pan,
            osc1On: osc1On,
            osc2Level: osc2Level,
            osc2Unison: osc2Unison,
            osc2Detune: osc2Detune,
            osc2Pan: osc2Pan,
            osc2On: osc2On,
            filter1Cutoff: filter1Cutoff,
            filter1Resonance: filter1Resonance,
            filter1On: filter1On,
            chorusDryWet: chorusDryWet,
            delayDryWet: delayDryWet,
            reverbDryWet: reverbDryWet
        )
    }
    
    private static func extractWavetables(from json: [String: Any]) -> [VitalWavetable] {
        var wavetables: [VitalWavetable] = []
        
        print("🔍 Searching for wavetables in Vital preset using proper structure...")
        
        // Extract settings first
        guard let settings = json["settings"] as? [String: Any] else {
            print("❌ No settings found in Vital preset")
            return wavetables
        }
        
        // Vital stores wavetables at: settings.wavetables → array of tables
        guard let wavetableArray = settings["wavetables"] as? [[String: Any]] else {
            print("❌ No wavetables array found in settings")
            return wavetables
        }
        
        print("📊 Found \(wavetableArray.count) wavetables in preset")
        
        for (tableIndex, table) in wavetableArray.enumerated() {
            let tableName = table["name"] as? String ?? "Wavetable \(tableIndex)"
            print("🌊 Processing table \(tableIndex): '\(tableName)'")
            
            // Navigate: table → groups[] → components[] → keyframes[]
            guard let groups = table["groups"] as? [[String: Any]] else {
                print("   ❌ No groups found in table \(tableIndex)")
                continue
            }
            
            var allFrames: [Float] = []
            var frameCount = 0
            
            for (groupIndex, group) in groups.enumerated() {
                guard let components = group["components"] as? [[String: Any]] else {
                    print("   ❌ No components found in group \(groupIndex)")
                    continue
                }
                
                for (componentIndex, component) in components.enumerated() {
                    guard let keyframes = component["keyframes"] as? [[String: Any]] else {
                        print("   ❌ No keyframes found in component \(componentIndex)")
                        continue
                    }
                    
                    for (keyframeIndex, keyframe) in keyframes.enumerated() {
                        if let waveData = keyframe["wave_data"] as? String {
                            print("   📈 Found wave_data in group[\(groupIndex)].components[\(componentIndex)].keyframes[\(keyframeIndex)]")
                            
                            if let frameSamples = decodeVitalWaveData(waveData) {
                                allFrames.append(contentsOf: frameSamples)
                                frameCount += 1
                                print("   ✅ Frame \(frameCount-1): \(frameSamples.count) samples")
                                
                                // Analyze first few samples for verification
                                let firstSamples = Array(frameSamples.prefix(8))
                                print("      First 8 samples: [\(firstSamples.map { String(format: "%.3f", $0) }.joined(separator: ", "))]")
                            } else {
                                print("   ❌ Failed to decode wave_data for keyframe \(keyframeIndex)")
                            }
                        }
                    }
                }
            }
            
            if !allFrames.isEmpty {
                let wavetable = VitalWavetable(
                    name: "\(tableName) (\(frameCount) frames)",
                    sampleRate: 44100,
                    length: allFrames.count,
                    samples: allFrames
                )
                wavetables.append(wavetable)
                print("✅ Created wavetable: '\(tableName)' with \(frameCount) frames (\(allFrames.count) total samples)")
            } else {
                print("⚠️ No frames found in table '\(tableName)'")
            }
        }
        
        if wavetables.isEmpty {
            print("⚠️ No wavetables extracted - will generate fallback wavetables")
        } else {
            print("🎵 Successfully extracted \(wavetables.count) wavetables from preset")
        }
        
        return wavetables
    }
    
    private static func decodeVitalWaveData(_ waveData: String) -> [Float]? {
        // Base64 decode the wave data
        guard let data = Data(base64Encoded: waveData) else {
            print("❌ Failed to decode base64 wave data")
            return nil
        }
        
        // Convert to Float32 array (little-endian)
        let expectedSampleCount = 2048 // Vital standard frame size
        let actualSampleCount = data.count / MemoryLayout<Float32>.size
        
        if actualSampleCount != expectedSampleCount {
            print("⚠️ Unexpected sample count: \(actualSampleCount) (expected \(expectedSampleCount))")
        }
        
        var samples: [Float] = []
        data.withUnsafeBytes { bytes in
            let floatPtr = bytes.bindMemory(to: Float32.self)
            for i in 0..<actualSampleCount {
                samples.append(Float(floatPtr[i]))
            }
        }
        
        // Vital preprocessing: DC removal and normalization
        let dcOffset = samples.reduce(0, +) / Float(samples.count)
        let dcRemovedSamples = samples.map { $0 - dcOffset }
        
        // Find peak for normalization
        let peak = dcRemovedSamples.map(abs).max() ?? 1.0
        let normalizedSamples = dcRemovedSamples.map { ($0 / peak) * 0.98 } // Normalize to ±0.98
        
        print("   📊 Decoded \(samples.count) samples, DC offset: \(String(format: "%.4f", dcOffset)), peak: \(String(format: "%.3f", peak))")
        
        return normalizedSamples
    }
    
    private static func decodeVitalSamples(_ samplesString: String, expectedLength: Int) -> [Float]? {
        // Vital stores samples as base64-encoded binary data
        guard let data = Data(base64Encoded: samplesString) else {
            print("❌ Failed to decode base64 samples")
            return nil
        }
        
        // Convert binary data to float array (assuming 32-bit floats)
        let floatCount = data.count / MemoryLayout<Float>.size
        var samples: [Float] = Array(repeating: 0.0, count: floatCount)
        
        data.withUnsafeBytes { bytes in
            let floatPtr = bytes.bindMemory(to: Float.self)
            for i in 0..<min(floatCount, samples.count) {
                samples[i] = floatPtr[i]
            }
        }
        
        // Vital samples are typically normalized between -1.0 and 1.0
        // Clamp any values outside this range
        samples = samples.map { max(-1.0, min(1.0, $0)) }
        
        print("📊 Decoded \(samples.count) samples (expected \(expectedLength))")
        print("   Sample range: \(samples.min() ?? 0) to \(samples.max() ?? 0)")
        
        return samples
    }
    
    private static func analyzeWaveform(_ samples: [Float], frameIndex: Int, wavetableName: String) {
        guard samples.count >= 16 else {
            print("   Frame \(frameIndex): TOO FEW SAMPLES (\(samples.count))")
            return
        }
        
        // Calculate basic waveform characteristics
        let minVal = samples.min() ?? 0.0
        let maxVal = samples.max() ?? 0.0
        let range = maxVal - minVal
        let dcOffset = samples.reduce(0, +) / Float(samples.count)
        
        // Analyze first few harmonics to identify waveform type
        let fundamentalMagnitude = calculateFourierMagnitude(samples, harmonic: 1)
        let secondHarmonic = calculateFourierMagnitude(samples, harmonic: 2)
        let thirdHarmonic = calculateFourierMagnitude(samples, harmonic: 3)
        let fourthHarmonic = calculateFourierMagnitude(samples, harmonic: 4)
        
        // Classify waveform based on harmonic content
        let waveformType = classifyWaveform(
            fundamental: fundamentalMagnitude,
            second: secondHarmonic,
            third: thirdHarmonic,
            fourth: fourthHarmonic
        )
        
        // Count zero crossings to estimate frequency content
        var zeroCrossings = 0
        for i in 1..<samples.count {
            if (samples[i-1] < 0 && samples[i] >= 0) || (samples[i-1] >= 0 && samples[i] < 0) {
                zeroCrossings += 1
            }
        }
        
        print("   Frame \(frameIndex): \(waveformType)")
        print("     Range: \(String(format: "%.3f", minVal)) to \(String(format: "%.3f", maxVal)) (span: \(String(format: "%.3f", range)))")
        print("     DC Offset: \(String(format: "%.4f", dcOffset))")
        print("     Zero Crossings: \(zeroCrossings)")
        print("     Harmonics: F=\(String(format: "%.3f", fundamentalMagnitude)) 2nd=\(String(format: "%.3f", secondHarmonic)) 3rd=\(String(format: "%.3f", thirdHarmonic)) 4th=\(String(format: "%.3f", fourthHarmonic))")
    }
    
    private static func calculateFourierMagnitude(_ samples: [Float], harmonic: Int) -> Float {
        // Simple DFT calculation for a specific harmonic
        let N = samples.count
        let k = harmonic // harmonic number
        var realSum: Float = 0.0
        var imagSum: Float = 0.0
        
        for n in 0..<N {
            let angle = 2.0 * Float.pi * Float(k * n) / Float(N)
            realSum += samples[n] * cos(angle)
            imagSum += samples[n] * sin(angle)
        }
        
        return sqrt(realSum * realSum + imagSum * imagSum) / Float(N)
    }
    
    private static func classifyWaveform(fundamental: Float, second: Float, third: Float, fourth: Float) -> String {
        let secondRatio = second / max(fundamental, 0.001)
        let thirdRatio = third / max(fundamental, 0.001)
        let fourthRatio = fourth / max(fundamental, 0.001)
        
        // Basic waveform classification based on harmonic ratios
        if fundamental > 0.3 && secondRatio < 0.1 && thirdRatio < 0.1 {
            return "SINE (pure fundamental)"
        } else if secondRatio > 0.3 && thirdRatio < 0.2 {
            return "TRIANGLE-like (strong 2nd harmonic)"
        } else if thirdRatio > 0.2 && secondRatio < 0.3 {
            return "SAW-like (strong odd harmonics)"
        } else if secondRatio > 0.3 && thirdRatio > 0.2 && fourthRatio > 0.1 {
            return "SQUARE-like (rich harmonics)"
        } else if fundamental > 0.1 {
            return "COMPLEX (multiple harmonics)"
        } else {
            return "NOISE/SILENCE (low fundamental)"
        }
    }
}

// MARK: - MetalWavetableSynth Extension for Vital Integration

extension MetalWavetableSynth {
    
    func loadVitalPreset(filePath: String) {
        guard let preset = VitalPresetLoader.loadPreset(from: filePath) else {
            print("❌ Failed to load Vital preset")
            return
        }
        
        print("🎵 Applying Vital preset '\(preset.name)' to synth")
        
        // Apply envelope settings
        synthParams.envelopeAttack = preset.settings.env1Attack
        synthParams.envelopeDecay = preset.settings.env1Decay
        synthParams.envelopeSustain = preset.settings.env1Sustain
        synthParams.envelopeRelease = preset.settings.env1Release
        
        // Apply filter settings - scale appropriately for our synth
        synthParams.filterCutoff = preset.settings.filter1Cutoff * 100.0 // Scale to Hz
        synthParams.filterResonance = preset.settings.filter1Resonance
        
        // Apply effects
        synthParams.chorusDepth = preset.settings.chorusDryWet
        synthParams.reverbMix = preset.settings.reverbDryWet
        
        // Check which oscillators are active and load appropriate wavetables
        let osc1Active = preset.settings.osc1On
        let osc2Active = preset.settings.osc2On
        
        // Load real Vital wavetables or fallback to Basic Shapes
        if !preset.wavetables.isEmpty {
            print("🎯 Loading real Vital wavetables from preset...")
            
            // Debug: Show what we found
            for (i, wt) in preset.wavetables.enumerated() {
                let frameCount = wt.length / 2048
                print("   Wavetable \(i): '\(wt.name)' - \(frameCount) frames (\(wt.length) samples)")
            }
            
            // Load the actual Vital wavetables
            loadVitalWavetables(preset.wavetables)
            
            print("✅ Using real Vital wavetables from dark.vital")
        } else {
            print("⚠️ No wavetables found in preset - using fallback Basic Shapes")
            generateBasicShapesWavetables()
        }
        
        // Set volume based on active oscillator levels
        let osc1Contribution = osc1Active ? preset.settings.osc1Level : 0.0
        let osc2Contribution = osc2Active ? preset.settings.osc2Level : 0.0
        synthParams.masterVolume = (osc1Contribution + osc2Contribution) * 0.4 // Balanced volume
        
        print("🎵 Wavetable setup complete")
        print("   OSC1: \(osc1Active ? "ON" : "OFF") (level: \(preset.settings.osc1Level))")
        print("   OSC2: \(osc2Active ? "ON" : "OFF") (level: \(preset.settings.osc2Level))")
        
        print("✅ Vital preset applied successfully")
        print("   ADSR: \(synthParams.envelopeAttack)s / \(synthParams.envelopeDecay)s / \(synthParams.envelopeSustain) / \(synthParams.envelopeRelease)s")
        print("   Filter: Cutoff=\(synthParams.filterCutoff)Hz Resonance=\(synthParams.filterResonance)")
        print("   Volume: \(synthParams.masterVolume)")
    }
    
    private func loadVitalWavetables(_ vitalWavetables: [VitalWavetable]) {
        print("🌊 Loading \(vitalWavetables.count) Vital wavetables...")
        
        // Convert Vital wavetables to our 32-frame format
        var newWavetableData: [Float] = []
        
        for (frameIndex, wavetable) in vitalWavetables.prefix(32).enumerated() {
            // Resample wavetable to our standard size (2048 samples)
            let resampledSamples = resampleWavetable(wavetable.samples, targetSize: wavetableSize)
            newWavetableData.append(contentsOf: resampledSamples)
            
            print("   Frame \(frameIndex): '\(wavetable.name)' (\(resampledSamples.count) samples)")
        }
        
        // Fill remaining frames by cycling through available wavetables
        while newWavetableData.count < wavetableSize * wavetableFrames {
            for wavetable in vitalWavetables {
                if newWavetableData.count >= wavetableSize * wavetableFrames { break }
                let resampledSamples = resampleWavetable(wavetable.samples, targetSize: wavetableSize)
                newWavetableData.append(contentsOf: resampledSamples)
            }
        }
        
        // Update our wavetable data
        wavetableData = Array(newWavetableData.prefix(wavetableSize * wavetableFrames))
        
        // Upload to Metal buffer
        guard let buffer = wavetableBuffer else { 
            print("❌ Wavetable buffer is nil")
            return 
        }
        let bufferPointer = buffer.contents().bindMemory(to: Float.self, capacity: wavetableData.count)
        for (index, value) in wavetableData.enumerated() {
            bufferPointer[index] = value
        }
        
        print("✅ Loaded Vital wavetables into 32-frame morphing system")
    }
    
    private func resampleWavetable(_ inputSamples: [Float], targetSize: Int) -> [Float] {
        if inputSamples.count == targetSize {
            return inputSamples
        }
        
        var outputSamples: [Float] = []
        let ratio = Float(inputSamples.count) / Float(targetSize)
        
        for i in 0..<targetSize {
            let srcIndex = Float(i) * ratio
            let index1 = Int(srcIndex)
            let index2 = min(index1 + 1, inputSamples.count - 1)
            let fraction = srcIndex - Float(index1)
            
            let sample1 = inputSamples[index1]
            let sample2 = inputSamples[index2]
            let interpolated = sample1 + (sample2 - sample1) * fraction
            
            outputSamples.append(interpolated)
        }
        
        return outputSamples
    }
    
    private func generateFallbackWavetables() {
        print("🎵 Generating fallback wavetables (basic waveforms)")
        
        // Generate simple waveforms as fallback when no wavetables are found
        var newWavetableData: [Float] = []
        
        // Generate 32 frames of basic waveforms (sine, saw, square, triangle variations)
        for frameIndex in 0..<wavetableFrames {
            let progress = Float(frameIndex) / Float(wavetableFrames - 1) // 0.0 to 1.0
            
            let frameData = generateBasicWaveform(
                frameProgress: progress,
                frameSize: wavetableSize
            )
            
            newWavetableData.append(contentsOf: frameData)
        }
        
        // Update our wavetable data
        wavetableData = newWavetableData
        
        // Upload to Metal buffer
        guard let buffer = wavetableBuffer else { 
            print("❌ Wavetable buffer is nil")
            return 
        }
        let bufferPointer = buffer.contents().bindMemory(to: Float.self, capacity: wavetableData.count)
        for (index, value) in wavetableData.enumerated() {
            bufferPointer[index] = value
        }
        
        print("✅ Generated \(wavetableFrames) frames of fallback wavetables")
    }
    
    private func generateBasicWaveform(frameProgress: Float, frameSize: Int) -> [Float] {
        var samples: [Float] = []
        
        // Morph between different basic waveforms based on frame progress
        for i in 0..<frameSize {
            let phase = Float(i) / Float(frameSize) * 2.0 * Float.pi
            
            // Start with sine wave, morph to saw, then to square
            let sine = sin(phase)
            let saw = (Float(2.0) * Float(i) / Float(frameSize)) - Float(1.0)
            let square: Float = sine > 0 ? Float(1.0) : Float(-1.0)
            
            let sample: Float
            if frameProgress < 0.33 {
                // Sine to saw
                let t = frameProgress / 0.33
                sample = sine * (Float(1.0) - t) + saw * t
            } else if frameProgress < 0.66 {
                // Saw to square
                let t = (frameProgress - 0.33) / 0.33
                sample = saw * (Float(1.0) - t) + square * t
            } else {
                // Square to harmonic-rich
                let t = (frameProgress - 0.66) / 0.34
                let harmonic = sine + Float(0.3) * sin(Float(3.0) * phase) + Float(0.1) * sin(Float(5.0) * phase)
                sample = square * (Float(1.0) - t) + harmonic * t
            }
            
            samples.append(max(-1.0, min(1.0, sample * 0.7))) // Slightly reduce amplitude
        }
        
        return samples
    }
    
    private func generateTestSineWaves() {
        print("🎵 Generating clean sine wave wavetables for testing...")
        
        // Generate 32 frames of pure sine waves with slight variations
        var newWavetableData: [Float] = []
        
        for frameIndex in 0..<wavetableFrames {
            var frameData: [Float] = []
            
            for i in 0..<wavetableSize {
                let phase = Float(i) / Float(wavetableSize) * 2.0 * Float.pi
                
                // Pure sine wave (no harmonics, no complexity)
                let sine = sin(phase)
                
                frameData.append(sine * 0.7) // Moderate amplitude
            }
            
            newWavetableData.append(contentsOf: frameData)
        }
        
        // Update our wavetable data
        wavetableData = newWavetableData
        
        // Upload to Metal buffer
        guard let buffer = wavetableBuffer else { 
            print("❌ Wavetable buffer is nil")
            return 
        }
        let bufferPointer = buffer.contents().bindMemory(to: Float.self, capacity: wavetableData.count)
        for (index, value) in wavetableData.enumerated() {
            bufferPointer[index] = value
        }
        
        print("✅ Generated \(wavetableFrames) frames of clean sine waves (\(wavetableData.count) total samples)")
    }
    
    func generateBasicShapesWavetables() {
        print("🎯 Generating Basic Shapes wavetables (8 frames)...")
        
        var newWavetableData: [Float] = []
        
        // Generate the 8 Basic Shapes frames
        for frameIndex in 0..<8 {
            let frameData = generateBasicShapeFrame(frameIndex: frameIndex, frameSize: wavetableSize)
            newWavetableData.append(contentsOf: frameData)
            
            // Print frame type for verification
            let frameType = getBasicShapeFrameName(frameIndex)
            print("   Frame \(frameIndex): \(frameType) (\(frameData.count) samples)")
        }
        
        // Fill remaining frames (9-31) by cycling through the 8 Basic Shapes
        for frameIndex in 8..<wavetableFrames {
            let sourceFrameIndex = frameIndex % 8
            let frameData = generateBasicShapeFrame(frameIndex: sourceFrameIndex, frameSize: wavetableSize)
            newWavetableData.append(contentsOf: frameData)
        }
        
        // Update our wavetable data
        wavetableData = newWavetableData
        
        // Upload to Metal buffer
        guard let buffer = wavetableBuffer else { 
            print("❌ Wavetable buffer is nil")
            return 
        }
        let bufferPointer = buffer.contents().bindMemory(to: Float.self, capacity: wavetableData.count)
        for (index, value) in wavetableData.enumerated() {
            bufferPointer[index] = value
        }
        
        print("✅ Generated Basic Shapes wavetables: 8 unique frames repeated across \(wavetableFrames) frames")
        print("   Total samples: \(wavetableData.count)")
        
        // Quick verification - check first few samples of each frame
        for frameIndex in 0..<8 {
            let startIdx = frameIndex * wavetableSize
            let endIdx = min(startIdx + 8, wavetableData.count) // Just first 8 samples
            if startIdx < wavetableData.count {
                let firstSamples = Array(wavetableData[startIdx..<endIdx])
                let frameType = getBasicShapeFrameName(frameIndex)
                print("   Frame \(frameIndex) (\(frameType)): [\(firstSamples.map { String(format: "%.3f", $0) }.joined(separator: ", "))]")
            }
        }
    }
    
    private func generateBasicShapeFrame(frameIndex: Int, frameSize: Int) -> [Float] {
        var samples: [Float] = []
        
        for i in 0..<frameSize {
            let phase = Float(i) / Float(frameSize) * 2.0 * Float.pi
            let normalizedPhase = Float(i) / Float(frameSize) // 0.0 to 1.0
            
            let sample: Float
            
            switch frameIndex {
            case 0: // Frame 0: Sine (very rounded wave)
                sample = sin(phase)
                
            case 1: // Frame 1: Triangle-ish
                sample = generateTriangleWave(normalizedPhase)
                
            case 2: // Frame 2: Progressively brighter (tri → saw) - 25% saw
                let triangle = generateTriangleWave(normalizedPhase)
                let saw = generateSawWave(normalizedPhase)
                sample = triangle * 0.75 + saw * 0.25
                
            case 3: // Frame 3: Progressively brighter (tri → saw) - 75% saw
                let triangle = generateTriangleWave(normalizedPhase)
                let saw = generateSawWave(normalizedPhase)
                sample = triangle * 0.25 + saw * 0.75
                
            case 4: // Frame 4: Ideal saw
                sample = generateSawWave(normalizedPhase)
                
            case 5: // Frame 5: Rounded square (soft edges)
                sample = generateRoundedSquareWave(normalizedPhase, smoothness: 0.15)
                
            case 6: // Frame 6: 50% square (perfect square)
                sample = generateSquareWave(normalizedPhase)
                
            case 7: // Frame 7: Pulse-width-ish / harder square (narrow pulse)
                sample = generatePulseWave(normalizedPhase, pulseWidth: 0.25) // 25% duty cycle
                
            default:
                sample = sin(phase) // Fallback to sine
            }
            
            // Apply gentle low-pass filtering and amplitude control
            let filteredSample = sample * 0.8 // Slightly reduce amplitude
            samples.append(max(-1.0, min(1.0, filteredSample)))
        }
        
        return samples
    }
    
    private func generateTriangleWave(_ phase: Float) -> Float {
        // Triangle wave: linear ramp up, then linear ramp down
        if phase < 0.5 {
            return (phase * 4.0) - 1.0 // Rise from -1 to +1
        } else {
            return 3.0 - (phase * 4.0) // Fall from +1 to -1
        }
    }
    
    private func generateSawWave(_ phase: Float) -> Float {
        // Sawtooth wave: linear ramp from -1 to +1
        return (phase * 2.0) - 1.0
    }
    
    private func generateSquareWave(_ phase: Float) -> Float {
        // Square wave: 50% duty cycle
        return phase < 0.5 ? -1.0 : 1.0
    }
    
    private func generateRoundedSquareWave(_ phase: Float, smoothness: Float) -> Float {
        // Rounded square wave using tanh for smooth transitions
        let adjustedPhase = (phase - 0.5) * 2.0 // Center around 0, range -1 to +1
        let sharpness = 1.0 / max(smoothness, 0.01) // Inverse of smoothness
        return tanh(adjustedPhase * sharpness)
    }
    
    private func generatePulseWave(_ phase: Float, pulseWidth: Float) -> Float {
        // Pulse wave with variable duty cycle
        return phase < pulseWidth ? 1.0 : -1.0
    }
    
    private func getBasicShapeFrameName(_ frameIndex: Int) -> String {
        switch frameIndex {
        case 0: return "SINE (rounded wave)"
        case 1: return "TRIANGLE-ish"
        case 2: return "TRI→SAW (25% saw)"
        case 3: return "TRI→SAW (75% saw)"
        case 4: return "IDEAL SAW"
        case 5: return "ROUNDED SQUARE"
        case 6: return "50% SQUARE"
        case 7: return "PULSE-WIDTH (25% duty)"
        default: return "UNKNOWN"
        }
    }
}