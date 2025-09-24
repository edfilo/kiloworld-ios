import Metal
import MetalKit
import simd

struct ParticleParams {
    var time: Float = 0.0
    var dt: Float = 1.0/60.0
    var release: Float = 0.0
    var softness: Float = 0.03
    var pop: Float = 25.0         // Much stronger initial impulse for dramatic spread
    var drift: Float = 8.0        // Much stronger turbulence for wispy flows
    var drag: Float = 0.3         // Much less drag for longer flowing trails
    var flowScale: Float = 0.8    // Larger scale turbulence for organic flows
    var windY: Float = 35.0       // Stronger upward wind for rising effect
    var gravityY: Float = -5.0    // Very weak gravity to allow floating
    var life: Float = 2.2
    var fogDensity: Float = 0.035
    var fogColor: SIMD3<Float> = SIMD3<Float>(0.5, 0.6, 0.7)
    var softSize: Float = 3.0
    var sharpSize: Float = 1.1
    var sharpMix: Float = 0.35
    var mbStretch: Float = 0.006
    var dither: Float = 0.01
    var edgeBias: Float = 0.12
    var seed: UInt32 = 1
    var nearFirst: Bool = true
    var twoPass: Bool = true
    var wipeDuration: Float = 3.0
    var depthAmount: Float = 1.0  // Controls Z depth from depth texture
    var globalSize: Float = 1.0   // Global size multiplier for all particles
    var userScale: Float = 1.0    // User zoom level
    var userRotationY: Float = 0.0 // User Y rotation (horizontal drag)
    var userRotationX: Float = 0.0 // User X rotation (vertical drag)
}

class ParticleDissolveSystem {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    
    // Compute pipeline
    private var computePipelineState: MTLComputePipelineState?
    
    // Render pipeline  
    private var renderPipelineState: MTLRenderPipelineState?
    private var depthStencilState: MTLDepthStencilState?
    
    // Textures (ping-pong)
    private var posTextureA: MTLTexture?
    private var posTextureB: MTLTexture?
    private var velTextureA: MTLTexture?
    private var velTextureB: MTLTexture?
    private var blueNoiseTexture: MTLTexture?
    
    // Source textures
    private var photoTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    
    // Uniforms
    private var paramsBuffer: MTLBuffer?
    private var mvpBuffer: MTLBuffer?
    
    // State
    private var params = ParticleParams()
    private var startTime: Double = 0
    private var isActive = false
    private var useBufferA = true
    private var cycleStartTime: Double = 0
    private var isLooping = false
    
    // Grid size (300x300 as per spec)
    let gridSize = 300
    
    init?(device: MTLDevice) {
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }
        
        self.commandQueue = commandQueue
        self.library = library
        
