//
//  MetalWavetableSynth.swift
//  kiloworld
//
//  Metal-based Wavetable Synthesizer for iOS
//

import Metal
import MetalKit
import AVFoundation
import simd

struct SynthParams {
    var sampleRate: Float = 44100.0
    var frequency: Float = 440.0
    var wavetablePosition: Float = 0.0
    var filterCutoff: Float = 8000.0
    var filterResonance: Float = 0.3
    
    // ADSR envelope - will be set from UserSettings
    var envelopeAttack: Float = 0.1        // Default attack
    var envelopeDecay: Float = 0.3         // Default decay
    var envelopeSustain: Float = 0.7       // Default sustain level
    var envelopeRelease: Float = 0.5       // Default release
    
    // Wavetable morphing parameters
    var wavetableMorphRate: Float = 0.05   // How fast wavetables morph automatically
    var wavetableFrameCount: Float = 32.0  // Number of wavetable frames
    
    var lfoRate: Float = 0.0               // DISABLED LFO for testing clean pitch
    var lfoDepth: Float = 0.0              // DISABLED LFO for testing clean pitch
    var masterVolume: Float = 0.3          // Lower volume for ambient feel
    var time: Float = 0.0
    var reverbMix: Float = 0.0             // DISABLED reverb for testing
    var chorusDepth: Float = 0.0           // DISABLED chorus for testing
}

struct NoteState {
    var isActive: Bool = false
    var noteNumber: Int32 = 0           // FIXED: Use Int32 to match Metal's int (32-bit)
    var velocity: Float = 0.0
    
    // 64-bit fixed-point phase accumulator (Q32.32 format)
    var phaseAccumulator: UInt64 = 0    // High precision phase accumulator
    var phaseDelta: UInt64 = 0          // Phase increment per sample (read-only for GPU)
    var startPhase: Float = 0.0         // Initial phase offset for unison spread
    
    var envelopePhase: Int32 = 0        // FIXED: Use Int32 to match Metal's int (32-bit) (0=attack, 1=decay, 2=sustain, 3=release)
    var envelopeLevel: Float = 0.0
    var startTime: Float = 0.0
    var releaseTime: Float = 0.0
    var wavetablePosition: Float = 0.0  // Per-voice wavetable position for polyphony
    var wavetableFrame: Float = 0.0     // Current wavetable frame (0.0-31.0) for morphing
    var pitchBend: Float = 0.0          // Pitch bend in semitones (-12.0 to +12.0)
    
    // LFO with fixed-point precision
    var lfoPhaseAccumulator: UInt64 = 0 // High precision LFO phase
    var lfoPhaseDelta: UInt64 = 0       // LFO phase increment
}

class MetalWavetableSynth {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    
    // Q32.32 Fixed-point constants
    private let FIXED_POINT_SCALE: UInt64 = 1 << 32  // 2^32 for Q32.32 format
    private let PHASE_MASK: UInt64 = (1 << 32) - 1   // Mask for fractional part
    private var computePipelineState: MTLComputePipelineState?
    
    // Audio engine
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    
    // Metal buffers
    private var synthParamsBuffer: MTLBuffer?
    internal var wavetableBuffer: MTLBuffer?  // Make internal for VitalPresetLoader access
    private var notesBuffer: MTLBuffer?
    private var audioBuffer: MTLBuffer?
    
    // Synthesis state
    internal var synthParams = SynthParams()  // Make internal for VitalPresetLoader access
    private var activeNotes: [NoteState] = Array(repeating: NoteState(), count: 16)
    private var currentSampleIndex: Int = 0
    
    // Enhanced wavetable data - make internal for VitalPresetLoader access
    internal var wavetableData: [Float] = []
    internal let wavetableSize: Int = 2048
    internal let wavetableFrames: Int = 32      // 32 morphing frames
    private let maxPolyphony: Int = 1  // TEMPORARY: Force monophonic to test rumbling
    
    init?(device: MTLDevice) {
        print("🚨🚨🚨 CREATING NEW MetalWavetableSynth INSTANCE 🚨🚨🚨")
        print("🎵 MetalWavetableSynth: Initializing with device: \(device.name)")
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue() else {
            print("❌ MetalWavetableSynth: Failed to create command queue")
            return nil
        }
        self.commandQueue = commandQueue
        print("✅ MetalWavetableSynth: Command queue created successfully")
        
        setupMetal()
        setupAudioEngine()
        generateWavetables()
        
        // Load Vital preset with wavetables after initialization
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.loadVitalPresetFromBundle()
        }
        
