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
    var looseness: Float
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
    var bgHide: Float
    var dissolve: Float
    var wobble: Float
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
        
        // Animation parameters
        private var time: Float = 0
        private var rotation: Float = 0
        private var rotSpeed: Float = 0.6
        private var sizeMultiplier: Float = 0.4
        private var zoom: Float = 0.5
        private var depthScale: Float = -5.0
        private var bgHide: Float = 1.0
        private var dissolve: Float = 0.0
        private var wobble: Float = 0.0
        private var yOffset: Float = 0.0
        private var emissionDensity: Float = 0.8
        private var emissionPeriodSec: Float = 8.0
        private var travelTimeSec: Float = 5.0
        private var arcHeight: Float = 50.0
        
        // Puck emission system - lifecycle phase for existing particles
        private var puckScreenPosition: CGPoint = CGPoint(x: 0, y: 0)
        private let maxEmittingParticles = 150 // How many particles emit at once

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
            depthScale = settings.hologramDepth // Direct mapping: -10 to +10
            bgHide = settings.hologramBgHide
            dissolve = settings.hologramDissolve
            wobble = settings.hologramWobble
            yOffset = settings.hologramYPosition * 250.0 // Map -1 to +1 to -250 to +250 units (positive = up) - 2.5x higher
            emissionDensity = settings.hologramEmissionDensity

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

        private func scheduleParticleRebuild(newCount: Int) {
            // Cancel any existing timer
            particleRebuildTimer?.invalidate()

            // Schedule new rebuild with 0.5s debouncing
            particleRebuildTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.rebuildParticleSystem(targetCount: newCount)
            }
        }

        private func rebuildParticleSystem(targetCount: Int) {
            print("🔨 Rebuilding particle system with \(targetCount) particles...")

            // Update current count
            currentParticleCount = targetCount

            // Reload particles with new target count
            loadParticlesFromImages(targetCount: targetCount)

            print("✅ Particle system rebuilt with \(particleCount) particles")
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
                float  looseness;
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
                float    bgHide;
                float    dissolve;
                float    wobble;
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
            };

            struct VertexOut {
                float4 position [[position]];
                float  point_size [[point_size]];
                float3 color;
                float  opacity;
                float  category;
                float  looseness;
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
                
                // Background hiding
                if (uniforms.bgHide > 0.0) {
                    float normalizedDepth = p.looseness;
                    float fadeStart = 1.0 - uniforms.bgHide;
                    float fadeEnd = 1.0;
                    float fadeAmount = smoothstep(fadeStart, fadeEnd, normalizedDepth);
                    validOpacity = validOpacity * (1.0 - fadeAmount);
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

                float finalSize = clamp(baseSize * (140.0 / viewZ) * uniforms.sizeMultiplier, 1.0, 200.0);

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
                out.looseness  = p.looseness;
                return out;
            }

            fragment float4 fragment_main(VertexOut in [[stage_in]],
                                          constant Uniforms& uniforms [[buffer(0)]],
                                          float2 pointCoord [[point_coord]]) {
                float2 uv = pointCoord - float2(0.5, 0.5);
                float dist = length(uv);

                float shapeAlpha = (dist < 0.5) ? 1.0 : 0.0;
                if (shapeAlpha < 0.1) discard_fragment();

                float alpha = in.opacity * shapeAlpha;
                if (alpha <= 0.01) discard_fragment();

                return float4(in.color, alpha);
            }

            kernel void unified_physics(device ImageParticle* particles [[buffer(0)]],
                                        constant Uniforms& uniforms     [[buffer(1)]],
                                        uint id [[thread_position_in_grid]]) {
                device ImageParticle& particle = particles[id];

                float3 hologramPos = particle.originalPosition;
                
                // Depth scaling controlled by slider
                float originalZ = particle.originalPosition.z;
                float frontZ = 20.0;
                float backZ = 80.0;
                
                float normalizedDepth = (originalZ - frontZ) / (backZ - frontZ);
                normalizedDepth = clamp(normalizedDepth, 0.0, 1.0);
                
                // When depthScale = 0, all particles are on same plane (50.0)
                // When depthScale != 0, particles spread based on depth mask
                float depthOffset = normalizedDepth * uniforms.depthScale * 10.0;
                hologramPos.z = 50.0 - depthOffset;

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
                    
                    float time1 = uniforms.time + hash1 * 6.28;
                    float time2 = uniforms.time + hash2 * 6.28;
                    float time3 = uniforms.time + hash3 * 6.28;
                    
                    float wobbleAmount = uniforms.wobble * 10.0;
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

                    // Visible while in-flight; immune to bgHide
                    particle.size = 1.5;
                    particle.looseness = 0.0;
                } else {
                    // Flight complete; fall back to normal hologram behavior
                    particle.looseness = normalizedDepth;
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
        
        private func loadParticlesFromImages(targetCount: Int = 30000) {
            print("📷 Loading hologram particles from images...")
            
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
            
            for y in stride(from: 0, to: height, by: baseSampleRate) {
                for x in stride(from: 0, to: width, by: baseSampleRate) {
                    let pixelIndex = (y * originalBytesPerRow) + (x * 4)
                    
                    // Get original image RGB
                    let r = Float(originalPixelData[pixelIndex]) / 255.0
                    let g = Float(originalPixelData[pixelIndex + 1]) / 255.0
                    let b = Float(originalPixelData[pixelIndex + 2]) / 255.0
                    
                    // Get depth value (use red channel of depth mask)
                    let depthValue = Float(depthPixelData[pixelIndex]) / 255.0
                    
                    // Position in world units (keep within ~±200 at zoom=1)
                    let maxDimension = max(width, height)
                    let scaleFactor = 400.0 / Float(maxDimension)
                    let posX = Float(x - width/2) * scaleFactor
                    let posY = Float(height/2 - y) * scaleFactor
                    
                    // Depth map: 20 (near) → 80 (far)
                    let posZ = 20.0 + (1.0 - depthValue) * 60.0
                    
                    // Category from brightness
                    let brightness = (r + g + b) / 3.0
                    let category: Float = (brightness < 0.2) ? 0.0 : (brightness < 0.5) ? 1.0 : (brightness < 0.8) ? 2.0 : 3.0

                    // Simple random emission seed - no need for complex hashing
                    let emissionSeed = Float.random(in: 0...1)

                    tempParticles.append(
                        ImageParticle(
                            position: SIMD3<Float>(posX, posY, posZ),
                            originalPosition: SIMD3<Float>(posX, posY, posZ),
                            color: SIMD3<Float>(r * 255, g * 255, b * 255),
                            size: 0.5 + depthValue * 2.0,
                            opacity: 1.0,
                            category: category,
                            looseness: 0.0,
                            velocity: .zero,
                            pixelCoord: SIMD2<Float>(Float(x), Float(y)),
                            emissionSeed: emissionSeed // Random seed for emission timing
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
            
            // All particles are hologram particles with emission lifecycle
            particles = tempParticles
            particleCount = particles.count

            // Debug: Check depth distribution
            let depths = particles.map { (($0.originalPosition.z - 20.0) / 60.0) } // Convert Z back to depth
            let minDepth = depths.min() ?? 0
            let maxDepth = depths.max() ?? 0
            let avgDepth = depths.reduce(0, +) / Float(depths.count)
            print("✅ Created \(tempParticles.count) particles - Depth range: \(minDepth)-\(maxDepth), avg: \(avgDepth)")

            // Check how many particles are in front vs back
            let frontCount = depths.filter { $0 < 0.3 }.count
            let backCount = depths.filter { $0 > 0.7 }.count
            print("📊 Particle depth distribution: Front(\(frontCount)) vs Back(\(backCount))")
            
            // GPU buffers
            let bufferSize = MemoryLayout<ImageParticle>.stride * particleCount
            particleBuffer = device.makeBuffer(bytes: particles, length: bufferSize, options: [])
            uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: [])
            
            // Compute dispatch sizing
            numThreadgroups = MTLSize(
                width: (particleCount + threadsPerGroup.width - 1) / threadsPerGroup.width,
                height: 1,
                depth: 1
            )
            print("✅ Buffers ready")
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
                            looseness: 0.0,
                            velocity: .zero,
                            pixelCoord: SIMD2<Float>(Float(x), Float(y)),
                            emissionSeed: emissionSeed // Random seed for emission timing
                        )
                    )
                }
            }
            
            // All particles are hologram particles with emission lifecycle
            particles = tempParticles
            particleCount = particles.count
            
            // Create GPU buffers
            let bufferSize = MemoryLayout<ImageParticle>.stride * particleCount
            particleBuffer = device.makeBuffer(bytes: particles, length: bufferSize, options: [])
            uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: [])
            
            // Compute dispatch sizing
            numThreadgroups = MTLSize(
                width: (particleCount + threadsPerGroup.width - 1) / threadsPerGroup.width,
                height: 1,
                depth: 1
            )
            
            print("✅ Created \(particleCount) test pattern particles")
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
            
            // Update animation
            time += 1.0 / 60.0
            rotation += rotSpeed * 0.01
            if rotation > 2 * .pi { rotation -= 2 * .pi }
            
            // Setup camera matrices
            let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
            let proj = perspectiveRH(fovyRadians: 45.0 * .pi / 180.0, aspect: aspect, near: 0.1, far: 2000.0)
            
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

            print("🎯 Puck conversion: screenPoints=\(puckPoints) → localPixels=\(puckLocalPixels) → NDC=(\(ndcX),\(ndcY)) → worldPos=\(puckWorldPos)")

            // 6) Fill uniforms with this *unprojected* world position
            var uniforms = Uniforms(
                mvpMatrix: proj * viewM,
                viewMatrix: viewM,
                rotation: rotation,
                time: time,
                sizeMultiplier: sizeMultiplier,
                zoom: zoom,
                depthScale: depthScale,
                bgHide: bgHide,
                dissolve: dissolve,
                wobble: wobble,
                yOffset: yOffset,
                centerPoint: SIMD4<Float>(centerPoint.x, centerPoint.y, centerPoint.z, 0),
                imageDimensions: imageDimensions,
                aspectRatio: aspect,
                _padA: 0,
                puckWorldPosition: SIMD4<Float>(puckWorldPos.x, puckWorldPos.y, puckWorldPos.z, 0),
                emissionDensity: emissionDensity,          // now arrives correctly
                emissionPeriodSec: emissionPeriodSec,
                travelTimeSec: travelTimeSec,
                arcHeight: arcHeight
            )
            uniformBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.size)
            
            let commandBuffer = commandQueue.makeCommandBuffer()!
            
            // Run compute shader for physics
            if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
                computeEncoder.setComputePipelineState(physicsComputePipelineState)
                computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
                computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 1)
                computeEncoder.dispatchThreadgroups(numThreadgroups, threadsPerThreadgroup: threadsPerGroup)
                computeEncoder.endEncoding()
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
