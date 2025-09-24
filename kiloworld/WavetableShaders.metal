//
//  WavetableShaders.metal
//  kiloworld
//
//  Metal compute shaders for GPU-accelerated wavetable synthesis
//

#include <metal_stdlib>
using namespace metal;

struct SynthParams {
    float sampleRate;
    float frequency;
    float wavetablePosition;
    float filterCutoff;
    float filterResonance;
    
    // Enhanced ADSR envelope with slow attack
    float envelopeAttack;        // Much slower attack for ethereal pads
    float envelopeDecay;         // Smooth decay
    float envelopeSustain;       // Higher sustain for pads
    float envelopeRelease;       // Very long release for ambient tails
    
    // Wavetable morphing parameters
    float wavetableMorphRate;    // How fast wavetables morph automatically
    float wavetableFrameCount;   // Number of wavetable frames
    
    float lfoRate;
    float lfoDepth;
    float masterVolume;
    float time;
    float reverbMix;
    float chorusDepth;
};

struct NoteState {
    bool isActive;
    int noteNumber;
    float velocity;
    
    // 64-bit fixed-point phase accumulator (Q32.32 format) - read-only for GPU
    ulong phaseAccumulator;    // High precision phase accumulator
    ulong phaseDelta;          // Phase increment per sample (read-only for GPU)
    float startPhase;          // Initial phase offset for unison spread
    
    int envelopePhase;         // (0=attack, 1=decay, 2=sustain, 3=release)
    float envelopeLevel;
    float startTime;
    float releaseTime;
    float wavetablePosition;   // Per-voice wavetable position for polyphony
    float wavetableFrame;      // Current wavetable frame (0.0-31.0) for morphing
    float pitchBend;           // Pitch bend in semitones (-12.0 to +12.0)
    
    // LFO with fixed-point precision
    ulong lfoPhaseAccumulator; // High precision LFO phase
    ulong lfoPhaseDelta;       // LFO phase increment
};

// Convert MIDI note to frequency
float midiToFrequency(int midiNote) {
    return 440.0 * pow(2.0, (midiNote - 69) / 12.0);
}

// Basic Shapes wavetable lookup with frame morphing
float wavetableLookup(device const float* wavetable, ulong phaseAccumulator, float wavetableFrame, int wavetableSize) {
    const int wavetableFrames = 32; // Total frames available (8 unique, repeated)
    const int basicShapesFrames = 8; // Number of unique Basic Shapes frames
    const ulong PHASE_MASK = (1UL << 32) - 1;  // Mask for fractional part
    
    // Convert Q32.32 phase accumulator to normalized phase (0.0-1.0)
    float phase = float(phaseAccumulator & PHASE_MASK) / float(1UL << 32);
    
    // Safety bounds checking for Basic Shapes (0-7.999...)
    wavetableFrame = clamp(wavetableFrame, 0.0f, float(basicShapesFrames) - 0.001f);
    phase = fmod(phase, 1.0f);
    if (phase < 0.0f) phase += 1.0f;
    
    // Determine which Basic Shapes frames to interpolate between (0-7)
    int frame1 = clamp((int)wavetableFrame, 0, basicShapesFrames - 1);
    int frame2 = (frame1 + 1) % basicShapesFrames; // Wrap around for continuous morphing
    float frameFrac = clamp(wavetableFrame - frame1, 0.0f, 1.0f);
    
    // Calculate sample positions with bounds checking
    float sampleFloat = phase * wavetableSize;
    int sample1 = ((int)sampleFloat) % wavetableSize;
    int sample2 = (sample1 + 1) % wavetableSize;
    float sampleFrac = clamp(sampleFloat - (int)sampleFloat, 0.0f, 1.0f);
    
    // Ensure array bounds safety for 32 frames
    int totalSize = wavetableFrames * wavetableSize;
    int index1_1 = clamp(frame1 * wavetableSize + sample1, 0, totalSize - 1);
    int index1_2 = clamp(frame1 * wavetableSize + sample2, 0, totalSize - 1);
    int index2_1 = clamp(frame2 * wavetableSize + sample1, 0, totalSize - 1);
    int index2_2 = clamp(frame2 * wavetableSize + sample2, 0, totalSize - 1);
    
    // Get samples from both wavetable frames with additional safety
    float value1_1 = (index1_1 >= 0 && index1_1 < totalSize) ? wavetable[index1_1] : 0.0f;
    float value1_2 = (index1_2 >= 0 && index1_2 < totalSize) ? wavetable[index1_2] : 0.0f;
    float value2_1 = (index2_1 >= 0 && index2_1 < totalSize) ? wavetable[index2_1] : 0.0f;
    float value2_2 = (index2_2 >= 0 && index2_2 < totalSize) ? wavetable[index2_2] : 0.0f;
    
    // Interpolate within each wavetable frame
    float interp1 = mix(value1_1, value1_2, sampleFrac);
    float interp2 = mix(value2_1, value2_2, sampleFrac);
    
    // Interpolate between wavetable frames for smooth morphing
    return mix(interp1, interp2, frameFrac);
}