        setupPipelines()
        setupResources()
    }
    
    private func setupPipelines() {
        // Compute pipeline
        guard let computeFunction = library.makeFunction(name: "updateParticles") else {
            // Failed to create compute function
            return
        }
        
        do {
            computePipelineState = try device.makeComputePipelineState(function: computeFunction)
            // Compute pipeline created
        } catch {
            // Failed to create compute pipeline
        }
        
        // Render pipeline - back to original particle shaders
        guard let vertexFunction = library.makeFunction(name: "particleVertex"),
              let fragmentFunction = library.makeFunction(name: "particleFragment") else {
            // Failed to create render functions
            return
        }
        
        let renderDescriptor = MTLRenderPipelineDescriptor()
        renderDescriptor.vertexFunction = vertexFunction
        renderDescriptor.fragmentFunction = fragmentFunction
        renderDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // Enable additive blending for glowing star particles
        let colorAttachment = renderDescriptor.colorAttachments[0]!
        colorAttachment.isBlendingEnabled = true
        colorAttachment.sourceRGBBlendFactor = .one
        colorAttachment.destinationRGBBlendFactor = .one
        colorAttachment.sourceAlphaBlendFactor = .one
        colorAttachment.destinationAlphaBlendFactor = .one
        
        // Enable depth testing for proper particle layering
        renderDescriptor.depthAttachmentPixelFormat = .depth32Float
        
        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: renderDescriptor)
            // Render pipeline created
        } catch {
            // Failed to create render pipeline
        }
        
        // Create depth stencil state for semi-transparent particles
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less // Standard depth test (closer = smaller Z)
        depthDescriptor.isDepthWriteEnabled = false // DON'T write to depth buffer for transparency
        depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)
    }
    
    private func setupResources() {
        // Create ping-pong textures for particle state
        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: gridSize,
            height: gridSize,
            mipmapped: false
        )
        textureDesc.usage = [.shaderRead, .shaderWrite]
        
        posTextureA = device.makeTexture(descriptor: textureDesc)
        posTextureB = device.makeTexture(descriptor: textureDesc)
        velTextureA = device.makeTexture(descriptor: textureDesc)
        velTextureB = device.makeTexture(descriptor: textureDesc)
        
        // Create blue noise texture (simplified - would load from file in production)
        createBlueNoiseTexture()
        
        // Create uniform buffers
        paramsBuffer = device.makeBuffer(length: MemoryLayout<ParticleParams>.stride, options: [])
        mvpBuffer = device.makeBuffer(length: MemoryLayout<float4x4>.stride, options: [])
        
        // Initialize particle positions to grid
        initializeParticles()
    }
    
    private func createBlueNoiseTexture() {
        let size = 256
        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        
        guard let texture = device.makeTexture(descriptor: textureDesc) else { return }
        
        // Generate simple random noise (would use proper blue noise in production)
        var noiseData = [UInt8](repeating: 0, count: size * size)
        for i in 0..<noiseData.count {
            noiseData[i] = UInt8.random(in: 0...255)
        }
        
        texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                       mipmapLevel: 0,
                       withBytes: noiseData,
                       bytesPerRow: size)
        
        blueNoiseTexture = texture
    }
    
    private func initializeParticles() {
        guard let posA = posTextureA, let velA = velTextureA else { return }
        
        // Initialize all particles to base positions with zero age/velocity
        var posData = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: gridSize * gridSize)
        var velData = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: gridSize * gridSize)
        
        // Simple initialization - shader will read depth directly
        for y in 0..<gridSize {
            for x in 0..<gridSize {
                let index = y * gridSize + x
                let uv = SIMD2<Float>(Float(x) / Float(gridSize), Float(y) / Float(gridSize))
                
                // Map UV to centered plane coordinates
                let pos = SIMD3<Float>(uv.x - 0.5, 0.5 - uv.y, 0.0)
                posData[index] = SIMD4<Float>(pos, 0.0) // age = 0
                velData[index] = SIMD4<Float>(0, 0, 0, 0) // vel + released = false
            }
        }
        
        // Upload to textures
        posA.replace(region: MTLRegionMake2D(0, 0, gridSize, gridSize),
                    mipmapLevel: 0,
                    withBytes: posData,
                    bytesPerRow: gridSize * MemoryLayout<SIMD4<Float>>.stride)
        
        velA.replace(region: MTLRegionMake2D(0, 0, gridSize, gridSize),
                    mipmapLevel: 0,
                    withBytes: velData,
                    bytesPerRow: gridSize * MemoryLayout<SIMD4<Float>>.stride)
    }
    
    func setPhoto(_ texture: MTLTexture, depth: MTLTexture?) {
        photoTexture = texture
        depthTexture = depth
        
        // Reset and start dissolve
        startDissolve()
    }
    
    func startDissolve() {
        cycleStartTime = CACurrentMediaTime()
        startTime = cycleStartTime
        isActive = true
        isLooping = true
        useBufferA = true
        
        // Reset particles
        initializeParticles()
        
        print("Started continuous particle dissolve loop")
        
        // Re-enabled: Particle system confirmed not interfering with audio buffers
        isLooping = true
        isActive = true
        print("✨ ENABLED particle system - confirmed no audio buffer interference")
    }
    
    func stopLoop() {
        isLooping = false
        isActive = false
    }
    
    // Method to control depth amount for testing
    func setDepthAmount(_ amount: Float) {
        params.depthAmount = amount
    }
    
    // Method to control global particle size
    func setGlobalSize(_ size: Float) {
        params.globalSize = size
    }
    
    // Methods to control user interaction
    func setScale(_ scale: Float) {
        params.userScale = scale
    }
    
    func setRotation(_ rotationX: Float, _ rotationY: Float) {
        params.userRotationX = rotationX
        params.userRotationY = rotationY
    }
    
    func update() {
        guard isActive, let computePipeline = computePipelineState else { return }
        
        let currentTime = CACurrentMediaTime()
        let totalElapsed = currentTime - cycleStartTime
        
        // TEMPORARY: Disable dissolve animation - keep particles in formation
        params.time = Float(totalElapsed)
        params.release = 0.0  // Keep particles in formation state
        
        // Update uniforms
        paramsBuffer?.contents().copyMemory(from: &params, byteCount: MemoryLayout<ParticleParams>.stride)
        
        // Create compute command
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
        
        computeEncoder.setComputePipelineState(computePipeline)
        
        // Set textures
        computeEncoder.setTexture(photoTexture, index: 0)
        computeEncoder.setTexture(depthTexture, index: 1)
        computeEncoder.setTexture(blueNoiseTexture, index: 2)
        
        if useBufferA {
            computeEncoder.setTexture(posTextureA, index: 3) // input
            computeEncoder.setTexture(velTextureA, index: 4)
            computeEncoder.setTexture(posTextureB, index: 5) // output
            computeEncoder.setTexture(velTextureB, index: 6)
        } else {
            computeEncoder.setTexture(posTextureB, index: 3) // input
            computeEncoder.setTexture(velTextureB, index: 4)
            computeEncoder.setTexture(posTextureA, index: 5) // output
            computeEncoder.setTexture(velTextureA, index: 6)
        }
        
        computeEncoder.setBuffer(paramsBuffer, offset: 0, index: 0)
        
        // Dispatch compute
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let numGroups = MTLSize(width: (gridSize + 15) / 16, height: (gridSize + 15) / 16, depth: 1)
        
        computeEncoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
        computeEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Flip buffers
        useBufferA.toggle()
    }
    
    func render(to renderEncoder: MTLRenderCommandEncoder, mvpMatrix: float4x4) {
        guard let renderPipeline = renderPipelineState else { 
            // No render pipeline available
            return 
        }
        
        // Starting render
        
        // Update MVP matrix
        var mvp = mvpMatrix
        mvpBuffer?.contents().copyMemory(from: &mvp, byteCount: MemoryLayout<float4x4>.stride)
        
        renderEncoder.setRenderPipelineState(renderPipeline)
        
        // Disable depth testing to show all particles regardless of Z position
        if let depthState = depthStencilState {
            renderEncoder.setDepthStencilState(depthState)
        }
        
        // Set textures (use current read buffer)
        if let photoTexture = photoTexture {
            renderEncoder.setVertexTexture(photoTexture, index: 0)
            // Photo texture set
        } else {
            // No photo texture
        }
        
        if useBufferA {
            renderEncoder.setVertexTexture(posTextureB, index: 1) // Read from write target
            renderEncoder.setVertexTexture(velTextureB, index: 2)
            // Using buffer B
        } else {
            renderEncoder.setVertexTexture(posTextureA, index: 1)
            renderEncoder.setVertexTexture(velTextureA, index: 2)
            // Using buffer A
        }
        
        // Add depth texture for debugging
        if let depthTexture = depthTexture {
            renderEncoder.setVertexTexture(depthTexture, index: 3)
        }
        
        // Set uniforms
        renderEncoder.setVertexBuffer(paramsBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(mvpBuffer, offset: 0, index: 1)
        renderEncoder.setFragmentBuffer(paramsBuffer, offset: 0, index: 0)
        
        // Draw all particles
        let particleCount = gridSize * gridSize
        // Drawing particles
        
        // Position texture ready
        
        // Use instanced triangle strip rendering for quad particles (4 vertices per quad)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: particleCount)
    }
}