        print("✅ MetalWavetableSynth: Initialization complete")
    }
    
    // MARK: - Fixed-Point Phase Helper Functions
    
    /// Convert frequency (Hz) to Q32.32 phase delta per sample
    private func frequencyToPhaseDelta(_ frequency: Float) -> UInt64 {
        let phaseIncrement = frequency / synthParams.sampleRate
        return UInt64(phaseIncrement * Float(FIXED_POINT_SCALE))
    }
    
    /// Convert Q32.32 phase accumulator to normalized phase (0.0-1.0)
    private func phaseAccumulatorToFloat(_ accumulator: UInt64) -> Float {
        return Float(accumulator & PHASE_MASK) / Float(FIXED_POINT_SCALE)
    }
    
    /// Convert normalized phase (0.0-1.0) to Q32.32 accumulator
    private func floatToPhaseAccumulator(_ phase: Float) -> UInt64 {
        return UInt64(phase * Float(FIXED_POINT_SCALE)) & PHASE_MASK
    }
    
    /// Calculate MIDI note frequency with pitch bend
    private func midiNoteToFrequency(noteNumber: Int32, pitchBend: Float) -> Float {
        let bendedNote = Float(noteNumber) + pitchBend
        return 440.0 * pow(2.0, (bendedNote - 69.0) / 12.0)
    }
    
    private func setupMetal() {
        print("🔧 MetalWavetableSynth: Setting up Metal resources...")
        
        guard let library = device.makeDefaultLibrary() else {
            print("❌ MetalWavetableSynth: Failed to create Metal library")
            return
        }
        print("✅ MetalWavetableSynth: Metal library created")
        
        guard let kernelFunction = library.makeFunction(name: "wavetableSynthKernel") else {
            print("❌ MetalWavetableSynth: Failed to create kernel function 'wavetableSynthKernel'")
            print("📋 Available functions: \(library.functionNames)")
            return
        }
        print("✅ MetalWavetableSynth: Kernel function 'wavetableSynthKernel' found")
        
        do {
            computePipelineState = try device.makeComputePipelineState(function: kernelFunction)
            print("✅ MetalWavetableSynth: Compute pipeline state created")
        } catch {
            print("❌ MetalWavetableSynth: Failed to create compute pipeline state: \(error)")
        }
        
        // Create Metal buffers
        let synthParamsSize = MemoryLayout<SynthParams>.stride
        let notesSize = MemoryLayout<NoteState>.stride * maxPolyphony
        let wavetableSize = MemoryLayout<Float>.stride * self.wavetableSize * wavetableFrames // 32 frames
        let audioSize = MemoryLayout<Float>.stride * 4096 // MONO: iOS forces mono buffer, so Metal outputs mono
        
        print("🔧 Creating Metal buffers:")
        print("   - SynthParams: \(synthParamsSize) bytes")
        print("   - Notes: \(notesSize) bytes (\(maxPolyphony) voices)")
        print("   - Wavetable: \(wavetableSize) bytes (\(wavetableFrames) frames × \(self.wavetableSize) samples)")
        print("   - Audio: \(audioSize) bytes (4096 samples)")
        
        synthParamsBuffer = device.makeBuffer(length: synthParamsSize, options: [])
        notesBuffer = device.makeBuffer(length: notesSize, options: [])
        wavetableBuffer = device.makeBuffer(length: wavetableSize, options: [])
        audioBuffer = device.makeBuffer(length: audioSize, options: [.storageModeShared])
        
        let buffersCreated = [synthParamsBuffer, notesBuffer, wavetableBuffer, audioBuffer].allSatisfy { $0 != nil }
        if buffersCreated {
            print("✅ MetalWavetableSynth: All Metal buffers created successfully")
        } else {
            print("❌ MetalWavetableSynth: Some Metal buffers failed to create")
        }
    }
    
    private func setupAudioEngine() {
        print("🎵 MetalWavetableSynth: Setting up AVAudioEngine...")
        
        audioEngine = AVAudioEngine()
        
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100.0,
            channels: 2,
            interleaved: true
        )!
        print("[audio] ✅ Audio format: 44.1kHz, 2 channels, \(audioFormat.commonFormat)")
        print("[audio]    Sample rate: \(audioFormat.sampleRate)")
        print("[audio]    Channels: \(audioFormat.channelCount)")
        print("[audio]    Format flags: \(audioFormat.formatDescription)")
        print("[audio]    Is interleaved: \(audioFormat.isInterleaved)")
        print("[audio]    Is float: \(audioFormat.commonFormat == .pcmFormatFloat32)")
        
        sourceNode = AVAudioSourceNode(format: audioFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            return self?.renderAudio(frameCount: frameCount, audioBufferList: audioBufferList) ?? noErr
        }
        print("[audio] ✅ AVAudioSourceNode created")
        
        guard let engine = audioEngine, let source = sourceNode else { 
            print("❌ Failed to create audio engine or source node")
            return 
        }
        
        print("🔗 Connecting audio nodes...")
        engine.attach(source)
        engine.connect(source, to: engine.outputNode, format: audioFormat)
        print("✅ Audio nodes connected")
        
        // Check audio session with more detailed configuration
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredSampleRate(44100.0)
            try session.setPreferredIOBufferDuration(0.005) // 5ms buffer for low latency
            try session.setActive(true)
            print("✅ Audio session configured: category=\(session.category), mode=\(session.mode)")
            print("   Current route: \(session.currentRoute)")
            print("   Output volume: \(session.outputVolume)")
            print("   Session sample rate: \(session.sampleRate)Hz")
            print("   Our format sample rate: \(audioFormat.sampleRate)Hz")
            
            // Check for sample rate mismatch
            if abs(session.sampleRate - audioFormat.sampleRate) > 1.0 {
                print("⚠️ Sample rate mismatch: session=\(session.sampleRate)Hz, format=\(audioFormat.sampleRate)Hz")
            }
        } catch {
            print("⚠️ Audio session configuration failed: \(error)")
        }
        
        do {
            try engine.start()
            print("✅ AVAudioEngine started successfully")
            print("   - Running: \(engine.isRunning)")
            print("   - Output format: \(engine.outputNode.outputFormat(forBus: 0))")
            print("   - Source format: \(audioFormat)")
            print("   - Connection exists: \(engine.outputNode.inputFormat(forBus: 0) != nil)")
            
            // Verify the connection chain
            if let sourceNode = sourceNode {
                print("   - Source node format: \(sourceNode.outputFormat(forBus: 0))")
                print("   - Source→Output connection valid: \(sourceNode.outputFormat(forBus: 0).sampleRate == engine.outputNode.inputFormat(forBus: 0).sampleRate)")
            }
        } catch {
            print("❌ Failed to start audio engine: \(error)")
        }
    }
    
    private func generateWavetables() {
        var tables: [Float] = []
        
        print("🌊 Generating \(wavetableFrames) morphing wavetable frames...")
        
        // Generate 32 frames of evolving wavetables for smooth morphing
        for frameIndex in 0..<wavetableFrames {
            let frameProgress = Float(frameIndex) / Float(wavetableFrames - 1) // 0.0 to 1.0
            
            for i in 0..<wavetableSize {
                let phase = Float(i) / Float(wavetableSize) * 2.0 * Float.pi
                var sample: Float = 0.0
                
                // Frame 0-7: Evolving from pure sine to rich harmonics
                if frameIndex < 8 {
                    let evolveAmount = Float(frameIndex) / 7.0
                    sample = sin(phase) // Base sine
                    sample += evolveAmount * 0.3 * sin(phase * 2.0) // Add 2nd harmonic
                    sample += evolveAmount * 0.2 * sin(phase * 3.0) // Add 3rd harmonic
                    sample += evolveAmount * 0.15 * sin(phase * 4.0) // Add 4th harmonic
                }
                // Frame 8-15: Golden ratio and fibonacci harmonics
                else if frameIndex < 16 {
                    let localProgress = Float(frameIndex - 8) / 7.0
                    let golden = Float(1.618034)
                    let fibonacci1 = Float(1.0)
                    let fibonacci2 = Float(1.618034)
                    let fibonacci3 = Float(2.618034)
                    
                    sample = sin(phase)
                    sample += 0.4 * sin(phase * fibonacci1) * (1.0 - localProgress)
                    sample += 0.4 * sin(phase * fibonacci2) * localProgress
                    sample += 0.2 * sin(phase * fibonacci3) * localProgress
                    sample += 0.15 * sin(phase * golden * golden) * localProgress
                }
                // Frame 16-23: Crystalline and metallic harmonics
                else if frameIndex < 24 {
                    let localProgress = Float(frameIndex - 16) / 7.0
                    let crystalRatios: [Float] = [1.0, 1.5, 2.0, 3.0, 4.0, 6.0]
                    
                    for (index, ratio) in crystalRatios.enumerated() {
                        let amplitude = (1.0 / Float(index + 1)) * (0.3 + 0.7 * localProgress)
                        let phaseShift = Float(index) * localProgress * 0.1
                        sample += amplitude * sin(phase * ratio + phaseShift)
                    }
                }
                // Frame 24-31: Ethereal and otherworldly textures
                else {
                    let localProgress = Float(frameIndex - 24) / 7.0
                    
                    // Base ethereal harmonics
                    sample = sin(phase)
                    sample += 0.5 * sin(phase * 1.2599) // Minor third
                    sample += 0.4 * sin(phase * 1.4983) // Perfect fifth (slightly detuned)
                    sample += 0.3 * sin(phase * 1.7818) // Minor seventh
                    sample += 0.2 * sin(phase * 2.3784) // Ninth
                    
                    // Add evolving inharmonic content
                    let inharmonicRatio = 1.0 + localProgress * 0.3
                    sample += 0.2 * sin(phase * inharmonicRatio * 2.7) * localProgress
                    sample += 0.15 * sin(phase * inharmonicRatio * 3.14159) * localProgress
                    
                    // Add subtle beating/chorus effect
                    sample += 0.1 * sin(phase * (1.0 + localProgress * 0.007))
                    sample += 0.1 * sin(phase * (1.0 - localProgress * 0.007))
                }
                
                // Apply frame-dependent filtering and saturation
                let filterAmount = 0.7 + 0.3 * sin(frameProgress * Float.pi)
                sample = tanh(sample * filterAmount) * 0.8
                
                // Add subtle frame-dependent modulation
                let frameModulation = sin(frameProgress * 2.0 * Float.pi) * 0.05
                sample += frameModulation * sin(phase * 7.0) * 0.1
                
                tables.append(sample)
            }
        }
        
        wavetableData = tables
        print("🌊 Generated \(wavetableFrames) morphing wavetable frames with \(wavetableSize) samples each")
        print("   Total samples: \(tables.count)")
        print("   Sample range: \(tables.min() ?? 0) to \(tables.max() ?? 0)")
        
        // Debug: Check first few samples of first and last frames
        if tables.count >= wavetableSize * 2 {
            print("   Frame 0 samples: \(tables[0]), \(tables[1]), \(tables[2]), \(tables[3])")
            let lastFrameStart = (wavetableFrames - 1) * wavetableSize
            print("   Frame \(wavetableFrames-1) samples: \(tables[lastFrameStart]), \(tables[lastFrameStart+1]), \(tables[lastFrameStart+2]), \(tables[lastFrameStart+3])")
        }
        
        // Upload to Metal buffer
        guard let buffer = wavetableBuffer else { 
            print("❌ Wavetable buffer is nil")
            return 
        }
        let bufferPointer = buffer.contents().bindMemory(to: Float.self, capacity: tables.count)
        for (index, value) in tables.enumerated() {
            bufferPointer[index] = value
        }
        print("✅ Uploaded \(tables.count) wavetable samples to Metal buffer")
    }
    
    private func renderAudio(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let frames = Int(frameCount)
        
        // Only log occasionally to avoid spam
        if currentSampleIndex % 44100 == 0 { // Once per second
            print("🎵 Rendering audio: \(frames) frames, time: \(String(format: "%.2f", Float(currentSampleIndex) / synthParams.sampleRate))s")
        }
        
        // Count active notes
        let activeNoteCount = activeNotes.filter { $0.isActive }.count
        if activeNoteCount > 0 && currentSampleIndex % 4410 == 0 { // Every 0.1 seconds when notes are active
            print("🎹 Active notes: \(activeNoteCount)")
        }
        
        // Update synthesis parameters
        synthParams.time = Float(currentSampleIndex) / synthParams.sampleRate
        
        // Update Metal buffers
        updateBuffers()
        
        // Debug: Track note states right before Metal execution
        if activeNoteCount > 0 && currentSampleIndex % 4410 == 0 {
            print("🔍 Pre-Metal: \(activeNoteCount) active notes, time=\(synthParams.time)")
            for i in 0..<min(3, maxPolyphony) {
                if activeNotes[i].isActive {
                    let timeElapsed = synthParams.time - activeNotes[i].startTime
                    print("   Voice \(i): MIDI=\(activeNotes[i].noteNumber), timeElapsed=\(String(format: "%.6f", timeElapsed))")
                }
            }
        }
        
        // Run Metal compute shader
        processAudioWithMetal(frameCount: frames)
        
        // Copy processed audio to output
        guard let audioBuffer = audioBuffer else { 
            print("❌ Audio buffer is nil in renderAudio")
            return -1 
        }
        // Handle both interleaved and non-interleaved formats
        let isInterleaved = audioBufferList.pointee.mNumberBuffers == 1

        let audioData = audioBuffer.contents().bindMemory(to: Float.self, capacity: frames)

        if isInterleaved {
            // Interleaved format: LRLRLR...
            guard let outputBuffer = audioBufferList.pointee.mBuffers.mData?.bindMemory(to: Float.self, capacity: frames * 2) else {
                print("❌ Interleaved output buffer is nil")
                return -1
            }

            // Copy mono to stereo interleaved
            for i in 0..<frames {
                let sample = audioData[i]
                outputBuffer[i * 2] = sample     // Left channel
                outputBuffer[i * 2 + 1] = sample // Right channel
            }
        } else {
            // Non-interleaved format: separate buffers for L and R
            let bufferPtr = UnsafeMutableAudioBufferListPointer(audioBufferList)

            guard bufferPtr.count >= 2 else {
                print("❌ Expected 2 buffers for stereo but got \(bufferPtr.count)")
                return -1
            }

            guard let leftBuffer = bufferPtr[0].mData?.bindMemory(to: Float.self, capacity: frames),
                  let rightBuffer = bufferPtr[1].mData?.bindMemory(to: Float.self, capacity: frames) else {
                print("❌ Left or right buffer is nil")
                return -1
            }

            // Copy mono to both separate buffers
            for i in 0..<frames {
                let sample = audioData[i]
                leftBuffer[i] = sample   // Left channel
                rightBuffer[i] = sample  // Right channel
            }
        }
        
        // Log buffer format details occasionally
        if currentSampleIndex % 44100 == 0 {
            print("[audio] 🔧 Audio buffer info:")
            print("[audio]    Expected frames: \(frames)")
            print("[audio]    Number of buffers: \(audioBufferList.pointee.mNumberBuffers)")
            print("[audio]    Buffer 0 size: \(audioBufferList.pointee.mBuffers.mDataByteSize) bytes")
            print("[audio]    Expected bytes for stereo interleaved: \(frames * 2 * 4) (for Float32)")
            print("[audio]    Actual buffer capacity: \(audioBufferList.pointee.mBuffers.mDataByteSize / 4) floats")

            // Check if we have multiple buffers (non-interleaved)
            if audioBufferList.pointee.mNumberBuffers > 1 {
                print("[audio]    ⚠️  Multiple buffers detected - this is non-interleaved format!")
                let bufferPtr = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for (index, buffer) in bufferPtr.enumerated() {
                    print("[audio]    Buffer \(index): \(buffer.mDataByteSize) bytes")
                }
            } else {
                print("[audio]    ✅ Single buffer - should be interleaved format")
            }
        }
        
        // Check for audio signal and apply cleanup
        var hasSignal = false
        var maxSample: Float = 0.0
        var noiseCount = 0

        // Apply cleanup and copy to stereo channels
        if isInterleaved {
            // Interleaved format: LRLRLR...
            guard let outputBuffer = audioBufferList.pointee.mBuffers.mData?.bindMemory(to: Float.self, capacity: frames * 2) else {
                print("❌ Interleaved output buffer is nil")
                return -1
            }

            for i in 0..<frames {
                guard i < 4096 else {
                    print("❌ Frame count \(frames) exceeds buffer size, truncating at \(i)")
                    break
                }

                let sample = audioData[i]
                maxSample = max(maxSample, abs(sample))

                // Check for noise when no notes should be active
                if activeNoteCount == 0 && abs(sample) > 0.0001 {
                    noiseCount += 1
                }

                // Clean up tiny values that might cause noise
                var cleanSample = sample
                if activeNoteCount == 0 {
                    cleanSample = 0.0  // Force silence when no notes
                } else if abs(sample) < 0.000001 {
                    cleanSample = 0.0  // Remove tiny DC offset values
                }

                // Copy to both channels
                outputBuffer[i * 2] = cleanSample     // Left channel
                outputBuffer[i * 2 + 1] = cleanSample // Right channel

                if abs(cleanSample) > 0.001 { hasSignal = true }
            }
        } else {
            // Non-interleaved format: separate buffers for L and R
            let bufferPtr = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let leftBuffer = bufferPtr[0].mData?.bindMemory(to: Float.self, capacity: frames),
                  let rightBuffer = bufferPtr[1].mData?.bindMemory(to: Float.self, capacity: frames) else {
                print("❌ Left or right buffer is nil")
                return -1
            }

            for i in 0..<frames {
                guard i < 4096 else {
                    print("❌ Frame count \(frames) exceeds buffer size, truncating at \(i)")
                    break
                }

                let sample = audioData[i]
                maxSample = max(maxSample, abs(sample))

                // Check for noise when no notes should be active
                if activeNoteCount == 0 && abs(sample) > 0.0001 {
                    noiseCount += 1
                }

                // Clean up tiny values that might cause noise
                var cleanSample = sample
                if activeNoteCount == 0 {
                    cleanSample = 0.0  // Force silence when no notes
                } else if abs(sample) < 0.000001 {
                    cleanSample = 0.0  // Remove tiny DC offset values
                }

                // Copy to both separate buffers
                leftBuffer[i] = cleanSample   // Left channel
                rightBuffer[i] = cleanSample  // Right channel

                if abs(cleanSample) > 0.001 { hasSignal = true }
            }
        }
        
        // Log background noise detection
        if activeNoteCount == 0 && noiseCount > 0 && currentSampleIndex % 22050 == 0 {
            print("🔇 Background noise detected: \(noiseCount)/\(frames) samples have noise (should be silent)")
        }
        
        // Log signal status and buffer dump
        if activeNoteCount > 0 && currentSampleIndex % 4410 == 0 {
            print("[audio] 🔊 Audio stats: hasSignal=\(hasSignal), maxSample=\(maxSample), activeNotes=\(activeNoteCount)")

            // Dump first 20 samples to see the waveform pattern
            print("[audio] 📊 Buffer dump (first 20 samples):")
            for i in 0..<min(20, frames) {
                let metalSample = audioData[i]
                if isInterleaved {
                    if let outputBuffer = audioBufferList.pointee.mBuffers.mData?.bindMemory(to: Float.self, capacity: frames * 2) {
                        print("[audio]    [\(i)]: Metal=\(String(format: "%.4f", metalSample)) → L=\(String(format: "%.4f", outputBuffer[i * 2])) R=\(String(format: "%.4f", outputBuffer[i * 2 + 1]))")
                    }
                } else {
                    let bufferPtr = UnsafeMutableAudioBufferListPointer(audioBufferList)
                    if let leftBuffer = bufferPtr[0].mData?.bindMemory(to: Float.self, capacity: frames),
                       let rightBuffer = bufferPtr[1].mData?.bindMemory(to: Float.self, capacity: frames) {
                        print("[audio]    [\(i)]: Metal=\(String(format: "%.4f", metalSample)) → L=\(String(format: "%.4f", leftBuffer[i])) R=\(String(format: "%.4f", rightBuffer[i]))")
                    }
                }
            }
            
            // Calculate expected frequency for first active note
            for i in 0..<maxPolyphony {
                if activeNotes[i].isActive {
                    let expectedFreq = 440.0 * pow(2.0, Float(activeNotes[i].noteNumber - 69) / 12.0)
                    let samplesPerCycle = synthParams.sampleRate / expectedFreq
                    print("🎼 Note \(activeNotes[i].noteNumber): expectedFreq=\(String(format: "%.1f", expectedFreq))Hz, samplesPerCycle=\(String(format: "%.1f", samplesPerCycle))")
                    break
                }
            }
        }
        
        // Log audio signal presence occasionally
        if currentSampleIndex % 22050 == 0 && hasSignal {
            print("🔊 Audio signal detected in output")
        } else if currentSampleIndex % 22050 == 0 && activeNoteCount > 0 {
            print("⚠️ No audio signal despite active notes")
        }
        
        currentSampleIndex += frames
        return noErr
    }
    
    private func updateBuffers() {
        // Update synthesis parameters buffer
        synthParamsBuffer?.contents().copyMemory(from: &synthParams, byteCount: MemoryLayout<SynthParams>.stride)
        
        // Update notes buffer with CPU-managed phase advancement
        guard let notesBuffer = notesBuffer else { 
            print("❌ notesBuffer is nil in updateBuffers")
            return 
        }
        
        // Advance phase accumulators on CPU audio thread and check for envelope completion
        var activeCount = 0
        for i in 0..<maxPolyphony {
            if activeNotes[i].isActive {
                let elapsed = synthParams.time - activeNotes[i].startTime
                
                // Auto-advance envelope phases based on timing
                if activeNotes[i].envelopePhase == 0 { // Attack phase
                    if elapsed >= synthParams.envelopeAttack {
                        activeNotes[i].envelopePhase = 1 // Move to decay
                        print("🎵 Voice \(i) transitioning to DECAY after \(String(format: "%.2f", elapsed))s attack")
                    }
                } else if activeNotes[i].envelopePhase == 1 { // Decay phase
                    if elapsed >= (synthParams.envelopeAttack + synthParams.envelopeDecay) {
                        activeNotes[i].envelopePhase = 2 // Move to sustain
                        print("🎵 Voice \(i) transitioning to SUSTAIN after \(String(format: "%.2f", elapsed))s")
                    }
                } else if activeNotes[i].envelopePhase == 3 { // Release phase
                    let releaseElapsed = synthParams.time - activeNotes[i].releaseTime
                    if releaseElapsed >= synthParams.envelopeRelease {
                        // Release envelope is complete - deactivate the note
                        activeNotes[i].isActive = false
                        print("🎵 Voice \(i) release completed after \(String(format: "%.3f", releaseElapsed))s - deactivating")
                        continue // Skip processing this voice
                    }
                }
                
                activeCount += 1
                
                // Calculate current frequency with pitch bend
                let frequency = midiNoteToFrequency(noteNumber: activeNotes[i].noteNumber, pitchBend: activeNotes[i].pitchBend)
                
                // Update phase delta for this frequency
                activeNotes[i].phaseDelta = frequencyToPhaseDelta(frequency)
                
                // DISABLE CPU phase advancement - let Metal handle all phase calculations
                // activeNotes[i].phaseAccumulator = activeNotes[i].phaseAccumulator &+ activeNotes[i].phaseDelta
                
                // DISABLE LFO advancement too
                // if synthParams.lfoRate > 0 {
                //     activeNotes[i].lfoPhaseDelta = frequencyToPhaseDelta(synthParams.lfoRate)
                //     activeNotes[i].lfoPhaseAccumulator = activeNotes[i].lfoPhaseAccumulator &+ activeNotes[i].lfoPhaseDelta
                // }
                
                // DISABLE wavetable morphing for testing
                // let timeSinceStart = synthParams.time - activeNotes[i].startTime
                // let morphRate = synthParams.wavetableMorphRate
                activeNotes[i].wavetableFrame = 0.0 // Fixed to frame 0
                
                if activeCount == 1 && currentSampleIndex % 4410 == 0 { // Log first active note occasionally
                    let phase = phaseAccumulatorToFloat(activeNotes[i].phaseAccumulator)
                    let elapsed = synthParams.time - activeNotes[i].startTime
                    print("📋 Voice \(i): MIDI=\(activeNotes[i].noteNumber), freq=\(String(format: "%.1f", frequency))Hz, envPhase=\(activeNotes[i].envelopePhase), elapsed=\(String(format: "%.2f", elapsed))s, attack=\(synthParams.envelopeAttack)s")
                }
            }
        }
        
        // Copy note states to GPU buffer (GPU receives read-only phase deltas)
        let notesPointer = notesBuffer.contents().bindMemory(to: NoteState.self, capacity: maxPolyphony)
        for (index, note) in activeNotes.enumerated() {
            notesPointer[index] = note
        }
        
        // CRITICAL: Force CPU writes to complete before GPU reads
        OSMemoryBarrier()
        
        if activeCount > 0 && currentSampleIndex % 4410 == 0 {
            print("🔍 CPU→GPU: \(activeCount) active voices with fixed-point phase management")
        }
    }
    
    private func processAudioWithMetal(frameCount: Int) {
        guard let computePipelineState = computePipelineState else {
            print("❌ Metal compute pipeline state is nil")
            return
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("❌ Failed to create Metal command buffer")
            return
        }
        
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            print("❌ Failed to create Metal compute encoder")
            return
        }
        
        computeEncoder.setComputePipelineState(computePipelineState)
        
        // Validate buffers before setting
        if synthParamsBuffer == nil { print("❌ synthParamsBuffer is nil") }
        if wavetableBuffer == nil { print("❌ wavetableBuffer is nil") }
        if notesBuffer == nil { print("❌ notesBuffer is nil") }
        if audioBuffer == nil { print("❌ audioBuffer is nil") }
        
        computeEncoder.setBuffer(synthParamsBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(wavetableBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(notesBuffer, offset: 0, index: 2)
        computeEncoder.setBuffer(audioBuffer, offset: 0, index: 3)
        
        let threadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)
        let numGroups = MTLSize(width: (frameCount + 63) / 64, height: 1, depth: 1)
        
        // Log Metal execution occasionally
        if currentSampleIndex % 44100 == 0 {
            print("🔧 Running Metal compute shader: \(frameCount) samples")
            print("   Groups: \(numGroups.width), Threads per group: \(threadsPerGroup.width)")
            print("   Total threads: \(numGroups.width * threadsPerGroup.width)")
        }
        
        // Use exact thread count to prevent extra threads
        computeEncoder.dispatchThreads(MTLSize(width: frameCount, height: 1, depth: 1), 
                                       threadsPerThreadgroup: threadsPerGroup)
        computeEncoder.endEncoding()
        
        // Add completion handler to ensure proper GPU->CPU synchronization
        let semaphore = DispatchSemaphore(value: 0)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            // GPU work is completely finished - safe to read buffer now
            semaphore.signal()
        }
        
        commandBuffer.commit()
        
        // Wait for GPU completion with timeout
        let waitResult = semaphore.wait(timeout: .now() + 0.1) // 100ms timeout
        if waitResult == .timedOut {
            print("⚠️ Metal GPU compute timed out!")
            return
        }
        
        // Check for Metal errors
        if commandBuffer.status == .error {
            print("❌ Metal command buffer completed with error: \(commandBuffer.error?.localizedDescription ?? "unknown")")
            return
        }
        
        // CRITICAL: Explicit memory barrier for iOS shared memory
        // Force cache line invalidation to see fresh GPU data
        if let audioBuffer = audioBuffer {
            let pointer = audioBuffer.contents()
            // Memory fence to ensure CPU cache coherency
            OSMemoryBarrier()
        }
    }
    
    // MARK: - Public Interface
    
    func noteOn(noteNumber: Int, velocity: Float) {
        // Use global wavetable position for backward compatibility
        noteOn(noteNumber: noteNumber, velocity: velocity, wavetablePosition: synthParams.wavetablePosition)
    }
    
    func noteOn(noteNumber: Int, velocity: Float, wavetablePosition: Float) {
        print("[audio] 🎹 Note ON: \(noteNumber) (velocity: \(String(format: "%.2f", velocity)))")
        
        // Find available voice
        for i in 0..<maxPolyphony {
            if !activeNotes[i].isActive {
                // Calculate deterministic start phase for unison spread
                let unisonSpread: Float = 0.05 // Small amount of detuning for unison effect
                let voicePhaseOffset = Float(i) / Float(maxPolyphony) // Spread voices across phase
                let startPhase = voicePhaseOffset * unisonSpread
                
                // Initialize voice with fixed-point precision
                activeNotes[i].isActive = true
                activeNotes[i].noteNumber = Int32(noteNumber)
                activeNotes[i].velocity = velocity
                
                // Deterministic phase reset with unison spread
                activeNotes[i].startPhase = startPhase
                activeNotes[i].phaseAccumulator = floatToPhaseAccumulator(startPhase)
                
                // IMMEDIATELY calculate phaseDelta for this note to ensure pitch works
                let frequency = midiNoteToFrequency(noteNumber: Int32(noteNumber), pitchBend: 0.0)
                activeNotes[i].phaseDelta = frequencyToPhaseDelta(frequency)
                
                print("🎹 [DEBUG] Note \(noteNumber) -> \(String(format: "%.1f", frequency))Hz, phaseDelta: \(activeNotes[i].phaseDelta)")
                
                // Reset envelope and timing
                activeNotes[i].envelopePhase = Int32(0) // Attack
                activeNotes[i].envelopeLevel = 0.0
                activeNotes[i].startTime = synthParams.time
                activeNotes[i].releaseTime = 0.0
                
                // Initialize wavetable and modulation
                activeNotes[i].wavetablePosition = wavetablePosition
                activeNotes[i].wavetableFrame = 0.0
                activeNotes[i].pitchBend = 0.0
                
                // Reset LFO with deterministic phase offset
                let lfoPhaseOffset = Float(i) * 0.25 // Quarter phase offsets for LFO per voice
                activeNotes[i].lfoPhaseAccumulator = floatToPhaseAccumulator(lfoPhaseOffset)
                activeNotes[i].lfoPhaseDelta = 0 // Will be calculated in updateBuffers
                
                // Force immediate buffer update to prevent race condition
                updateBuffers()
                
                print("✅ Voice \(i): MIDI=\(noteNumber), startPhase=\(String(format: "%.3f", startPhase)), lfoOffset=\(String(format: "%.3f", lfoPhaseOffset))")
                return
            }
        }
        print("⚠️ No available voices for note \(noteNumber)")
    }
    
    func noteOff(noteNumber: Int) {
        print("[audio] 🎹 Note OFF: \(noteNumber)")
        var foundNote = false
        for i in 0..<maxPolyphony {
            if activeNotes[i].isActive && activeNotes[i].noteNumber == Int32(noteNumber) {
                // Transition to release phase instead of immediately stopping
                activeNotes[i].envelopePhase = Int32(3) // Release phase
                activeNotes[i].releaseTime = synthParams.time
                activeNotes[i].envelopeLevel = activeNotes[i].velocity * synthParams.envelopeSustain // Current level at release
                
                print("🎹 Note \(noteNumber) entering release phase at time \(synthParams.time)")
                
                print("✅ Note \(noteNumber) turned OFF and entering release on voice \(i)")
                foundNote = true
            }
        }
        if !foundNote {
            print("⚠️ Note OFF: Could not find active note \(noteNumber)")
        }
    }
    
    // MARK: - Voice-specific polyphonic methods for touch handling
    
    func findAvailableVoice() -> Int? {
        for i in 0..<maxPolyphony {
            if !activeNotes[i].isActive {
                return i
            }
        }
        return nil // No available voices
    }
    
    func noteOnWithVoice(voiceIndex: Int, noteNumber: Int, velocity: Float, wavetablePosition: Float) {
        guard voiceIndex >= 0 && voiceIndex < maxPolyphony else {
            print("⚠️ Invalid voice index: \(voiceIndex)")
            return
        }
        
        print("🎹 Voice \(voiceIndex) Note ON: \(noteNumber) (velocity: \(String(format: "%.2f", velocity)))")
        
        // Calculate deterministic start phase for unison spread
        let unisonSpread: Float = 0.05 // Small amount of detuning for unison effect
        let voicePhaseOffset = Float(voiceIndex) / Float(maxPolyphony) // Spread voices across phase
        let startPhase = voicePhaseOffset * unisonSpread
        
        // Initialize voice with fixed-point precision
        activeNotes[voiceIndex].isActive = true
        activeNotes[voiceIndex].noteNumber = Int32(noteNumber)
        activeNotes[voiceIndex].velocity = velocity
        
        // Deterministic phase reset with unison spread
        activeNotes[voiceIndex].startPhase = startPhase
        activeNotes[voiceIndex].phaseAccumulator = floatToPhaseAccumulator(startPhase)
        
        // IMMEDIATELY calculate phaseDelta for this note to ensure pitch works
        let frequency = midiNoteToFrequency(noteNumber: Int32(noteNumber), pitchBend: 0.0)
        activeNotes[voiceIndex].phaseDelta = frequencyToPhaseDelta(frequency)
        
        print("🎹 [DEBUG] Voice \(voiceIndex) Note \(noteNumber) -> \(String(format: "%.1f", frequency))Hz, phaseDelta: \(activeNotes[voiceIndex].phaseDelta)")
        
        // Reset envelope and timing
        activeNotes[voiceIndex].envelopePhase = Int32(0) // Attack
        activeNotes[voiceIndex].envelopeLevel = 0.0
        activeNotes[voiceIndex].startTime = synthParams.time
        activeNotes[voiceIndex].releaseTime = 0.0
        
        // Initialize wavetable and modulation
        activeNotes[voiceIndex].wavetablePosition = wavetablePosition
        activeNotes[voiceIndex].wavetableFrame = 0.0
        activeNotes[voiceIndex].pitchBend = 0.0
        
        // Reset LFO with deterministic phase offset
        let lfoPhaseOffset = Float(voiceIndex) * 0.25 // Quarter phase offsets for LFO per voice
        activeNotes[voiceIndex].lfoPhaseAccumulator = floatToPhaseAccumulator(lfoPhaseOffset)
        activeNotes[voiceIndex].lfoPhaseDelta = 0 // Will be calculated in updateBuffers
        
        // Force immediate buffer update to prevent race condition
        updateBuffers()
        
        print("✅ Voice \(voiceIndex): MIDI=\(noteNumber), startPhase=\(String(format: "%.3f", startPhase)), lfoOffset=\(String(format: "%.3f", lfoPhaseOffset))")
    }
    
    func noteOffVoice(voiceIndex: Int) {
        guard voiceIndex >= 0 && voiceIndex < maxPolyphony else {
            print("⚠️ Invalid voice index for noteOff: \(voiceIndex)")
            return
        }
        
        if activeNotes[voiceIndex].isActive {
            let noteNumber = activeNotes[voiceIndex].noteNumber
            print("🎹 Voice \(voiceIndex) Note OFF: \(noteNumber)")
            
            // Transition to release phase instead of immediately stopping
            activeNotes[voiceIndex].envelopePhase = Int32(3) // Release phase
            activeNotes[voiceIndex].releaseTime = synthParams.time
            activeNotes[voiceIndex].envelopeLevel = activeNotes[voiceIndex].velocity * synthParams.envelopeSustain // Current level at release
            
            print("🎹 Voice \(voiceIndex) Note \(noteNumber) entering release phase at time \(synthParams.time)")
            print("✅ Voice \(voiceIndex) Note \(noteNumber) entering release - envelope will complete naturally")
        } else {
            print("⚠️ Voice \(voiceIndex) not active for noteOff")
        }
    }
    
    func updateVoicePitch(voiceIndex: Int, noteNumber: Int, wavetablePosition: Float) {
        guard voiceIndex >= 0 && voiceIndex < maxPolyphony else {
            print("⚠️ Invalid voice index for pitch update: \(voiceIndex)")
            return
        }
        
        if activeNotes[voiceIndex].isActive {
            // Update pitch smoothly using portamento/glide
            activeNotes[voiceIndex].noteNumber = Int32(noteNumber)
            activeNotes[voiceIndex].wavetablePosition = wavetablePosition
            
            // Recalculate frequency and phase delta for new pitch
            let frequency = midiNoteToFrequency(noteNumber: Int32(noteNumber), pitchBend: 0.0)
            activeNotes[voiceIndex].phaseDelta = frequencyToPhaseDelta(frequency)
            
            // DON'T reset the phase accumulator - this allows smooth gliding
            // The phase will continue from its current position with the new frequency
            
            print("🎵 Voice \(voiceIndex) GLIDE to note \(noteNumber) (\(String(format: "%.1f", frequency))Hz), wavetable: \(String(format: "%.3f", wavetablePosition))")
        } else {
            print("⚠️ Voice \(voiceIndex) not active for pitch update")
        }
    }
    
    func allNotesOff() {
        print("[audio] 🎹 ALL NOTES OFF")
        for i in 0..<maxPolyphony {
            activeNotes[i].isActive = false
            activeNotes[i].velocity = 0.0
            activeNotes[i].noteNumber = 0
            
            // Clear fixed-point phase accumulators
            activeNotes[i].phaseAccumulator = 0
            activeNotes[i].phaseDelta = 0
            activeNotes[i].startPhase = 0.0
            activeNotes[i].lfoPhaseAccumulator = 0
            activeNotes[i].lfoPhaseDelta = 0
            
            // Clear other state
            activeNotes[i].wavetablePosition = 0.0
            activeNotes[i].wavetableFrame = 0.0
            activeNotes[i].pitchBend = 0.0
            activeNotes[i].envelopeLevel = 0.0
            activeNotes[i].releaseTime = 0.0
        }
    }
    
    func setWavetablePosition(_ position: Float) {
        let clampedPos = max(0.0, min(1.0, position))
        if abs(synthParams.wavetablePosition - clampedPos) > 0.01 { // Only log significant changes
            print("🌊 Wavetable position: \(String(format: "%.3f", clampedPos))")
        }
        synthParams.wavetablePosition = clampedPos
    }
    
    func updateNoteWavetablePosition(noteNumber: Int, wavetablePosition: Float) {
        let clampedPosition = max(0.0, min(1.0, wavetablePosition))
        for i in 0..<maxPolyphony {
            if activeNotes[i].isActive && activeNotes[i].noteNumber == Int32(noteNumber) {
                activeNotes[i].wavetablePosition = clampedPosition
                print("🌊 Updated note \(noteNumber) wavetable position: \(String(format: "%.3f", clampedPosition))")
                return
            }
        }
    }
    
    func updateNotePitchBend(noteNumber: Int, pitchBend: Float) {
        let clampedBend = max(-12.0, min(12.0, pitchBend))
        for i in 0..<maxPolyphony {
            if activeNotes[i].isActive && activeNotes[i].noteNumber == Int32(noteNumber) {
                activeNotes[i].pitchBend = clampedBend
                print("🎵 Updated note \(noteNumber) pitch bend: \(String(format: "%.2f", clampedBend)) semitones")
                return
            }
        }
    }
    
    func setFilterCutoff(_ cutoff: Float) {
        synthParams.filterCutoff = max(20.0, min(20000.0, cutoff))
    }
    
    func setFilterResonance(_ resonance: Float) {
        synthParams.filterResonance = max(0.0, min(1.0, resonance))
    }
    
    func setLFORate(_ rate: Float) {
        synthParams.lfoRate = max(0.1, min(20.0, rate))
    }
    
    func setLFODepth(_ depth: Float) {
        synthParams.lfoDepth = max(0.0, min(1.0, depth))
        print("🌊 LFO Depth: \(String(format: "%.3f", synthParams.lfoDepth))")
    }
    
    func setMasterVolume(_ volume: Float) {
        synthParams.masterVolume = max(0.0, min(1.0, volume))
    }

    // MARK: - ADSR Envelope Control

    func updateADSR(attack: Float, decay: Float, sustain: Float, release: Float) {
        synthParams.envelopeAttack = max(0.001, min(3.0, attack))
        synthParams.envelopeDecay = max(0.001, min(3.0, decay))
        synthParams.envelopeSustain = max(0.0, min(1.0, sustain))
        synthParams.envelopeRelease = max(0.001, min(3.0, release))
        print("[audio] 🎛️ Updated ADSR: A=\(String(format: "%.3f", synthParams.envelopeAttack))s D=\(String(format: "%.3f", synthParams.envelopeDecay))s S=\(String(format: "%.3f", synthParams.envelopeSustain)) R=\(String(format: "%.3f", synthParams.envelopeRelease))s")
    }

    // MARK: - Vital Preset Loading
    
    private func loadVitalPresetFromBundle() {
        guard let bundlePath = Bundle.main.path(forResource: "dark", ofType: "vital") else {
            print("⚠️ dark.vital not found in app bundle, using default wavetables")
            return
        }
        
        print("🎵 Loading Vital preset from app bundle: \(bundlePath)")
        loadVitalPreset(filePath: bundlePath)
    }
}