// Stateless ADSR envelope calculation - determines phase based on timing
float calculateEnvelope(NoteState note, SynthParams params, float currentTime) {
    if (!note.isActive) return 0.0;
    
    float elapsed = currentTime - note.startTime;
    
    // Determine current envelope phase based on elapsed time
    float attackTime = max(0.001, params.envelopeAttack);
    float decayTime = max(0.001, params.envelopeDecay);
    float releaseTime = max(0.001, params.envelopeRelease);
    
    // Check if we're in release phase (note was released)
    if (note.envelopePhase == 3) {
        // Release phase
        float releaseElapsed = currentTime - note.releaseTime;
        if (releaseElapsed < releaseTime) {
            float progress = releaseElapsed / releaseTime; // 0.0 to 1.0
            // Exponential release curve (Vital-style)
            float curve = exp(-4.0 * progress); // Smooth exponential tail
            return note.envelopeLevel * curve;
        } else {
            return 0.0; // Note finished
        }
    }
    
    // Normal ADSR progression based on elapsed time
    if (elapsed < attackTime) {
        // Attack phase: 0 → 1.0
        float progress = elapsed / attackTime; // 0.0 to 1.0
        // Exponential attack curve (Vital-style)
        float curve = 1.0 - exp(-5.0 * progress); // Exponential rise
        return curve * note.velocity;
    } else if (elapsed < (attackTime + decayTime)) {
        // Decay phase: 1.0 → sustain level
        float decayElapsed = elapsed - attackTime;
        float progress = decayElapsed / decayTime; // 0.0 to 1.0
        // Exponential decay curve (Vital-style)
        float curve = exp(-3.0 * progress); // Exponential fall
        float startLevel = note.velocity;
        float targetLevel = note.velocity * params.envelopeSustain;
        return mix(targetLevel, startLevel, curve);
    } else {
        // Sustain phase: hold at sustain level
        return note.velocity * params.envelopeSustain;
    }
}

// Alternative envelope calculation with configurable curve types
float calculateEnvelopeWithCurve(NoteState note, SynthParams params, float currentTime, int curveType) {
    if (!note.isActive) return 0.0;
    
    float elapsed = currentTime - note.startTime;
    
    switch (note.envelopePhase) {
        case 0: { // Attack
            float attackTime = max(0.001, params.envelopeAttack);
            if (elapsed < attackTime) {
                float progress = elapsed / attackTime;
                float curve;
                
                switch (curveType) {
                    case 0: // Linear
                        curve = progress;
                        break;
                    case 1: // Exponential (default Vital style)
                        curve = 1.0 - exp(-5.0 * progress);
                        break;
                    case 2: // Logarithmic
                        curve = log(1.0 + progress * 9.0) / log(10.0);
                        break;
                    default:
                        curve = 1.0 - exp(-5.0 * progress);
                }
                
                return curve * note.velocity;
            } else {
                return note.velocity;
            }
        }
        case 1: { // Decay
            float attackTime = max(0.001, params.envelopeAttack);
            float decayTime = max(0.001, params.envelopeDecay);
            float decayElapsed = elapsed - attackTime;
            
            if (decayElapsed < decayTime) {
                float progress = decayElapsed / decayTime;
                float curve;
                
                switch (curveType) {
                    case 0: // Linear
                        curve = 1.0 - progress;
                        break;
                    case 1: // Exponential (default Vital style)
                        curve = exp(-3.0 * progress);
                        break;
                    case 2: // Logarithmic
                        curve = 1.0 - (log(1.0 + progress * 9.0) / log(10.0));
                        break;
                    default:
                        curve = exp(-3.0 * progress);
                }
                
                float startLevel = note.velocity;
                float targetLevel = note.velocity * params.envelopeSustain;
                return mix(targetLevel, startLevel, curve);
            } else {
                return note.velocity * params.envelopeSustain;
            }
        }
        case 2: { // Sustain
            return note.velocity * params.envelopeSustain;
        }
        case 3: { // Release
            float releaseTime = max(0.001, params.envelopeRelease);
            float releaseElapsed = currentTime - note.releaseTime;
            
            if (releaseElapsed < releaseTime) {
                float progress = releaseElapsed / releaseTime;
                float curve;
                
                switch (curveType) {
                    case 0: // Linear
                        curve = 1.0 - progress;
                        break;
                    case 1: // Exponential (default Vital style)
                        curve = exp(-4.0 * progress);
                        break;
                    case 2: // Logarithmic
                        curve = 1.0 - (log(1.0 + progress * 9.0) / log(10.0));
                        break;
                    default:
                        curve = exp(-4.0 * progress);
                }
                
                return note.envelopeLevel * curve;
            } else {
                return 0.0;
            }
        }
        default:
            return 0.0;
    }
}

// Simple low-pass filter
float applyFilter(float input, float cutoff, float resonance, float sampleRate, thread float& filterState1, thread float& filterState2) {
    float frequency = cutoff / sampleRate;
    float fb = resonance + resonance / (1.0 - frequency);
    
    filterState1 += frequency * (input - filterState1 + fb * (filterState1 - filterState2));
    filterState2 += frequency * (filterState1 - filterState2);
    
    return filterState2;
}

