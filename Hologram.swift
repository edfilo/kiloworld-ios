#!/usr/bin/env swift

import Cocoa
import Metal
import MetalKit
import simd

// MARK: - MTKView subclass

class InteractiveMetalView: MTKView {
    var renderer: ImageSampledHologramRenderer?
}

// MARK: - Shared types (Swift ⇄ Metal must match)

struct ImageParticle {
    var position: SIMD3<Float>
    var originalPosition: SIMD3<Float>
    var color: SIMD3<Float>      // 0–255 in each channel (normalized in shader)
    var size: Float
    var opacity: Float
    var category: Float
    var normalizedDepth: Float
    var velocity: SIMD3<Float>
    var pixelCoord: SIMD2<Float>
}

// IMPORTANT: Keep this layout in sync with the Metal Uniforms struct.
// We moved to a proper camera pipeline: world → view → clip (M*V*P).
struct Uniforms {
    var mvpMatrix: simd_float4x4
    var viewMatrix: simd_float4x4

    // Controls (still used by compute)
    var rotation: Float
    var time: Float
    var sizeMultiplier: Float
    var zoom: Float
    var depthScale: Float
    var bgHide: Float
    var dissolve: Float
    var wobble: Float
    var centerPoint: SIMD3<Float>
    var imageDimensions: SIMD2<Float>
    var aspectRatio: Float   // not used in shaders anymore, kept for binary compatibility/alignment

    // Pad to 16B alignment (Metal constant buffer safety)
    var _pad0: SIMD3<Float> = .zero
    var _pad1: Float = 0
}

// MARK: - Renderer

class ImageSampledHologramRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var renderPipelineState: MTLRenderPipelineState!
    var physicsComputePipelineState: MTLComputePipelineState!
    var particleBuffer: MTLBuffer!
    var uniformBuffer: MTLBuffer!
    var depthStencilState: MTLDepthStencilState!

    var particles: [ImageParticle] = []
    var particleCount: Int = 0

    // Hologram + image info
    var centerPoint = SIMD3<Float>(0, 0, 0)
    var imageDimensions = SIMD2<Float>(0, 0)

    // Controls
    var time: Float = 0
    var rotation: Float = 0
    var rotSpeed: Float = 0.6
    var sizeMultiplier: Float = 0.4
    var zoom: Float = 0.5
    var depthScale: Float = -5.0
    var bgHide: Float = 1.0
    var dissolve: Float = 0.0
    var wobble: Float = 0.0

    // Compute dispatch
    private let threadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)
    private var numThreadgroups = MTLSize(width: 1, height: 1, depth: 1)

    // Camera (right-handed)
    var cameraEye = SIMD3<Float>(0, 0, 250)
    var cameraCenter = SIMD3<Float>(0, 0, 0)
    var cameraUp = SIMD3<Float>(0, 1, 0)

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        super.init()

        setupMetal()
        loadParticlesFromImages()
    }

    // MARK: - Matrix helpers

    func perspectiveRH(fovyRadians f: Float, aspect a: Float, near n: Float, far fz: Float) -> simd_float4x4 {
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

    func lookAtRH(eye e: SIMD3<Float>, center c: SIMD3<Float>, up u: SIMD3<Float>) -> simd_float4x4 {
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

    // MARK: - Metal setup

    func setupMetal() {
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)

        // Shaders (Metal)
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
        };

        struct Uniforms {
            float4x4 mvpMatrix;
            float4x4 viewMatrix;

            float rotation;
            float time;
            float sizeMultiplier;
            float zoom;
            float depthScale;
            float bgHide;
            float dissolve;
            float wobble;
            float3 centerPoint;
            float2 imageDimensions;
            float aspectRatio;   // not used (legacy)

            float3 _pad0;        // alignment
            float  _pad1;
        };

        struct VertexOut {
            float4 position [[position]];
            float  point_size [[point_size]];
            float3 color;
            float  opacity;
            float  category;
            float  normalizedDepth;
        };

        // ====================
        // Vertex (proper MVP)
        // ====================
        vertex VertexOut vertex_main(constant ImageParticle* particles [[buffer(0)]],
                                     constant Uniforms& uniforms        [[buffer(1)]],
                                     uint vertexID                       [[vertex_id]]) {
            ImageParticle p = particles[vertexID];

            float4 worldPos = float4(p.position, 1.0);
            float4 clipPos  = uniforms.mvpMatrix * worldPos;

            // View-space Z for perspective-correct point sizing
            float4 viewPos = uniforms.viewMatrix * worldPos;
            float viewZ = max(-viewPos.z, 0.001);   // RH: camera looks -Z

            // Color/alpha and base size
            float3 validColor = clamp(p.color / 255.0, 0.0, 1.0);
            float  validOpacity = clamp(p.opacity, 0.0, 1.0);
            
            // Background hiding: smoothly fade based on depth mask (stored in normalizedDepth)
            if (uniforms.bgHide > 0.0) {
                float normalizedDepth = p.normalizedDepth; // 0=white(near), 1=black(far)
                float fadeStart = 1.0 - uniforms.bgHide; // Start fading at this depth
                float fadeEnd = 1.0; // Complete fade at depth 1.0
                float fadeAmount = smoothstep(fadeStart, fadeEnd, normalizedDepth);
                validOpacity = validOpacity * (1.0 - fadeAmount);
            }
            
            // Dissolve: random particle hiding based on position hash
            if (uniforms.dissolve > 0.0) {
                // Create pseudo-random value from particle position
                float hash = fract(sin(dot(p.originalPosition.xy, float2(12.9898, 78.233))) * 43758.5453);
                if (hash < uniforms.dissolve) {
                    validOpacity = 0.0;
                }
            }
            float  validSize = clamp(p.size, 0.0, 1.0);

            float baseSize = 8.0 + (validSize * 32.0);
            if (p.category < 0.5)      baseSize *= 0.7;
            else if (p.category < 1.5) baseSize *= 1.0;
            else if (p.category < 2.5) baseSize *= 1.3;
            else                       baseSize *= 1.6;

            // Tune the 140.0 constant to taste (sprite size vs distance)
            float finalSize = clamp(baseSize * (140.0 / viewZ) * uniforms.sizeMultiplier, 1.0, 200.0);

            // Basic NaN/Inf guard
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
            return out;
        }

        // ===============
        // Fragment (disc)
        // ===============
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

        // ==========================
        // Physics (compute) — unified
        // ==========================
        kernel void unified_physics(device ImageParticle* particles [[buffer(0)]],
                                    constant Uniforms& uniforms     [[buffer(1)]],
                                    uint id [[thread_position_in_grid]]) {
            device ImageParticle& particle = particles[id];

            // === Apply depth scaling FIRST ===
            float3 hologramPos = particle.originalPosition;
            
            // Depth spread: 0=flat plane, 1=50 unit spread, 2=100 unit spread
            float originalZ = particle.originalPosition.z;
            float frontZ = 20.0;
            float backZ = 80.0;
            
            // Calculate how far back this particle should be (0=front, 1=back)
            float normalizedDepth = (originalZ - frontZ) / (backZ - frontZ);
            normalizedDepth = clamp(normalizedDepth, 0.0, 1.0);
            
            // Apply depth scaling: front stays put, back moves away from camera (higher Z)
            float depthOffset = normalizedDepth * uniforms.depthScale * 50.0;
            hologramPos.z = originalZ - depthOffset;

            // Rigid Y rotation around a near-center (AFTER depth scaling)
            float3 orbitalCenter = float3(0.0, 0.0, 50.0);
            float tempX = hologramPos.x - orbitalCenter.x;
            float tempZ = hologramPos.z - orbitalCenter.z;

            float cos_y = cos(uniforms.rotation);
            float sin_y = sin(uniforms.rotation);
            float rotX = tempX * cos_y - tempZ * sin_y;
            float rotZ = tempX * sin_y + tempZ * cos_y;

            hologramPos.x = rotX + orbitalCenter.x;
            hologramPos.z = rotZ + orbitalCenter.z;

            // Wobble effect: random movement around position
            if (uniforms.wobble > 0.0) {
                // Create truly different random seeds for each axis with better distribution
                float hash1 = fract(sin(dot(particle.originalPosition.xy, float2(12.9898, 78.233))) * 43758.5453);
                float hash2 = fract(sin(dot(particle.originalPosition.yz, float2(127.1, 311.7))) * 23421.631);
                float hash3 = fract(sin(dot(particle.originalPosition.zx, float2(269.5, 183.3))) * 85734.293);

                // Additional hash variations to break up patterns completely
                float hashX = fract(sin(particle.originalPosition.x * 91.3458 + particle.originalPosition.y * 47.2891) * 47623.2317);
                float hashY = fract(sin(particle.originalPosition.y * 157.239 + particle.originalPosition.z * 83.7234) * 68329.471);
                float hashZ = fract(sin(particle.originalPosition.z * 203.847 + particle.originalPosition.x * 71.5392) * 31891.652);

                // Time-based wobble with very different frequencies and phase offsets per axis
                float time1 = uniforms.time * (0.8 + hashX * 0.6) + hash1 * 6.28;
                float time2 = uniforms.time * (1.2 + hashY * 0.8) + hash2 * 6.28;
                float time3 = uniforms.time * (0.9 + hashZ * 0.7) + hash3 * 6.28;

                // Apply wobble with independent frequencies and amplitudes for each axis
                float wobbleAmount = uniforms.wobble * 8.0; // Slightly reduced for smoother motion
                hologramPos.x += sin(time1 * 1.7 + hashX * 3.14) * wobbleAmount * hashX;
                hologramPos.y += sin(time2 * 2.1 + hashY * 3.14) * wobbleAmount * hashY;
                hologramPos.z += sin(time3 * 1.4 + hashZ * 3.14) * wobbleAmount * hashZ;
            }

            // Store normalized depth in normalizedDepth for background hiding in vertex shader
            particle.normalizedDepth = normalizedDepth;

            // Final position this frame
            particle.position = hologramPos;

            // Simple stream reset if ever too near camera (rare with real camera)
            if (particle.position.z < -150.0) {
                particle.position = hologramPos;
                particle.position.z = hologramPos.z + 100.0;
                particle.velocity = float3(0.0);
            }
        }
        """

        let library = try! device.makeLibrary(source: shaderSource, options: nil)
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

        renderPipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let computeFunction = library.makeFunction(name: "unified_physics")!
        physicsComputePipelineState = try! device.makeComputePipelineState(function: computeFunction)

        print("✅ Metal shaders compiled successfully")
    }

    // MARK: - Data load

    func loadParticlesFromImages() {
        print("📷 Loading particles from images...")

        guard let originalImage = NSImage(contentsOfFile: "/Users/kiloverse/splat/edkilo.png"),
              let depthImage = NSImage(contentsOfFile: "/Users/kiloverse/splat/edkilo_mask.png"),
              let originalBitmap = NSBitmapImageRep(data: originalImage.tiffRepresentation ?? Data()),
              let depthBitmap = NSBitmapImageRep(data: depthImage.tiffRepresentation ?? Data()) else {
            print("❌ Failed to load images/bitmaps")
            return
        }

        let width = originalBitmap.pixelsWide
        let height = originalBitmap.pixelsHigh
        imageDimensions = SIMD2<Float>(Float(width), Float(height))
        print("📷 Image dimensions: \(width)×\(height)")

        let targetParticles = 30_000
        let availablePixels = width * height
        let baseSampleRate = max(1, Int((Float(availablePixels) / Float(targetParticles)).squareRoot()))
        print("📐 Using sample rate: \(baseSampleRate)")
        print("🔍 Starting particle processing...")

        var tempParticles: [ImageParticle] = []
        var processedCount = 0

        for y in stride(from: 0, to: height, by: baseSampleRate) {
            for x in stride(from: 0, to: width, by: baseSampleRate) {
                guard let originalData = originalBitmap.bitmapData,
                      let depthData = depthBitmap.bitmapData else { continue }

                let bytesPerPixel = originalBitmap.bitsPerPixel / 8
                let offset = y * originalBitmap.bytesPerRow + x * bytesPerPixel
                let r = Float(originalData[offset + 0]) / 255.0
                let g = Float(originalData[offset + 1]) / 255.0
                let b = Float(originalData[offset + 2]) / 255.0

                let depthOffset = y * depthBitmap.bytesPerRow + x * (depthBitmap.bitsPerPixel / 8)
                let depthValue = Float(depthData[depthOffset]) / 255.0

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

                tempParticles.append(
                    ImageParticle(
                        position: SIMD3<Float>(posX, posY, posZ),
                        originalPosition: SIMD3<Float>(posX, posY, posZ),
                        color: SIMD3<Float>(r * 255, g * 255, b * 255),
                        size: 0.5 + depthValue * 2.0,
                        opacity: 1.0,
                        category: category,
                        normalizedDepth: 0.0,
                        velocity: .zero,
                        pixelCoord: SIMD2<Float>(Float(x), Float(y))
                    )
                )

                processedCount += 1
                if processedCount % 5000 == 0 {
                    print("📊 Processed \(processedCount) particles...")
                }
            }
        }

        // Center point (avg)
        var sum = SIMD3<Float>(0,0,0)
        for p in tempParticles { sum += p.position }
        centerPoint = sum / Float(max(tempParticles.count, 1))

        // Sort back-to-front (optional with depth test; harmless here)
        tempParticles.sort { $0.position.z > $1.position.z }

        particles = tempParticles
        particleCount = particles.count
        print("✅ Created \(particleCount) particles")

        // GPU buffers
        let bufferSize = MemoryLayout<ImageParticle>.stride * particleCount
        particleBuffer = device.makeBuffer(bytes: particles, length: bufferSize, options: [])

        // FIX: allocate uniform buffer with the *actual* size of Uniforms
        uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: [])

        // Compute dispatch sizing
        numThreadgroups = MTLSize(width: (particleCount + threadsPerGroup.width - 1) / threadsPerGroup.width,
                                  height: 1,
                                  depth: 1)
        print("✅ Buffers ready")
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let uniformBuffer = uniformBuffer else { return }

        time += 1.0 / 60.0
        rotation += rotSpeed * 0.01
        if rotation > 2 * .pi { rotation -= 2 * .pi }

        // Proper camera matrices with zoom applied to camera position
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let proj = perspectiveRH(fovyRadians: 45.0 * .pi / 180.0, aspect: aspect, near: 0.1, far: 2000.0)
        
        // Traditional camera zoom: move camera closer/further from subject
        let zoomedCameraEye = SIMD3<Float>(cameraEye.x, cameraEye.y, cameraEye.z / zoom)
        let viewM = lookAtRH(eye: zoomedCameraEye, center: cameraCenter, up: cameraUp)
        let mvp = proj * viewM   // model is identity; rotation happens in compute

        // Write uniforms
        var uniforms = Uniforms(
            mvpMatrix: mvp,
            viewMatrix: viewM,
            rotation: rotation,
            time: time,
            sizeMultiplier: sizeMultiplier,
            zoom: zoom,
            depthScale: depthScale,
            bgHide: bgHide,
            dissolve: dissolve,
            wobble: wobble,
            centerPoint: centerPoint,
            imageDimensions: imageDimensions,
            aspectRatio: aspect,
            _pad0: .zero,
            _pad1: 0
        )
        uniformBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.size)

        let commandBuffer = commandQueue.makeCommandBuffer()!

        // Compute (always run for rotation/physics)
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            computeEncoder.setComputePipelineState(physicsComputePipelineState)
            computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 1)
            computeEncoder.dispatchThreadgroups(numThreadgroups, threadsPerThreadgroup: threadsPerGroup)
            computeEncoder.endEncoding()
        }

        // Render
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

// MARK: - App bootstrap (Cocoa)

print("🌐 IMAGE-SAMPLED HOLOGRAM (Camera-corrected)")

var app: NSApplication!
var delegate: ImageHologramDelegate!
var window: NSWindow!
var metalView: MTKView!
var renderer: ImageSampledHologramRenderer!

class ImageHologramDelegate: NSObject, NSApplicationDelegate {
    var rotLabel: NSTextField!
    var sizeLabel: NSTextField!
    var zoomLabel: NSTextField!
    var depthLabel: NSTextField!
    var bgHideLabel: NSTextField!
    var dissolveLabel: NSTextField!
    var wobbleLabel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("❌ Metal not supported")
            NSApp.terminate(nil)
            return
        }

        renderer = ImageSampledHologramRenderer(device: device)
        guard renderer != nil else {
            print("❌ Failed to create renderer")
            NSApp.terminate(nil)
            return
        }

        metalView = InteractiveMetalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.preferredFramesPerSecond = 60
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.delegate = renderer
        (metalView as! InteractiveMetalView).renderer = renderer

        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "🌐 Image-Sampled Hologram (Camera-corrected)"
        window.contentView = metalView
        window.makeKeyAndOrderFront(nil)

        setupControls()
        print("✅ READY")
    }

    func setupControls() {
        let windowHeight = window.frame.height
        let controlsView = NSView(frame: NSRect(x: 20, y: windowHeight - 300, width: 150, height: 280))
        controlsView.wantsLayer = true
        controlsView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor

        // Rotation Speed
        let rotSpeedSlider = NSSlider(value: Double(renderer.rotSpeed), minValue: 0, maxValue: 3, target: self, action: #selector(rotSpeedChanged(_:)))
        rotSpeedSlider.frame = NSRect(x: 10, y: 200, width: 120, height: 20)
        controlsView.addSubview(rotSpeedSlider)

        rotLabel = NSTextField(labelWithString: String(format: "Rot Speed: %.1fx", renderer.rotSpeed))
        rotLabel.frame = NSRect(x: 10, y: 220, width: 120, height: 15)
        rotLabel.font = NSFont.systemFont(ofSize: 11)
        rotLabel.textColor = .white
        controlsView.addSubview(rotLabel)

        // Size
        let sizeSlider = NSSlider(value: Double(renderer.sizeMultiplier), minValue: 0, maxValue: 2, target: self, action: #selector(sizeChanged(_:)))
        sizeSlider.frame = NSRect(x: 10, y: 170, width: 120, height: 20)
        controlsView.addSubview(sizeSlider)

        sizeLabel = NSTextField(labelWithString: String(format: "Size: %.1fx", renderer.sizeMultiplier))
        sizeLabel.frame = NSRect(x: 10, y: 190, width: 120, height: 15)
        sizeLabel.font = NSFont.systemFont(ofSize: 11)
        sizeLabel.textColor = .white
        controlsView.addSubview(sizeLabel)

        // Zoom
        let zoomSlider = NSSlider(value: Double(renderer.zoom), minValue: 0.1, maxValue: 2.0, target: self, action: #selector(zoomChanged(_:)))
        zoomSlider.frame = NSRect(x: 10, y: 140, width: 120, height: 20)
        controlsView.addSubview(zoomSlider)

        zoomLabel = NSTextField(labelWithString: String(format: "Zoom: %.1fx", renderer.zoom))
        zoomLabel.frame = NSRect(x: 10, y: 160, width: 120, height: 15)
        zoomLabel.font = NSFont.systemFont(ofSize: 11)
        zoomLabel.textColor = .white
        controlsView.addSubview(zoomLabel)

        // Depth
        let depthSlider = NSSlider(value: Double(renderer.depthScale), minValue: -5, maxValue: 5, target: self, action: #selector(depthChanged(_:)))
        depthSlider.frame = NSRect(x: 10, y: 110, width: 120, height: 20)
        controlsView.addSubview(depthSlider)

        depthLabel = NSTextField(labelWithString: String(format: "Depth: %.1fx", renderer.depthScale))
        depthLabel.frame = NSRect(x: 10, y: 130, width: 120, height: 15)
        depthLabel.font = NSFont.systemFont(ofSize: 11)
        depthLabel.textColor = .white
        controlsView.addSubview(depthLabel)

        // Background Hide
        let bgHideSlider = NSSlider(value: Double(renderer.bgHide), minValue: 0, maxValue: 1.0, target: self, action: #selector(bgHideChanged(_:)))
        bgHideSlider.frame = NSRect(x: 10, y: 80, width: 120, height: 20)
        controlsView.addSubview(bgHideSlider)

        bgHideLabel = NSTextField(labelWithString: String(format: "BG Hide: %.2f", renderer.bgHide))
        bgHideLabel.frame = NSRect(x: 10, y: 100, width: 120, height: 15)
        bgHideLabel.font = NSFont.systemFont(ofSize: 11)
        bgHideLabel.textColor = .white
        controlsView.addSubview(bgHideLabel)

        // Dissolve
        let dissolveSlider = NSSlider(value: Double(renderer.dissolve), minValue: 0, maxValue: 1.0, target: self, action: #selector(dissolveChanged(_:)))
        dissolveSlider.frame = NSRect(x: 10, y: 50, width: 120, height: 20)
        controlsView.addSubview(dissolveSlider)

        dissolveLabel = NSTextField(labelWithString: String(format: "Dissolve: %.2f", renderer.dissolve))
        dissolveLabel.frame = NSRect(x: 10, y: 70, width: 120, height: 15)
        dissolveLabel.font = NSFont.systemFont(ofSize: 11)
        dissolveLabel.textColor = .white
        controlsView.addSubview(dissolveLabel)

        // Wobble
        let wobbleSlider = NSSlider(value: Double(renderer.wobble), minValue: 0, maxValue: 1.0, target: self, action: #selector(wobbleChanged(_:)))
        wobbleSlider.frame = NSRect(x: 10, y: 20, width: 120, height: 20)
        controlsView.addSubview(wobbleSlider)

        wobbleLabel = NSTextField(labelWithString: String(format: "Wobble: %.2f", renderer.wobble))
        wobbleLabel.frame = NSRect(x: 10, y: 40, width: 120, height: 15)
        wobbleLabel.font = NSFont.systemFont(ofSize: 11)
        wobbleLabel.textColor = .white
        controlsView.addSubview(wobbleLabel)

        (window.contentView as? MTKView)?.addSubview(controlsView)
    }

    @objc func rotSpeedChanged(_ sender: NSSlider) {
        renderer.rotSpeed = Float(sender.doubleValue)
        rotLabel?.stringValue = String(format: "Rot Speed: %.1fx", renderer.rotSpeed)
        print("🔄 Rot Speed: \(renderer.rotSpeed)")
    }

    @objc func sizeChanged(_ sender: NSSlider) {
        renderer.sizeMultiplier = Float(sender.doubleValue)
        sizeLabel?.stringValue = String(format: "Size: %.1fx", renderer.sizeMultiplier)
        print("🔧 Size: \(renderer.sizeMultiplier)")
    }

    @objc func zoomChanged(_ sender: NSSlider) {
        renderer.zoom = Float(sender.doubleValue)
        zoomLabel?.stringValue = String(format: "Zoom: %.1fx", renderer.zoom)
        print("🔍 Zoom: \(renderer.zoom)")
    }

    @objc func depthChanged(_ sender: NSSlider) {
        renderer.depthScale = Float(sender.doubleValue)
        depthLabel?.stringValue = String(format: "Depth: %.1fx", renderer.depthScale)
        print("📏 Depth: \(renderer.depthScale)")
    }

    @objc func bgHideChanged(_ sender: NSSlider) {
        renderer.bgHide = Float(sender.doubleValue)
        bgHideLabel?.stringValue = String(format: "BG Hide: %.2f", renderer.bgHide)
        print("🙈 BG Hide: \(renderer.bgHide)")
    }

    @objc func dissolveChanged(_ sender: NSSlider) {
        renderer.dissolve = Float(sender.doubleValue)
        dissolveLabel?.stringValue = String(format: "Dissolve: %.2f", renderer.dissolve)
        print("💫 Dissolve: \(renderer.dissolve)")
    }

    @objc func wobbleChanged(_ sender: NSSlider) {
        renderer.wobble = Float(sender.doubleValue)
        wobbleLabel?.stringValue = String(format: "Wobble: %.2f", renderer.wobble)
        print("🌀 Wobble: \(renderer.wobble)")
    }
}

app = NSApplication.shared
delegate = ImageHologramDelegate()
app.delegate = delegate
app.run()