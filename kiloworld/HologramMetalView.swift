//
//  HologramMetalView.swift
//  kiloworld
//
//  iOS SwiftUI integration of the Hologram renderer
//  Created by Claude on 9/22/25.
//

import SwiftUI
import Metal
import MetalKit
import UIKit
import simd

struct ImageParticle {
    var position: SIMD3<Float>
    var originalPosition: SIMD3<Float>
    var color: SIMD3<Float>
    var size: Float
    var opacity: Float
    var category: Float
    var normalizedDepth: Float
    var velocity: SIMD3<Float>
    var pixelCoord: SIMD2<Float>
    var emissionSeed: Float // Random seed for emission timing, set once at creation
}

struct Uniforms {
    var mvpMatrix: simd_float4x4
    var viewMatrix: simd_float4x4
    var rotation: Float
    var time: Float
    var sizeMultiplier: Float
    var zoom: Float
    var depthScale: Float
    var bgMin: Float
    var bgMax: Float
    var arcRadius: Float
    var dissolve: Float
    var wobble: Float
    var wobbleSpeed: Float
    var yOffset: Float
    var centerPoint: SIMD4<Float>         // <- was SIMD3
    var imageDimensions: SIMD2<Float>
    var aspectRatio: Float
    var _padA: Float = 0                  // pad to 16B boundary
    var puckWorldPosition: SIMD4<Float>   // <- was SIMD3
    var emissionDensity: Float            // 0..1
    var emissionPeriodSec: Float          // P
    var travelTimeSec: Float              // T
    var arcHeight: Float                  // arc height
    var particleBlink: Float              // Blink rate: 0=no blink, 1=random blink
    var particleRandomSize: Float         // Size variation: 0=uniform, 1=varied
    var particleGlow: Float               // Glow effect: 0=sharp circles, 1=soft glow
}

struct HologramMetalView: UIViewRepresentable {
    let depthAmount: Float
    let globalSize: Float
    let metalSynth: MetalWavetableSynth?
    @ObservedObject var userSettings: UserSettings
    let puckScreenPosition: CGPoint
    @Binding var coordinator: HologramCoordinator?
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.isOpaque = false
        mtkView.backgroundColor = UIColor.clear
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.isUserInteractionEnabled = true
        mtkView.isMultipleTouchEnabled = true
        
        context.coordinator.setMTKView(mtkView)
        context.coordinator.setMetalSynth(metalSynth)
        