kernel void wavetableSynthKernel(
    device const SynthParams& params [[buffer(0)]],
    device const float* wavetable [[buffer(1)]],
    device const NoteState* notes [[buffer(2)]],
    device float* audioOutput [[buffer(3)]],
    uint index [[thread_position_in_grid]]
) {
    const int maxPolyphony = 16;
    
    if (index >= 4096) return; // Max mono frames - we'll output stereo pairs
    
    float sample = 0.0;
    float sampleIndex = float(index);
    float currentTime = params.time + (sampleIndex / params.sampleRate);
    
    // Process all active voices with fixed-point precision and ADSR
    int activeVoiceCount = 0;
    for (int voice = 0; voice < maxPolyphony; voice++) {
        NoteState note = notes[voice];
        
        if (!note.isActive) {
            continue;
        }
        
        activeVoiceCount++;
        if (activeVoiceCount > 1) {
            // MULTIPLE VOICES DETECTED - SKIP EXTRAS FOR TESTING
            continue;
        }
        
        // Validate note parameters
        if (note.noteNumber < 0 || note.noteNumber > 127) {
            continue;
        }
        if (note.velocity <= 0.0f || note.velocity > 1.0f) {
            continue;
        }
        
        // PURE TIME-BASED CALCULATION - IGNORE ALL PHASE ACCUMULATOR DATA
        float noteNumber = float(note.noteNumber);
        float frequency = 440.0 * pow(2.0, (noteNumber - 69.0) / 12.0);
        
        // Time-based phase with note start offset for continuity
        float noteStartTime = note.startTime;
        float elapsedTime = (params.time + (float(index) / params.sampleRate)) - noteStartTime;
        float phase = fmod(elapsedTime * frequency, 1.0);
        
        // Convert phase to wavetable lookup - use our clean time-based phase!
        // Create fake phase accumulator for wavetable function
        ulong fakePhaseAccumulator = (ulong)(phase * float(1UL << 32));
        
        // Basic Shapes wavetable morphing - slow morphing through 8 frames
        float morphTime = currentTime * 0.05f; // Very slow morphing (20 second cycle)
        float basicShapesFrame = fmod(morphTime, 8.0f); // Cycle through frames 0-7
        
        float voiceSample = wavetableLookup(wavetable, fakePhaseAccumulator, basicShapesFrame, 2048) * 0.3;
        
        // Apply Vital-style ADSR envelope (stateless - calculates phase from timing)
        float envelopeLevel = calculateEnvelope(note, params, currentTime);
        
        // If envelope finished release, mark note as inactive
        if (note.envelopePhase == 3 && envelopeLevel <= 0.0) {
            // Note: Can't modify const notes buffer here, but this will be handled by silence
        }
        
        voiceSample *= envelopeLevel;
        
        // LFO COMPLETELY DISABLED FOR TESTING
        // if (params.lfoRate > 0.0 && params.lfoDepth > 0.0) {
        //     const ulong LFO_PHASE_MASK = (1UL << 32) - 1;
        //     float lfoPhase = float(note.lfoPhaseAccumulator & LFO_PHASE_MASK) / float(1UL << 32);
        //     float lfoValue = sin(lfoPhase * 2.0 * M_PI_F);
        //     voiceSample *= (1.0 + lfoValue * params.lfoDepth);
        // }
        
        // Clamp individual voice sample to prevent overflow
        voiceSample = clamp(voiceSample, -1.0f, 1.0f);
        
        // Add voice to polyphonic mix
        sample += voiceSample;
    }
    
    // Apply master volume and prevent clipping
    sample = clamp(sample * params.masterVolume, -1.0f, 1.0f);
    
    // Debug signal to prove kernel is running and show voice count
    if (index == 0) {
        sample += 0.000001f;
        // Encode voice count in tiny signal for debugging
        sample += activeVoiceCount * 0.000001f;
    }
    
    // Output mono - iOS forces mono buffer despite our stereo format request
    audioOutput[index] = sample;
}

// Additional kernel for updating note phases (called less frequently)
kernel void updateNotePhases(
    device const SynthParams& params [[buffer(0)]],
    device NoteState* notes [[buffer(1)]],
    uint index [[thread_position_in_grid]]
) {
    const int maxPolyphony = 16;
    if (index >= maxPolyphony) return;
    
    device NoteState& note = notes[index];
    if (!note.isActive) return;
    
    // Update envelope phase based on timing
    float elapsed = params.time - note.startTime;
    
    switch (note.envelopePhase) {
        case 0: // Attack
            if (elapsed >= params.envelopeAttack) {
                note.envelopePhase = 1; // Move to decay
                note.envelopeLevel = note.velocity;
            }
            break;
        case 1: // Decay
            if (elapsed >= (params.envelopeAttack + params.envelopeDecay)) {
                note.envelopePhase = 2; // Move to sustain
                note.envelopeLevel = note.velocity * params.envelopeSustain;
            }
            break;
        case 3: // Release
            if ((params.time - note.releaseTime) >= params.envelopeRelease) {
                note.isActive = false; // Note finished
            }
            break;
    }
}