        // Store coordinator reference for SkyGate control
        coordinator = context.coordinator
        
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.setDepthAmount(depthAmount)
        context.coordinator.setGlobalSize(globalSize)
        context.coordinator.updateHologramSettings(userSettings)
        context.coordinator.setPuckScreenPosition(puckScreenPosition)
    }
    
    func makeCoordinator() -> HologramCoordinator {
        HologramCoordinator()
    }
    
    class HologramCoordinator: NSObject, MTKViewDelegate {
        private let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private var renderPipelineState: MTLRenderPipelineState?
        private var physicsComputePipelineState: MTLComputePipelineState?
        private var particleBuffer: MTLBuffer?
        private var uniformBuffer: MTLBuffer?
        private var depthStencilState: MTLDepthStencilState?
        private weak var mtkView: MTKView?
        private weak var metalSynth: MetalWavetableSynth?
        
        private var particles: [ImageParticle] = []
        private var particleCount: Int = 0
        private var centerPoint = SIMD3<Float>(0, 0, 0)
        private var imageDimensions = SIMD2<Float>(0, 0)

        // Current image source tracking
        private var currentImageURL: String?
        private var currentImageData: (originalImage: UIImage, maskImage: UIImage)?
        private var isUsingRemoteImage: Bool = false
        
        // Animation parameters
        private var time: Float = 0
        private var rotation: Float = 0
        private var rotSpeed: Float = 0.6
        private var sizeMultiplier: Float = 0.4
        private var zoom: Float = 0.5
        private var depthScale: Float = 1.0
        private var arcRadius: Float = 200.0
        private var bgMin: Float = 0.0
        private var bgMax: Float = 1.0
        private var dissolve: Float = 0.0
        private var wobble: Float = 0.0
        private var wobbleSpeed: Float = 1.0
        private var yOffset: Float = 0.0
        private var emissionDensity: Float = 0.8
        private var particleBlink: Float = 0.0
        private var particleRandomSize: Float = 0.0
        private var particleGlow: Float = 0.0
        private var emissionPeriodSec: Float = 8.0
        private var travelTimeSec: Float = 5.0
        private var arcHeight: Float = 50.0
        
        // Puck emission system - lifecycle phase for existing particles
        private var puckScreenPosition: CGPoint = CGPoint(x: 0, y: 0)
        private let maxEmittingParticles = 150 // How many particles emit at once

        // Globe mode state
        private var isInGlobeMode: Bool = false

        // Particle count management
        private var currentParticleCount: Int = 30000
        private var particleRebuildTimer: Timer?
        
        // Camera parameters
        private var cameraEye = SIMD3<Float>(0, 0, 250)
        private var cameraCenter = SIMD3<Float>(0, 0, 0)
        private var cameraUp = SIMD3<Float>(0, 1, 0)
        
        // Compute dispatch
        private let threadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)
        private var numThreadgroups = MTLSize(width: 1, height: 1, depth: 1)
        
        // Touch handling
        private var activeTouches: [UITouch: Int] = [:]
        private let celestialScales = [
            [0, 2, 4, 7, 9],           // Pentatonic major
            [0, 3, 5, 7, 10],          // Pentatonic minor
            [0, 2, 3, 5, 7, 8, 10],    // Natural minor
            [0, 2, 4, 6, 7, 9, 11],    // Lydian
            [0, 1, 4, 5, 7, 8, 11],    // Harmonic minor
            [0, 2, 4, 5, 7, 9, 10],    // Mixolydian
            [0, 1, 3, 4, 6, 8, 10]     // Whole tone
        ]
        private var currentScaleIndex = 0
        private var baseOctave = 4
        
        override init() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let commandQueue = device.makeCommandQueue() else {
                fatalError("Failed to create Metal device/queue")
            }
            
            self.device = device
            self.commandQueue = commandQueue
            super.init()
            
            setupMetal()
            loadParticlesFromImages()

            // Debug: Print Uniforms size for alignment verification
            print("🔧 Swift Uniforms stride: \(MemoryLayout<Uniforms>.stride) bytes")
        }

        deinit {
            particleRebuildTimer?.invalidate()
        }
        
        func setMTKView(_ view: MTKView) {
            mtkView = view
            setupGestures()
        }
        
        func setDepthAmount(_ amount: Float) {
            depthScale = amount * 10.0 - 5.0 // Map 0-1 to -5 to +5, 0.5 = flat plane
        }
        
        func setGlobalSize(_ size: Float) {
            sizeMultiplier = size * 2.0 // Map 0-1 to 0-2
        }
        
        func setMetalSynth(_ synth: MetalWavetableSynth?) {
            metalSynth = synth
        }
        
        func updateHologramSettings(_ settings: UserSettings) {
            rotation = settings.hologramRotation
            rotSpeed = settings.hologramRotSpeed
            sizeMultiplier = settings.hologramSize
            zoom = settings.hologramZoom
            depthScale = settings.hologramDepth // Direct mapping: -100 to +100 (range -20 to +20)
            arcRadius = settings.arcRadius // Direct mapping from slider
            bgMin = settings.hologramBgMin
            bgMax = settings.hologramBgMax
            print("[hologram] 🎭 Background hiding: bgMin=\(bgMin), bgMax=\(bgMax)")
            dissolve = settings.hologramDissolve
            wobble = settings.hologramWobble
            wobbleSpeed = settings.hologramWobbleSpeed
            yOffset = settings.hologramYPosition * 500.0 // Map -1 to +1 to -500 to +500 units (positive = up) - doubled from 250
            emissionDensity = settings.hologramEmissionDensity
            particleBlink = settings.particleBlink
            particleRandomSize = settings.particleRandomSize
            particleGlow = settings.particleGlow
            print("[emission] ⚡ Emission density changed to: \(emissionDensity)")
            print("[emission] 🔍 bgMin: \(settings.hologramBgMin), bgMax: \(settings.hologramBgMax)")
            print("[emission] 🔍 Particle count: \(particleCount)")

            // Map speed slider to travelTimeSec (lower time = faster)
            // speed 0 → 8.0s (slow), speed 1 → 2.0s (fast)
            let minT: Float = 2.0
            let maxT: Float = 8.0
            let speed01 = simd_clamp(settings.hologramEmissionSpeed, 0.0, 1.0)
            travelTimeSec = maxT - speed01 * (maxT - minT)

            // Check for particle count changes
            let newParticleCount = Int(settings.hologramParticleCount)
            let countDifference = abs(newParticleCount - currentParticleCount)
            let percentageChange = Float(countDifference) / Float(currentParticleCount)

            // If particle count changed by more than 10% or by more than 5000 particles, schedule rebuild
            if percentageChange > 0.1 || countDifference > 5000 {
                print("🔄 Particle count change detected: \(currentParticleCount) → \(newParticleCount) (\(Int(percentageChange * 100))% change)")
                scheduleParticleRebuild(newCount: newParticleCount)
            }
        }
        
        func setPuckScreenPosition(_ position: CGPoint) {
            puckScreenPosition = position
            // Screen position is stored and converted to world coordinates each frame
            // This ensures the emission point stays at the same screen location regardless of zoom
        }

        func setGlobeMode(_ globeMode: Bool) {
            isInGlobeMode = globeMode

            // When entering globe mode, reset rotation to face us (0 degrees)
            if globeMode {
                rotation = 0.0
                print("[hologram] 🌍 Globe mode enabled - rotation paused and reset to face user")
            } else {
                print("[hologram] 🌍 Globe mode disabled - rotation resumed")
            }
        }

        private func scheduleParticleRebuild(newCount: Int) {
            // Cancel any existing timer
            particleRebuildTimer?.invalidate()

            // Schedule new rebuild with 0.5s debouncing
            particleRebuildTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.rebuildParticleSystem(targetCount: newCount)
            }
        }

        private func rebuildParticleSystem(targetCount: Int) {
            print("[hologram] 🔨 Rebuilding particle system with \(targetCount) particles...")

            // Update current count
            currentParticleCount = targetCount

            // Reload particles based on current image source
            if let cachedImageData = currentImageData {
                // We have cached image data, use it
                print("[hologram] 🔄 Rebuilding with cached remote images")
                loadParticlesFromDownloadedImages(originalImage: cachedImageData.originalImage, maskImage: cachedImageData.maskImage, targetCount: targetCount)
            } else if let currentURL = currentImageURL {
                // We have a URL but no cached data, re-download
                print("[hologram] 🔄 Rebuilding with remote URL: \(currentURL)")
                loadHologramFromURL(currentURL, targetCount: targetCount)
            } else {
                // No remote image, use local default
                print("[hologram] 🔄 Rebuilding with local images")
                loadParticlesFromImages(targetCount: targetCount)
            }

            print("[hologram] ✅ Particle system rebuild completed")
        }
        
        
        private func refreshParticleBuffer() {
            guard let particleBuffer = particleBuffer else { return }
            
            // All particles are now regular hologram particles with emission lifecycle
            particleCount = particles.count
            
            // Update GPU buffer
            let bufferSize = MemoryLayout<ImageParticle>.stride * particleCount
            if bufferSize <= particleBuffer.length {
                // Buffer is large enough, just copy data
                particleBuffer.contents().copyMemory(from: particles, byteCount: bufferSize)
            } else {
                // Need to recreate buffer (this should rarely happen)
                self.particleBuffer = device.makeBuffer(bytes: particles, length: bufferSize, options: [])
            }
        }
        
        // MARK: - SkyGate Control Methods
        
        @objc func onSkyTouchBegan(_ locationValue: NSValue, in view: UIView) {
            let location = locationValue.cgPointValue
            // Convert touch location to hologram control parameters
            let x = Float(location.x / view.bounds.width)
            let y = Float(location.y / view.bounds.height)
            
            // Control hologram parameters based on touch position
            wobble = y * 0.5 // Y controls wobble intensity
            rotSpeed = x * 2.0 + 0.5 // X controls rotation speed
            
            print("🌌 Hologram: Sky touch began - wobble: \(wobble), rotSpeed: \(rotSpeed)")
        }
        
        @objc func onSkyTouchMoved(_ locationValue: NSValue, in view: UIView) {
            let location = locationValue.cgPointValue
            let x = Float(location.x / view.bounds.width)
            let y = Float(location.y / view.bounds.height)
            
            // Update hologram parameters as touch moves
            wobble = y * 0.5
            rotSpeed = x * 2.0 + 0.5
            dissolve = sin(time * 2.0) * 0.2 + 0.3 // Add dynamic dissolve effect
        }
        
        @objc func onSkyTouchEnded() {
            // Gradually return to normal state
            wobble *= 0.8
            if wobble < 0.05 { wobble = 0.0 }
            
            rotSpeed = 0.6 // Return to default rotation speed
            dissolve = 0.0 // Clear dissolve effect
            
            print("🌌 Hologram: Sky touch ended - returning to normal")
        }
        
        private func setupMetal() {
            // Create depth stencil state
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .less
            depthDescriptor.isDepthWriteEnabled = true
            depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)
            
            // Create shader library with inline Metal source
            let shaderSource = """
            #include <metal_stdlib>
            using namespace metal;

            struct ImageParticle {
                float3 position;
                float3 originalPosition;
                float3 color;
                float  size;
                float  opacity;
                float  category;
                float  normalizedDepth;
                float3 velocity;
                float2 pixelCoord;
                float  emissionSeed; // Random seed for emission timing
            };

            struct Uniforms {
                float4x4 mvpMatrix;
                float4x4 viewMatrix;
                float    rotation;
                float    time;
                float    sizeMultiplier;
                float    zoom;
                float    depthScale;
                float    bgMin;
                float    bgMax;
                float    arcRadius;
                float    dissolve;
                float    wobble;
                float    wobbleSpeed;
                float    yOffset;
                float4   centerPoint;        // <- was float3
                float2   imageDimensions;
                float    aspectRatio;
                float    _padA;              // pad to 16B
                float4   puckWorldPosition;  // <- was float3
                float    emissionDensity;
                float    emissionPeriodSec;
                float    travelTimeSec;
                float    arcHeight;
                float    particleBlink;
                float    particleRandomSize;
                float    particleGlow;
            };

            struct VertexOut {
                float4 position [[position]];
                float  point_size [[point_size]];
                float3 color;
                float  opacity;
                float  category;
                float  normalizedDepth;
                float  glowAmount;
            };

            vertex VertexOut vertex_main(constant ImageParticle* particles [[buffer(0)]],
                                         constant Uniforms& uniforms        [[buffer(1)]],
                                         uint vertexID                       [[vertex_id]]) {
                ImageParticle p = particles[vertexID];

                float4 worldPos = float4(p.position, 1.0);
                float4 clipPos  = uniforms.mvpMatrix * worldPos;

                // View-space Z for perspective-correct point sizing
                float4 viewPos = uniforms.viewMatrix * worldPos;
                float viewZ = max(-viewPos.z, 0.001);

                // Color/alpha and base size
                float3 validColor = clamp(p.color / 255.0, 0.0, 1.0);
                float  validOpacity = clamp(p.opacity, 0.0, 1.0);
                
                // Background hiding with smoothstep between min/max using normalizedDepth
                if (uniforms.bgMin < uniforms.bgMax) {
                    // normalizedDepth < bgMin = visible (opacity = 1.0)
                    // normalizedDepth > bgMax = hidden (opacity = 0.0)
                    // Between = smooth transition
                    float smoothstepValue = smoothstep(uniforms.bgMin, uniforms.bgMax, p.normalizedDepth);
                    float visibilityAmount = 1.0 - smoothstepValue;
                    validOpacity = validOpacity * visibilityAmount;

                    // Debug logging for first few particles
                    if (vertexID < 5) {
                        // This will show in Metal debug output
                        // normalizedDepth, bgMin, bgMax, smoothstepValue, visibilityAmount, finalOpacity
                    }
                }
                
                // Dissolve effect
                if (uniforms.dissolve > 0.0) {
                    float hash = fract(sin(dot(p.originalPosition.xy, float2(12.9898, 78.233))) * 43758.5453);
                    if (hash < uniforms.dissolve) {
                        validOpacity = 0.0;
                    }
                }
                
                float validSize = clamp(p.size, 0.0, 1.0);
                float baseSize = 8.0 + (validSize * 32.0);

                if (p.category < 0.5)      baseSize *= 0.7;
                else if (p.category < 1.5) baseSize *= 1.0;
                else if (p.category < 2.5) baseSize *= 1.3;
                else                       baseSize *= 1.6;

                // Hash values for particle randomness
                float particleRandom1 = fract(sin(dot(p.originalPosition.xy, float2(12.9898, 78.233))) * 43758.5453);
                float particleRandom2 = fract(sin(dot(p.originalPosition.yx, float2(39.346, 11.135))) * 43758.5453);
                float particleRandom3 = fract(sin(dot(p.originalPosition.xz, float2(93.989, 1.233))) * 43758.5453);

                // Apply random size variation
                float sizeVariation = 1.0;
                if (uniforms.particleRandomSize > 0.0) {
                    // Random size between 0.5x and 1.5x natural size
                    float randomSizeFactor = 0.5 + particleRandom3 * 1.0; // 0.5 to 1.5
                    sizeVariation = mix(1.0, randomSizeFactor, uniforms.particleRandomSize);
                }

                // Apply blink effect
                float blinkAlpha = 1.0;
                if (uniforms.particleBlink > 0.0) {
                    // Random blink period between 0.5 and 5.0 seconds per particle
                    float blinkPeriod = 0.5 + particleRandom1 * 4.5; // 0.5 to 5.0 seconds
                    float blinkPhase = fmod(uniforms.time + particleRandom2 * 10.0, blinkPeriod) / blinkPeriod;
                    float blinkPattern = smoothstep(0.0, 0.1, blinkPhase) * (1.0 - smoothstep(0.9, 1.0, blinkPhase));
                    blinkAlpha = mix(1.0, blinkPattern, uniforms.particleBlink);
                }

                float finalSize = clamp(baseSize * sizeVariation * (140.0 / viewZ) * uniforms.sizeMultiplier, 1.0, 200.0);
                validOpacity *= blinkAlpha; // Apply blink effect to opacity

                // Hide particles with very low opacity from background hiding
                if (validOpacity <= 0.001) {
                    finalSize = 0.0;
                }

                if (!isfinite(clipPos.x) || !isfinite(clipPos.y) || !isfinite(clipPos.z)) {
                    finalSize = 0.0;
                    validOpacity = 0.0;
                }

                VertexOut out;
                out.position   = clipPos;
                out.point_size = finalSize;
                out.color      = validColor;
                out.opacity    = validOpacity;
                out.category   = p.category;
                out.normalizedDepth  = p.normalizedDepth;
                out.glowAmount = uniforms.particleGlow;
                return out;
            }

            fragment float4 fragment_main(VertexOut in [[stage_in]],
                                          constant Uniforms& uniforms [[buffer(0)]],
                                          float2 pointCoord [[point_coord]]) {
                // Early discard for completely transparent particles to prevent occlusion
                if (in.opacity <= 0.0) discard_fragment();

                float2 uv = pointCoord - float2(0.5, 0.5);
                float dist = length(uv);

                // Apply glow effect: 0=sharp circles, 1=soft glow
                float sharpAlpha = (dist < 0.5) ? 1.0 : 0.0;
                float glowFalloff = 1.0 - smoothstep(0.0, 0.5, dist);
                float shapeAlpha = mix(sharpAlpha, glowFalloff, in.glowAmount);

                if (shapeAlpha < 0.1) discard_fragment();

                float alpha = in.opacity * shapeAlpha;
                if (alpha <= 0.005) discard_fragment();  // Lower threshold for better occlusion prevention

                return float4(in.color, alpha);
            }

            kernel void unified_physics(device ImageParticle* particles [[buffer(0)]],
                                        constant Uniforms& uniforms     [[buffer(1)]],
                                        uint id [[thread_position_in_grid]]) {
                device ImageParticle& particle = particles[id];

                float3 hologramPos = particle.originalPosition;
                
                // Depth scaling controlled by slider
                //float originalZ = particle.originalPosition.z;
                //float frontZ = arcRadius;
                //float backZ = arcRadius - particle.normalizedDepth * arcRadius;
                
                //float normalizedDepth = (originalZ - frontZ) / (backZ - frontZ);
                //normalizedDepth = clamp(normalizedDepth, 0.0, 1.0);
                
                // Depth formula: arcRadius + (normalizedDepth * arcRadius * depthScale)
                // arcRadius: base distance, normalizedDepth: 0=white(near), 1=black(far), depthScale: -1 to +1 controls distribution
                // depthScale=0: flat plane at arcRadius, depthScale=+1: spread arcRadius to 2*arcRadius, depthScale=-1: reverse
                hologramPos.z = uniforms.arcRadius + (particle.normalizedDepth * uniforms.arcRadius * uniforms.depthScale);

                // Debug: ensure particles are visible (temporary logging for first few particles)
                if (id < 5) {
                    // This will be visible in Metal debug output
                }

                // Rotation
                float3 orbitalCenter = float3(0.0, 0.0, 50.0);
                float tempX = hologramPos.x - orbitalCenter.x;
                float tempZ = hologramPos.z - orbitalCenter.z;

                float cos_y = cos(uniforms.rotation);
                float sin_y = sin(uniforms.rotation);
                float rotX = tempX * cos_y - tempZ * sin_y;
                float rotZ = tempX * sin_y + tempZ * cos_y;

                hologramPos.x = rotX + orbitalCenter.x;
                hologramPos.z = rotZ + orbitalCenter.z;
                
                // Apply Y offset to move hologram up/down
                hologramPos.y += uniforms.yOffset;
                
                // Hash values for randomness
                float hash1 = fract(sin(dot(particle.originalPosition.xy, float2(12.9898, 78.233))) * 43758.5453);
                float hash2 = fract(sin(dot(particle.originalPosition.yx, float2(39.346, 11.135))) * 43758.5453);
                float hash3 = fract(sin(dot(particle.originalPosition.xz, float2(93.989, 1.233))) * 43758.5453);
                
                // Wobble effect
                if (uniforms.wobble > 0.0) {

                    float wobbleTime = uniforms.time * uniforms.wobbleSpeed;
                    float time1 = wobbleTime + hash1 * 6.28;
                    float time2 = wobbleTime + hash2 * 6.28;
                    float time3 = wobbleTime + hash3 * 6.28;

                    float wobbleAmount = uniforms.wobble * 200.0;
                    hologramPos.x += sin(time1 * 2.0) * wobbleAmount * hash1;
                    hologramPos.y += sin(time2 * 1.7) * wobbleAmount * hash2;
                    hologramPos.z += sin(time3 * 2.3) * wobbleAmount * hash3;
                }

                // === Target in-flight fraction model ======================================
                // Let emissionDensity be the target fraction of particles in flight (0..0.1).
                // Choose an effective period Peff so that steady-state fraction T/Peff == emissionDensity.
                // We also keep a base "nominal" period P that shapes cadence.
                const float P = max(0.001, uniforms.emissionPeriodSec);
                const float T = max(0.001, uniforms.travelTimeSec);

                // Clamp target fraction F to 0..0.1, then compute windowFrac = F * (P/T),
                // and Peff = P / windowFrac. This yields T/Peff == F.
                float F = clamp(uniforms.emissionDensity, 0.0, 0.1);
                float windowFrac = clamp(F * (P / T), 0.0, 1.0);
                float Peff = P / max(windowFrac, 1e-4);   // avoid div-by-zero; huge Peff when F≈0

                // Stagger each particle by its seed; each particle "launches" once per Peff seconds.
                float timeWithOffset = uniforms.time * 0.3 + particle.emissionSeed * Peff;
                float phase = fract(timeWithOffset / Peff);   // [0,1) within this particle's Peff-cycle

                // Age since launch in seconds (0..Peff)
                float ageSec = phase * Peff;

                // In flight while age < T (independent of target fraction).
                bool is_in_flight = (ageSec < T);

                if (is_in_flight) {
                    // Travel progress is based ONLY on age since launch vs T (independent of ON window)
                    float t = clamp(ageSec / T, 0.0, 1.0);

                    // Start/end
                    float3 startPos = uniforms.puckWorldPosition.xyz;
                    float3 endPos = hologramPos;

                    // Ease-out
                    float te = 1.0 - pow(1.0 - t, 2.0);

                    // Arc + gentle sway
                    float3 arcPos = mix(startPos, endPos, te);
                    arcPos.y += sin(t * 3.1415926) * uniforms.arcHeight;
                    arcPos.x += sin(t * 6.0 + particle.emissionSeed * 10.0) * 8.0;
                    arcPos.z += cos(t * 4.0 + particle.emissionSeed * 12.0) * 5.0;

                    hologramPos = arcPos;

                    // Visible while in-flight; but still respect background smoothstep
                    particle.size = 1.5;
                    // Keep original normalizedDepth so emitting particles still respect smoothstep
                    // particle.normalizedDepth = 0.0;  // REMOVED - was making particles immune to background hide
                } else {
                    // Flight complete; fall back to normal hologram behavior
                    // Keep existing particle.normalizedDepth (set during particle creation)
                }
                particle.position = hologramPos;

                if (particle.position.z < -150.0) {
                    particle.position = hologramPos;
                    particle.position.z = hologramPos.z + 100.0;
                    particle.velocity = float3(0.0);
                }
            }
            """
            
            do {
                let library = try device.makeLibrary(source: shaderSource, options: nil)
                let vertexFunction = library.makeFunction(name: "vertex_main")!
                let fragmentFunction = library.makeFunction(name: "fragment_main")!
                
                let pipelineDescriptor = MTLRenderPipelineDescriptor()
                pipelineDescriptor.vertexFunction = vertexFunction
                pipelineDescriptor.fragmentFunction = fragmentFunction
                pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
                pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
                pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                
                renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
                
                let computeFunction = library.makeFunction(name: "unified_physics")!
                physicsComputePipelineState = try device.makeComputePipelineState(function: computeFunction)
                
                print("✅ Hologram Metal shaders compiled successfully")
            } catch {
                print("❌ Failed to create hologram shaders: \(error)")
            }
        }

        // MARK: - Remote Image Loading

        func loadHologramFromURL(_ imageURL: String, targetCount: Int = 30000) {
            print("[hologram] 🌐 Loading hologram from remote URL: \(imageURL)")

            // Store current URL for rebuilds
            currentImageURL = imageURL
            currentImageData = nil // Clear cached image data since we're loading new URL
            isUsingRemoteImage = true // Flag for compute shader control

            guard let url = URL(string: imageURL) else {
                print("[hologram] ❌ Invalid image URL: \(imageURL)")
                return
            }

            // Generate mask URL by appending _mask to filename
            let maskURL = generateMaskURL(from: imageURL)
            print("[hologram] 🎭 Generated mask URL: \(maskURL)")
            print("[hologram] 📝 Original URL: \(imageURL)")
            print("[hologram] 📝 Mask URL: \(maskURL)")

            // Download both images concurrently
            let group = DispatchGroup()
            var downloadedImage: UIImage?
            var downloadedMask: UIImage?

            // Download main image
            group.enter()
            downloadImage(from: url) { image in
                downloadedImage = image
                print("[hologram] \(image != nil ? "✅" : "❌") Main image download: \(image != nil ? "success" : "failed")")
                group.leave()
            }

            // Download mask image
            group.enter()
            if let maskURLObj = URL(string: maskURL) {
                downloadImage(from: maskURLObj) { image in
                    downloadedMask = image
                    print("[hologram] \(image != nil ? "✅" : "❌") Mask image download: \(image != nil ? "success" : "failed")")
                    group.leave()
                }
            } else {
                print("[hologram] ❌ Invalid mask URL: \(maskURL)")
                group.leave()
            }

            // Process images when both downloads complete
            group.notify(queue: .main) {
                print("[hologram] 📊 Download results - Main: \(downloadedImage != nil), Mask: \(downloadedMask != nil)")

                guard let originalImage = downloadedImage else {
                    print("[hologram] ❌ Main image download failed for: \(imageURL)")
                    print("[hologram] 🔄 Falling back to local images")
                    self.loadParticlesFromImages(targetCount: targetCount)
                    return
                }

                // If mask failed, use the main image as both color and mask
                let maskImage = downloadedMask ?? originalImage
                if downloadedMask == nil {
                    print("[hologram] ⚠️ Mask download failed for: \(maskURL)")
                    print("[hologram] 🎭 Using main image as mask (uniform depth)")
                }

                print("[hologram] 🎉 Processing downloaded image(s), creating particles...")
                // Ensure particle generation happens on main thread for Metal operations
                DispatchQueue.main.async {
                    self.loadParticlesFromDownloadedImages(originalImage: originalImage, maskImage: maskImage, targetCount: targetCount)
                }
            }
        }

        private func generateMaskURL(from imageURL: String) -> String {
            // Convert URL like "https://cdn.kilo.gallery/items/8r6i5n9r/txzad.png"
            // to "https://cdn.kilo.gallery/items/8r6i5n9r/txzad_mask.png"
            guard let url = URL(string: imageURL) else {
                print("[hologram] ❌ Invalid URL for mask generation: \(imageURL)")
                return imageURL
            }

            let pathExtension = url.pathExtension
            let fileName = url.deletingPathExtension().lastPathComponent
            let maskFileName = "\(fileName)_mask.\(pathExtension)"
            let maskURL = url.deletingLastPathComponent().appendingPathComponent(maskFileName).absoluteString

            return maskURL
        }

        private func downloadImage(from url: URL, completion: @escaping (UIImage?) -> Void) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10.0 // 10 second timeout

            print("[hologram] 📥 Starting download: \(url.absoluteString)")

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    print("[hologram] ❌ Download error for \(url.absoluteString): \(error.localizedDescription)")
                    completion(nil)
                    return
                }

                if let httpResponse = response as? HTTPURLResponse {
                    print("[hologram] 📡 HTTP \(httpResponse.statusCode) for \(url.absoluteString)")
                    if httpResponse.statusCode != 200 {
                        print("[hologram] ❌ HTTP error \(httpResponse.statusCode) for \(url.absoluteString)")
                        completion(nil)
                        return
                    }
                }

                guard let data = data, let image = UIImage(data: data) else {
                    print("[hologram] ❌ Failed to create image from downloaded data for \(url.absoluteString)")
                    completion(nil)
                    return
                }

                print("[hologram] ✅ Successfully downloaded image: \(url.absoluteString)")
                completion(image)
            }.resume()
        }

        private func generateParticlesFromPixelData(originalPixelData: [UInt8], depthPixelData: [UInt8], width: Int, height: Int, targetCount: Int) {
            print("[hologram] 🎨 Generating particles from pixel data...")

            // Validate input data
            let expectedDataSize = width * height * 4
            guard originalPixelData.count >= expectedDataSize && depthPixelData.count >= expectedDataSize else {
                print("[hologram] ❌ Invalid pixel data size - original: \(originalPixelData.count), depth: \(depthPixelData.count), expected: \(expectedDataSize)")
                return
            }

            let originalBytesPerRow = width * 4
            let availablePixels = width * height

            // Adjust target particles based on image size to prevent memory issues
            // Relaxed from 64 to 16 pixels per particle for better visual quality
            let maxSafeParticles = min(targetCount, availablePixels / 16) // 1 particle per 16 pixels (was 64)
            let targetParticles = min(targetCount, maxSafeParticles)

            let baseSampleRate = max(1, Int((Float(availablePixels) / Float(targetParticles)).squareRoot()))

            // Memory usage calculation
            let imageMemoryMB = Float(width * height * 8) / (1024 * 1024) // 8 bytes per pixel (2 images × 4 bytes)
            let particleMemoryMB = Float(targetParticles * MemoryLayout<ImageParticle>.stride) / (1024 * 1024)

            print("[hologram] 📐 Using sample rate: \(baseSampleRate)")
            print("[hologram] 🎯 Target particles: \(targetParticles) (requested: \(targetCount), max safe: \(maxSafeParticles))")
            print("[hologram] 💾 Image memory: \(String(format: "%.1f", imageMemoryMB))MB, Particle memory: \(String(format: "%.1f", particleMemoryMB))MB")
            print("[hologram] 📐 Image size: \(width)×\(height) = \(availablePixels) pixels (1 particle per 16 pixels)")

            if targetParticles < targetCount {
                print("[hologram] ⚠️ Particle count reduced from \(targetCount) to \(targetParticles) for memory safety")
            } else {
                print("[hologram] ✅ Full particle count achieved: \(targetParticles) particles")
            }
            print("[hologram] 🔍 Starting particle processing...")
            print("[hologram] 📊 Pixel data validation - original: \(originalPixelData.count) bytes, depth: \(depthPixelData.count) bytes")

            var tempParticles: [ImageParticle] = []
            var processedCount = 0
            var rejectedCount = 0

            for y in stride(from: 0, to: height, by: baseSampleRate) {
                for x in stride(from: 0, to: width, by: baseSampleRate) {
                    let pixelIndex = (y * originalBytesPerRow) + (x * 4)

                    // Bounds checking to prevent buffer overruns
                    guard pixelIndex + 3 < originalPixelData.count && pixelIndex + 3 < depthPixelData.count else {
                        print("[hologram] ⚠️ Pixel index out of bounds: \(pixelIndex), max: \(originalPixelData.count)")
                        continue
                    }

                    // Get original image RGB
                    let r = Float(originalPixelData[pixelIndex]) / 255.0
                    let g = Float(originalPixelData[pixelIndex + 1]) / 255.0
                    let b = Float(originalPixelData[pixelIndex + 2]) / 255.0

                    // Get depth value (use red channel of depth mask)
                    // Invert so white=0 (near), black=1 (far)
                    let depthValue = 1.0 - (Float(depthPixelData[pixelIndex]) / 255.0)

                    // Position in world units (keep within ~±200 at zoom=1)
                    let maxDimension = max(width, height)
                    let scaleFactor = 400.0 / Float(maxDimension)
                    let posX = Float(x - width/2) * scaleFactor
                    let posY = Float(height/2 - y) * scaleFactor

                    // Depth map: 20 (near) → 80 (far)
                    let posZ = depthValue

                    // Category from brightness
                    let brightness = (r + g + b) / 3.0
                    let category: Float = (brightness < 0.2) ? 0.0 : (brightness < 0.5) ? 1.0 : (brightness < 0.8) ? 2.0 : 3.0

                    // Simple random emission seed - no need for complex hashing
                    let emissionSeed = Float.random(in: 0...1)

                    // Validate particle data to prevent GPU hangs
                    let position = SIMD3<Float>(posX, posY, posZ)
                    let color = SIMD3<Float>(r * 255, g * 255, b * 255)
                    let size = 0.5 + depthValue * 2.0
                    let pixelCoord = SIMD2<Float>(Float(x), Float(y))

                    // Check for invalid values that could hang the GPU
                    if !position.x.isFinite || !position.y.isFinite || !position.z.isFinite ||
                       !color.x.isFinite || !color.y.isFinite || !color.z.isFinite ||
                       !size.isFinite || !depthValue.isFinite ||
                       !pixelCoord.x.isFinite || !pixelCoord.y.isFinite ||
                       !emissionSeed.isFinite {

                        rejectedCount += 1
                        if rejectedCount <= 5 { // Only log first few rejections
                            print("[hologram] ⚠️ Invalid particle \(rejectedCount) at (\(x),\(y)): pos=\(position), color=\(color), depth=\(depthValue)")
                        }
                        continue
                    }

                    tempParticles.append(
                        ImageParticle(
                            position: position,
                            originalPosition: position,
                            color: color,
                            size: size,
                            opacity: 1.0,
                            category: category,
                            normalizedDepth: depthValue,
                            velocity: .zero,
                            pixelCoord: pixelCoord,
                            emissionSeed: emissionSeed
                        )
                    )

                    processedCount += 1
                    if processedCount % 5000 == 0 {
                        print("[hologram] 📊 Processed \(processedCount) particles...")
                    }
                }
            }

            // Center point (average)
            var sum = SIMD3<Float>(0,0,0)
            for p in tempParticles { sum += p.position }
            centerPoint = sum / Float(max(tempParticles.count, 1))

            // Sort back-to-front (optional with depth test; harmless here)
            tempParticles.sort { $0.position.z > $1.position.z }

            // Calculate buffer size first
            let tempParticleCount = tempParticles.count
            let bufferSize = MemoryLayout<ImageParticle>.stride * tempParticleCount

            // Validate buffer creation
            guard bufferSize > 0 && tempParticleCount > 0 else {
                print("[hologram] ❌ Invalid buffer parameters: size=\(bufferSize), count=\(tempParticleCount)")
                return
            }

            // Ensure Metal operations happen on main thread and update atomically
            DispatchQueue.main.async {
                // Create new buffer first
                guard let newParticleBuffer = self.device.makeBuffer(bytes: tempParticles, length: bufferSize, options: []) else {
                    print("[hologram] ❌ Failed to create particle buffer")
                    // Resume Metal view on failure
                    self.mtkView?.isPaused = false
                    return
                }

                // Pause Metal rendering during particle buffer update to prevent race conditions
                print("[hologram] ⏸️ Pausing Metal view for atomic particle buffer update")
                self.mtkView?.isPaused = true

                // Only update state after successful buffer creation (atomic update)
                self.particles = tempParticles
                self.particleCount = tempParticleCount
                self.particleBuffer = newParticleBuffer

                if self.uniformBuffer == nil {
                    self.uniformBuffer = self.device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: [])
                }

                // Update compute dispatch sizing for remote image particles
                self.numThreadgroups = MTLSize(
                    width: (self.particleCount + self.threadsPerGroup.width - 1) / self.threadsPerGroup.width,
                    height: 1,
                    depth: 1
                )

                print("[hologram] ✅ Generated \(self.particles.count) particles and updated GPU buffers")
                print("[hologram] 📊 Buffer size: \(bufferSize) bytes, particle stride: \(MemoryLayout<ImageParticle>.stride)")
                if rejectedCount > 0 {
                    print("[hologram] ⚠️ Rejected \(rejectedCount) invalid particles during generation")
                }

                // Resume Metal rendering after successful buffer update
                print("[hologram] ▶️ Resuming Metal view after particle buffer update")
                self.mtkView?.isPaused = false
            }
        }

        private func scaleImagesIfNeeded(originalImage: UIImage, maskImage: UIImage, maxDimension: Int) -> (UIImage, UIImage) {
            let originalSize = originalImage.size
            let maxDim = max(originalSize.width, originalSize.height)

            if maxDim <= CGFloat(maxDimension) {
                print("[hologram] 📏 Images are within size limit: \(Int(originalSize.width))×\(Int(originalSize.height))")
                return (originalImage, maskImage)
            }

            // Calculate scale factor
            let scaleFactor = CGFloat(maxDimension) / maxDim
            let newWidth = Int(originalSize.width * scaleFactor)
            let newHeight = Int(originalSize.height * scaleFactor)

            print("[hologram] 📏 Scaling images from \(Int(originalSize.width))×\(Int(originalSize.height)) to \(newWidth)×\(newHeight)")

            func scaleImage(_ image: UIImage, to size: CGSize) -> UIImage? {
                UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
                defer { UIGraphicsEndImageContext() }
                image.draw(in: CGRect(origin: .zero, size: size))
                return UIGraphicsGetImageFromCurrentImageContext()
            }

            let newSize = CGSize(width: newWidth, height: newHeight)
            guard let scaledOriginal = scaleImage(originalImage, to: newSize),
                  let scaledMask = scaleImage(maskImage, to: newSize) else {
                print("[hologram] ⚠️ Failed to scale images, using originals")
                return (originalImage, maskImage)
            }

            return (scaledOriginal, scaledMask)
        }

        private func loadParticlesFromDownloadedImages(originalImage: UIImage, maskImage: UIImage, targetCount: Int = 30000) {
            print("[hologram] 🎨 Processing downloaded images for particle generation...")

            // Debug image properties
            print("[hologram] 🔍 Original image - size: \(originalImage.size), scale: \(originalImage.scale)")
            print("[hologram] 🔍 Mask image - size: \(maskImage.size), scale: \(maskImage.scale)")

            // Check image size and potentially downscale
            let maxDimension = 768 // Limit to reduce memory pressure
            let (processedOriginal, processedMask) = scaleImagesIfNeeded(originalImage: originalImage, maskImage: maskImage, maxDimension: maxDimension)

            // Store current image data for rebuilds (store processed versions)
            currentImageData = (originalImage: processedOriginal, maskImage: processedMask)

            guard let originalCGImage = processedOriginal.cgImage,
                  let maskCGImage = processedMask.cgImage else {
                print("[hologram] ❌ Failed to get CGImage from processed images")
                loadTestPatternParticles(targetCount: targetCount)
                return
            }

            // Debug CGImage properties
            print("[hologram] 🔍 CGImage original - width: \(originalCGImage.width), height: \(originalCGImage.height)")
            print("[hologram] 🔍 CGImage original - colorSpace: \(String(describing: originalCGImage.colorSpace?.name))")
            print("[hologram] 🔍 CGImage original - bitsPerComponent: \(originalCGImage.bitsPerComponent), bitsPerPixel: \(originalCGImage.bitsPerPixel)")
            print("[hologram] 🔍 CGImage mask - width: \(maskCGImage.width), height: \(maskCGImage.height)")
            print("[hologram] 🔍 CGImage mask - colorSpace: \(String(describing: maskCGImage.colorSpace?.name))")

            let width = originalCGImage.width
            let height = originalCGImage.height
            imageDimensions = SIMD2<Float>(Float(width), Float(height))
            print("[hologram] 📷 Downloaded image dimensions: \(width)×\(height)")

            // Create bitmap contexts for pixel data access with consistent color space
            let originalBytesPerRow = width * 4
            let depthBytesPerRow = width * 4
            var originalPixelData = [UInt8](repeating: 0, count: height * originalBytesPerRow)
            var depthPixelData = [UInt8](repeating: 0, count: height * depthBytesPerRow)

            // Force sRGB color space for consistency
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                print("[hologram] ❌ Failed to create sRGB color space")
                loadTestPatternParticles(targetCount: targetCount)
                return
            }

            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

            guard let originalContext = CGContext(data: &originalPixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: originalBytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
                  let depthContext = CGContext(data: &depthPixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: depthBytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
                print("[hologram] ❌ Failed to create bitmap contexts")
                loadTestPatternParticles(targetCount: targetCount)
                return
            }

            print("[hologram] 🎨 Created bitmap contexts with sRGB color space")

            // Draw images into contexts
            originalContext.draw(originalCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            depthContext.draw(maskCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            // Generate particles from the downloaded images
            generateParticlesFromPixelData(originalPixelData: originalPixelData, depthPixelData: depthPixelData, width: width, height: height, targetCount: targetCount)
        }

        private func loadParticlesFromImages(targetCount: Int = 30000) {
            print("[hologram] 📷 Loading hologram particles from local images...")

            // Clear remote image state since we're loading local images
            currentImageURL = nil
            currentImageData = nil
            isUsingRemoteImage = false

            // Debug: List available resources
            if let resourcePath = Bundle.main.resourcePath {
                print("🔍 Resource path: \(resourcePath)")
                do {
                    let contents = try FileManager.default.contentsOfDirectory(atPath: resourcePath)
                    let pngFiles = contents.filter { $0.hasSuffix(".png") }
                    print("🔍 Available PNG files: \(pngFiles)")
                } catch {
                    print("❌ Could not list resource directory: \(error)")
                }
            }
            
            guard let originalImagePath = Bundle.main.path(forResource: "edkilo", ofType: "png"),
                  let depthImagePath = Bundle.main.path(forResource: "edkilo_mask", ofType: "png") else {
                print("❌ Failed to find image paths in bundle")
                print("🔍 Trying alternative approach...")
                loadTestPatternParticles(targetCount: targetCount)
                return
            }
            
            guard let originalImage = UIImage(contentsOfFile: originalImagePath),
                  let depthImage = UIImage(contentsOfFile: depthImagePath),
                  let originalCGImage = originalImage.cgImage,
                  let depthCGImage = depthImage.cgImage else {
                print("❌ Failed to load edkilo.png and edkilo_mask.png images from paths")
                print("🔍 Trying alternative approach...")
                loadTestPatternParticles(targetCount: targetCount)
                return
            }
            
            let width = originalCGImage.width
            let height = originalCGImage.height
            imageDimensions = SIMD2<Float>(Float(width), Float(height))
            print("📷 Image dimensions: \(width)×\(height)")
            
            // Create bitmap contexts for pixel data access
            let originalBytesPerRow = width * 4
            let depthBytesPerRow = width * 4
            var originalPixelData = [UInt8](repeating: 0, count: height * originalBytesPerRow)
            var depthPixelData = [UInt8](repeating: 0, count: height * depthBytesPerRow)
            
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            
            guard let originalContext = CGContext(data: &originalPixelData,
                                                width: width,
                                                height: height,
                                                bitsPerComponent: 8,
                                                bytesPerRow: originalBytesPerRow,
                                                space: colorSpace,
                                                bitmapInfo: bitmapInfo.rawValue),
                  let depthContext = CGContext(data: &depthPixelData,
                                             width: width,
                                             height: height,
                                             bitsPerComponent: 8,
                                             bytesPerRow: depthBytesPerRow,
                                             space: colorSpace,
                                             bitmapInfo: bitmapInfo.rawValue) else {
                print("❌ Failed to create bitmap contexts")
                return
            }
            
            // Draw images to contexts
            originalContext.draw(originalCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            depthContext.draw(depthCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            
            let targetParticles = targetCount
            let availablePixels = width * height
            let baseSampleRate = max(1, Int((Float(availablePixels) / Float(targetParticles)).squareRoot()))
            print("📐 Using sample rate: \(baseSampleRate)")
            print("🔍 Starting particle processing...")
            
            var tempParticles: [ImageParticle] = []
            var processedCount = 0
            var rejectedCount = 0
            
            for y in stride(from: 0, to: height, by: baseSampleRate) {
                for x in stride(from: 0, to: width, by: baseSampleRate) {
                    let pixelIndex = (y * originalBytesPerRow) + (x * 4)
                    
                    // Get original image RGB
                    let r = Float(originalPixelData[pixelIndex]) / 255.0
                    let g = Float(originalPixelData[pixelIndex + 1]) / 255.0
                    let b = Float(originalPixelData[pixelIndex + 2]) / 255.0
                    
                    // Get depth value (use red channel of depth mask)
                    // Invert so white=0 (near), black=1 (far)
                    let depthValue = 1.0 - (Float(depthPixelData[pixelIndex]) / 255.0)
                    
                    // Position in world units (keep within ~±200 at zoom=1)
                    let maxDimension = max(width, height)
                    let scaleFactor = 400.0 / Float(maxDimension)
                    let posX = Float(x - width/2) * scaleFactor
                    let posY = Float(height/2 - y) * scaleFactor
                    
                    // Depth map: 20 (near) → 80 (far)
                    let posZ = depthValue
                    
                    // Category from brightness
                    let brightness = (r + g + b) / 3.0
                    let category: Float = (brightness < 0.2) ? 0.0 : (brightness < 0.5) ? 1.0 : (brightness < 0.8) ? 2.0 : 3.0

                    // Simple random emission seed - no need for complex hashing
                    let emissionSeed = Float.random(in: 0...1)

                    // Validate particle data to prevent GPU hangs
                    let position = SIMD3<Float>(posX, posY, posZ)
                    let color = SIMD3<Float>(r * 255, g * 255, b * 255)
                    let size = 0.5 + depthValue * 2.0
                    let pixelCoord = SIMD2<Float>(Float(x), Float(y))

                    // Check for invalid values that could hang the GPU
                    if !position.x.isFinite || !position.y.isFinite || !position.z.isFinite ||
                       !color.x.isFinite || !color.y.isFinite || !color.z.isFinite ||
                       !size.isFinite || !depthValue.isFinite ||
                       !pixelCoord.x.isFinite || !pixelCoord.y.isFinite ||
                       !emissionSeed.isFinite {

                        rejectedCount += 1
                        if rejectedCount <= 5 { // Only log first few rejections
                            print("[hologram] ⚠️ Invalid particle \(rejectedCount) at (\(x),\(y)): pos=\(position), color=\(color), depth=\(depthValue)")
                        }
                        continue
                    }

                    tempParticles.append(
                        ImageParticle(
                            position: position,
                            originalPosition: position,
                            color: color,
                            size: size,
                            opacity: 1.0,
                            category: category,
                            normalizedDepth: depthValue,
                            velocity: .zero,
                            pixelCoord: pixelCoord,
                            emissionSeed: emissionSeed
                        )
                    )
                    
                    processedCount += 1
                    if processedCount % 5000 == 0 {
                        print("📊 Processed \(processedCount) particles...")
                    }
                }
            }
            
            // Center point (average)
            var sum = SIMD3<Float>(0,0,0)
            for p in tempParticles { sum += p.position }
            centerPoint = sum / Float(max(tempParticles.count, 1))
            
            // Sort back-to-front (optional with depth test; harmless here)
            tempParticles.sort { $0.position.z > $1.position.z }

            // Debug: Check depth distribution
            let depths = tempParticles.map { (($0.originalPosition.z - 20.0) / 60.0) } // Convert Z back to depth
            let minDepth = depths.min() ?? 0
            let maxDepth = depths.max() ?? 0
            let avgDepth = depths.reduce(0, +) / Float(depths.count)
            print("✅ Created \(tempParticles.count) particles - Depth range: \(minDepth)-\(maxDepth), avg: \(avgDepth)")

            // Check how many particles are in front vs back
            let frontCount = depths.filter { $0 < 0.3 }.count
            let backCount = depths.filter { $0 > 0.7 }.count
            print("📊 Particle depth distribution: Front(\(frontCount)) vs Back(\(backCount))")

            // Atomic update on main thread
            DispatchQueue.main.async {
                // Create GPU buffers first
                let bufferSize = MemoryLayout<ImageParticle>.stride * tempParticles.count
                guard let newParticleBuffer = self.device.makeBuffer(bytes: tempParticles, length: bufferSize, options: []),
                      let newUniformBuffer = self.device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: []) else {
                    print("[hologram] ❌ Failed to create GPU buffers for local images")
                    // Resume Metal view on failure
                    self.mtkView?.isPaused = false
                    return
                }

                // Pause Metal rendering during particle buffer update to prevent race conditions
                print("[hologram] ⏸️ Pausing Metal view for local image particle buffer update")
                self.mtkView?.isPaused = true

                // Update state atomically
                self.particles = tempParticles
                self.particleCount = tempParticles.count
                self.particleBuffer = newParticleBuffer
                self.uniformBuffer = newUniformBuffer

                // Compute dispatch sizing
                self.numThreadgroups = MTLSize(
                    width: (self.particleCount + self.threadsPerGroup.width - 1) / self.threadsPerGroup.width,
                    height: 1,
                    depth: 1
                )
                print("✅ Buffers ready")

                // Resume Metal rendering after successful buffer update
                print("[hologram] ▶️ Resuming Metal view after local image particle buffer update")
                self.mtkView?.isPaused = false
            }
        }
        
        private func loadTestPatternParticles(targetCount: Int = 30000) {
            print("📷 Loading fallback test pattern particles...")
            
            // Create a simple test pattern as fallback
            var tempParticles: [ImageParticle] = []
            let gridSize = Int(sqrt(Float(targetCount))) // Dynamic grid size based on target count
            
            for x in 0..<gridSize {
                for y in 0..<gridSize {
                    let posX = Float(x - gridSize/2) * 2.0
                    let posY = Float(y - gridSize/2) * 2.0
                    let posZ = 50.0 + sin(Float(x) * 0.1) * sin(Float(y) * 0.1) * 20.0
                    
                    let distance = sqrt(posX * posX + posY * posY)
                    let hue = distance * 0.01
                    let r = sin(hue) * 0.5 + 0.5
                    let g = sin(hue + 2.0) * 0.5 + 0.5
                    let b = sin(hue + 4.0) * 0.5 + 0.5

                    // Simple random emission seed - no need for complex hashing
                    let emissionSeed = Float.random(in: 0...1)

                    tempParticles.append(
                        ImageParticle(
                            position: SIMD3<Float>(posX, posY, posZ),
                            originalPosition: SIMD3<Float>(posX, posY, posZ),
                            color: SIMD3<Float>(r * 255, g * 255, b * 255),
                            size: 0.5 + sin(distance * 0.1) * 0.5,
                            opacity: 1.0,
                            category: Float(x % 4),
                            normalizedDepth: Float.random(in: 0...1), // Random depth for testing background hiding
                            velocity: .zero,
                            pixelCoord: SIMD2<Float>(Float(x), Float(y)),
                            emissionSeed: emissionSeed // Random seed for emission timing
                        )
                    )
                }
            }

            // Atomic update on main thread
            DispatchQueue.main.async {
                // Create GPU buffers first
                let bufferSize = MemoryLayout<ImageParticle>.stride * tempParticles.count
                guard let newParticleBuffer = self.device.makeBuffer(bytes: tempParticles, length: bufferSize, options: []),
                      let newUniformBuffer = self.device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: []) else {
                    print("[hologram] ❌ Failed to create GPU buffers for test pattern")
                    // Resume Metal view on failure
                    self.mtkView?.isPaused = false
                    return
                }

                // Pause Metal rendering during particle buffer update to prevent race conditions
                print("[hologram] ⏸️ Pausing Metal view for test pattern particle buffer update")
                self.mtkView?.isPaused = true

                // Update state atomically
                self.particles = tempParticles
                self.particleCount = tempParticles.count
                self.particleBuffer = newParticleBuffer
                self.uniformBuffer = newUniformBuffer

                // Compute dispatch sizing
                self.numThreadgroups = MTLSize(
                    width: (self.particleCount + self.threadsPerGroup.width - 1) / self.threadsPerGroup.width,
                    height: 1,
                    depth: 1
                )

                print("✅ Created \(self.particleCount) test pattern particles")

                // Resume Metal rendering after successful buffer update
                print("[hologram] ▶️ Resuming Metal view after test pattern particle buffer update")
                self.mtkView?.isPaused = false
            }
        }
        
        private func setupGestures() {
            guard let view = mtkView else { return }
            
            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            
            view.addGestureRecognizer(pinchGesture)
            view.addGestureRecognizer(panGesture)
        }
        
        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .changed {
                zoom *= Float(gesture.scale)
                zoom = max(0.1, min(2.0, zoom))
                gesture.scale = 1.0
            }
        }
        
        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .changed {
                let translation = gesture.translation(in: gesture.view)
                rotation += Float(translation.x) * 0.01
                gesture.setTranslation(.zero, in: gesture.view)
            }
        }
        
        // Touch handling for synthesis
        func handleTouchesBegan(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) {
            for touch in touches {
                let location = touch.location(in: view)
                let noteNumber = calculateNoteFromLocation(location, in: view)
                
                if let metalSynth = metalSynth {
                    let velocity = Float(0.5 + (location.x / view.bounds.width) * 0.4)
                    let wavetablePos = Float(location.x / view.bounds.width)
                    metalSynth.noteOn(noteNumber: noteNumber, velocity: velocity, wavetablePosition: wavetablePos)
                    activeTouches[touch] = noteNumber
                }
            }
        }
        
        func handleTouchesEnded(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) {
            for touch in touches {
                if let noteNumber = activeTouches[touch], let metalSynth = metalSynth {
                    metalSynth.noteOff(noteNumber: noteNumber)
                    activeTouches.removeValue(forKey: touch)
                }
            }
        }
        
        private func calculateNoteFromLocation(_ location: CGPoint, in view: UIView) -> Int {
            let x = Float(location.x / view.bounds.width)
            let y = Float(location.y / view.bounds.height)
            
            let celestialScale = celestialScales[currentScaleIndex]
            let baseNote = 60 + (baseOctave * 12)
            
            let octaveShift = Int((1.0 - y) * 24.0 - 12.0)
            let scaleIndex = Int(x * Float(celestialScale.count - 1))
            let noteOffset = celestialScale[scaleIndex]
            
            return max(0, min(127, baseNote + octaveShift + noteOffset))
        }
        
        // Matrix helper functions
        private func perspectiveRH(fovyRadians f: Float, aspect a: Float, near n: Float, far fz: Float) -> simd_float4x4 {
            let t = tanf(f * 0.5)
            let sx: Float = 1.0 / (a * t)
            let sy: Float = 1.0 / t
            let sz: Float = fz / (n - fz)
            let tz: Float = (fz * n) / (n - fz)
            return simd_float4x4(
                SIMD4<Float>( sx,  0,  0,  0),
                SIMD4<Float>(  0, sy,  0,  0),
                SIMD4<Float>(  0,  0, sz, -1),
                SIMD4<Float>(  0,  0, tz,  0)
            )
        }
        
        private func lookAtRH(eye e: SIMD3<Float>, center c: SIMD3<Float>, up u: SIMD3<Float>) -> simd_float4x4 {
            let f = simd_normalize(c - e)
            let s = simd_normalize(simd_cross(f, u))
            let v = simd_cross(s, f)
            let m = simd_float4x4(
                SIMD4<Float>( s.x, v.x, -f.x, 0),
                SIMD4<Float>( s.y, v.y, -f.y, 0),
                SIMD4<Float>( s.z, v.z, -f.z, 0),
                SIMD4<Float>(  0,   0,    0,  1)
            )
            let t = simd_float4x4(
                SIMD4<Float>(1,0,0,0),
                SIMD4<Float>(0,1,0,0),
                SIMD4<Float>(0,0,1,0),
                SIMD4<Float>(-e.x, -e.y, -e.z, 1)
            )
            return m * t
        }
        
        // MTKViewDelegate methods
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle size changes if needed
        }
        
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let uniformBuffer = uniformBuffer,
                  let particleBuffer = particleBuffer,
                  let renderPipelineState = renderPipelineState,
                  let physicsComputePipelineState = physicsComputePipelineState,
                  let depthStencilState = depthStencilState else {
                return
            }

            // Validate buffer/count consistency to prevent GPU faults
            let expectedBufferSize = MemoryLayout<ImageParticle>.stride * particleCount
            if particleBuffer.length < expectedBufferSize {
                print("[hologram] ⚠️ Buffer/count mismatch: buffer=\(particleBuffer.length), expected=\(expectedBufferSize), count=\(particleCount)")
                return
            }

            // Additional safety check
            guard particleCount > 0 && particleCount <= particles.count else {
                print("[hologram] ⚠️ Invalid particle count: \(particleCount), particles array: \(particles.count)")
                return
            }
            
            // Update animation
            time += 1.0 / 60.0
            // Pause rotation in globe mode - keep our side facing us
            if !isInGlobeMode {
                rotation += rotSpeed * 0.01
                if rotation > 2 * .pi { rotation -= 2 * .pi }
            }
            
            // Setup camera matrices
            let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
            let proj = perspectiveRH(fovyRadians: 45.0 * .pi / 180.0, aspect: aspect, near: 1.0, far: 2000.0)
            
            let zoomedCameraEye = SIMD3<Float>(cameraEye.x, cameraEye.y, cameraEye.z / zoom)
            let viewM = lookAtRH(eye: zoomedCameraEye, center: cameraCenter, up: cameraUp)
            let mvp = proj * viewM
            
            // Helper function to convert puck coordinates properly
            func puckPointInLocalPixels(for view: MTKView, puckPointInScreenPoints: CGPoint) -> CGPoint {
                // 1) Convert from screen/window coordinates into the MTKView's local coordinates (points).
                // If your puck point is already in the MTKView's coords, this conversion is a no-op.
                let localInPoints: CGPoint = {
                    if let window = view.window {
                        // Treat the input as window (screen) coordinates by default
                        return view.convert(puckPointInScreenPoints, from: window)
                    } else {
                        // Fallback: assume it's already local
                        return puckPointInScreenPoints
                    }
                }()

                // Clamp just in case (optional safety)
                let clampedX = max(0, min(localInPoints.x, view.bounds.width))
                let clampedY = max(0, min(localInPoints.y, view.bounds.height))

                // 2) Points → Pixels using display scale
                let scale = view.window?.screen.scale ?? view.contentScaleFactor
                return CGPoint(x: clampedX * scale, y: clampedY * scale)
            }

            // Choose the plane where you want the emitter to live
            let planeZ: Float = 50.0 + yOffset

            // Resolve a fallback if no puck provided
            let fallback = CGPoint(x: view.bounds.width / 2, y: view.bounds.height * 0.75)
            let puckPoints = (puckScreenPosition == .zero) ? fallback : puckScreenPosition

            // 1) Get the puck point in this MTKView's local *pixels*
            let puckLocalPixels = puckPointInLocalPixels(for: view, puckPointInScreenPoints: puckPoints)

            // 2) Pixels → NDC using drawableSize (also in pixels)
            let dw = max(view.drawableSize.width,  1)
            let dh = max(view.drawableSize.height, 1)
            let ndcX = Float((puckLocalPixels.x / dw) * 2.0 - 1.0)
            // UIKit Y grows downward; NDC Y grows upward
            let ndcY = Float(1.0 - (puckLocalPixels.y / dh) * 2.0)

            // 3) Unproject near/far clip points
            let nearClip = SIMD4<Float>(ndcX, ndcY, -1.0, 1.0)
            let farClip  = SIMD4<Float>(ndcX, ndcY,  1.0, 1.0)

            let invProj = simd_inverse(proj)
            let invView = simd_inverse(viewM)

            var nearView = invProj * nearClip
            var farView  = invProj * farClip
            nearView /= nearView.w
            farView  /= farView.w

            var nearWorld = invView * nearView
            var farWorld  = invView * farView
            nearWorld /= nearWorld.w
            farWorld  /= farWorld.w

            let rayOrigin = SIMD3<Float>(nearWorld.x, nearWorld.y, nearWorld.z)
            let rayEnd    = SIMD3<Float>(farWorld.x,  farWorld.y,  farWorld.z)
            let rayDir    = simd_normalize(rayEnd - rayOrigin)

            // 4) Intersect with z = planeZ
            var puckWorldPos = SIMD3<Float>(0, 0, planeZ)
            let denom = rayDir.z
            if abs(denom) > 1e-6 {
                let t = (planeZ - rayOrigin.z) / denom
                let hit = rayOrigin + t * rayDir
                puckWorldPos = SIMD3<Float>(hit.x, hit.y, planeZ)
            }

            // print("🎯 Puck conversion: screenPoints=\(puckPoints) → localPixels=\(puckLocalPixels) → NDC=(\(ndcX),\(ndcY)) → worldPos=\(puckWorldPos)")

            // 6) Fill uniforms with this *unprojected* world position
            var uniforms = Uniforms(
                mvpMatrix: proj * viewM,
                viewMatrix: viewM,
                rotation: rotation,
                time: time,
                sizeMultiplier: sizeMultiplier,
                zoom: zoom,
                depthScale: depthScale,
                bgMin: bgMin,
                bgMax: bgMax,
                arcRadius: arcRadius,
                dissolve: dissolve,
                wobble: wobble,
                wobbleSpeed: wobbleSpeed,
                yOffset: yOffset,
                centerPoint: SIMD4<Float>(centerPoint.x, centerPoint.y, centerPoint.z, 0),
                imageDimensions: imageDimensions,
                aspectRatio: aspect,
                _padA: 0,
                puckWorldPosition: SIMD4<Float>(puckWorldPos.x, puckWorldPos.y, puckWorldPos.z, 0),
                emissionDensity: emissionDensity,          // now arrives correctly
                emissionPeriodSec: emissionPeriodSec,
                travelTimeSec: travelTimeSec,
                arcHeight: arcHeight,
                particleBlink: particleBlink,
                particleRandomSize: particleRandomSize,
                particleGlow: particleGlow
            )

            // Debug logging for background hiding values being sent to shader
            if Int(time * 10) % 300 == 0 { // Log once per 30 seconds instead of every second
                print("[emission] 🎭 Uniforms bgMin=\(uniforms.bgMin), bgMax=\(uniforms.bgMax), emissionDensity=\(uniforms.emissionDensity)")
            }

            uniformBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.size)
            
            let commandBuffer = commandQueue.makeCommandBuffer()!
            
            // Run compute shader for physics with validation
            // Fixed: Remote images now properly update numThreadgroups
            let shouldRunComputeShader = true

            if shouldRunComputeShader {
                if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
                    computeEncoder.setComputePipelineState(physicsComputePipelineState)
                    computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
                    computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 1)
                    computeEncoder.dispatchThreadgroups(numThreadgroups, threadsPerThreadgroup: threadsPerGroup)
                    computeEncoder.endEncoding()
                }
            }
            
            // Render particles
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                encoder.setDepthStencilState(depthStencilState)
                encoder.setRenderPipelineState(renderPipelineState)
                encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
                encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
                encoder.endEncoding()
            }
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
