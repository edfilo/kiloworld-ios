//
//  MetalRenderingViews.swift
//  kiloworld
//
//  Created by Claude on 9/22/25.
//

import SwiftUI
import Metal
import MetalKit

struct FullscreenMetalView: UIViewRepresentable {
    let imageUrls: [String]
    let depthAmount: Float
    let globalSize: Float
    let metalSynth: MetalWavetableSynth?
    
    func makeUIView(context: Context) -> PolyphonicMTKView {
        print("🔧 Creating PolyphonicMTKView...")
        let mtkView = PolyphonicMTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = false  // Enable continuous drawing for particle animation
        mtkView.preferredFramesPerSecond = 60
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0) // Transparent background
        mtkView.isOpaque = false // CRITICAL: Allow transparency
        mtkView.backgroundColor = UIColor.clear // Clear background
        // Enable depth buffer for proper depth testing
        mtkView.depthStencilPixelFormat = .depth32Float
        // Enable user interaction for gestures
        mtkView.isUserInteractionEnabled = true
        mtkView.isMultipleTouchEnabled = true  // Enable multi-touch
        
        // CRITICAL: Allow touches to pass through to views behind
        mtkView.backgroundColor = UIColor.clear
        mtkView.layer.backgroundColor = UIColor.clear.cgColor
        
        print("✅ PolyphonicMTKView created with multi-touch: \(mtkView.isMultipleTouchEnabled)")
        
        mtkView.coordinator = context.coordinator
        context.coordinator.setMTKView(mtkView)
        context.coordinator.setMetalSynth(metalSynth)
        return mtkView
    }
    
    func updateUIView(_ uiView: PolyphonicMTKView, context: Context) {
        // Update parameters - debounce to prevent GPU choking
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            context.coordinator.setDepthAmount(depthAmount)
            context.coordinator.setGlobalSize(globalSize)
        }
        
        // Load the most recent image
        print("FullscreenMetalView: updateUIView called with \(imageUrls.count) images")
        if let latestImageUrl = imageUrls.last {
            print("FullscreenMetalView: Loading latest image: \(latestImageUrl)")
            context.coordinator.loadImage(from: latestImageUrl)
        } else {
            print("FullscreenMetalView: No images to display")
        }
    }
    
    func makeCoordinator() -> FullscreenCoordinator {
        FullscreenCoordinator()
    }
    
    class FullscreenCoordinator: NSObject, MTKViewDelegate {
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var texture: MTLTexture?
        private var maskTexture: MTLTexture?
        private weak var mtkView: MTKView?
        private var particleSystem: ParticleDissolveSystem?
        private var displayTimer: Timer?
        private weak var metalSynth: MetalWavetableSynth?
        
        // Celestial musical scales
        private let celestialScales = [
            [0, 2, 4, 7, 9],           // Pentatonic major (ethereal)
            [0, 3, 5, 7, 10],          // Pentatonic minor (mysterious)  
            [0, 2, 3, 5, 7, 8, 10],    // Natural minor (melancholic)
            [0, 2, 4, 6, 7, 9, 11],    // Lydian (dreamy, floating)
            [0, 1, 4, 5, 7, 8, 11],    // Harmonic minor (exotic)
            [0, 2, 4, 5, 7, 9, 10],    // Mixolydian (warm, celestial)
            [0, 1, 3, 4, 6, 8, 10]     // Whole tone (spacey, ethereal)
        ]
        private var currentScaleIndex = 0
        private var baseOctave = 4
        private var activeTouches: [UITouch: Int] = [:] // Maps each touch to its MIDI note
        private var currentTouchNote: Int? = nil // For single-touch compatibility
        
        // Gesture state  
        private var currentZoomScale: Float = 2.0  // Start at 2x to make gestures more obvious
        private var currentRotationX: Float = 0.0  // Vertical drag rotation (front-facing)
        private var currentRotationY: Float = 0.0  // Horizontal drag rotation (front-facing)
        
        override init() {
            super.init()
            setupMetal()
        }
        
        func setMTKView(_ view: MTKView) {
            mtkView = view
            setupGestures()
            
            // Load hardcoded image for testing
            loadHardcodedImage()
        }
        
        func setDepthAmount(_ amount: Float) {
            particleSystem?.setDepthAmount(amount)
        }
        
        func setGlobalSize(_ size: Float) {
            particleSystem?.setGlobalSize(size)
        }
        
        func setMetalSynth(_ synth: MetalWavetableSynth?) {
            metalSynth = synth
        }
        
        func loadImage(from urlString: String) {
            // Simplified image loading - just print for now
            print("FullscreenCoordinator: Loading image from \(urlString)")
        }
        
        private func setupMetal() {
            device = MTLCreateSystemDefaultDevice()
            commandQueue = device?.makeCommandQueue()
            
            guard let device = device else {
                print("Failed to create Metal device")
                return
            }
            
            particleSystem = ParticleDissolveSystem(device: device)
        }
        
        private func setupGestures() {
            guard let view = mtkView else { return }
            
            // Add gesture recognizers for zoom and rotation
            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            
            pinchGesture.delegate = self
            panGesture.delegate = self
            
            view.addGestureRecognizer(pinchGesture)
            view.addGestureRecognizer(panGesture)
        }
        
        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .changed {
                currentZoomScale *= Float(gesture.scale)
                currentZoomScale = max(0.5, min(5.0, currentZoomScale))
                gesture.scale = 1.0
            }
        }
        
        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .changed {
                let translation = gesture.translation(in: gesture.view)
                currentRotationY += Float(translation.x) * 0.01
                currentRotationX += Float(translation.y) * 0.01
                gesture.setTranslation(.zero, in: gesture.view)
            }
        }
        
        private func loadHardcodedImage() {
            // Load a default test image if needed
            print("Loading hardcoded image for testing")
        }
        
        // Simplified touch handling methods for polyphonic synthesis
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
        
        func handleTouchesMoved(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) {
            // Could update note parameters here
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
        
        // MTKViewDelegate methods
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle size changes
        }
        
        func draw(in view: MTKView) {
            guard let commandQueue = commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else {
                return
            }
            
            // Simple clear for now
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            
            if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                renderEncoder.endEncoding()
            }
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

struct MetalImageView: UIViewRepresentable {
    let imageUrl: String
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
        context.coordinator.setMTKView(mtkView)
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.loadImage(from: imageUrl)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var texture: MTLTexture?
        private var maskTexture: MTLTexture?
        private weak var mtkView: MTKView?
        
        override init() {
            super.init()
            setupMetal()
        }
        
        func setMTKView(_ view: MTKView) {
            mtkView = view
        }
        
        private func setupMetal() {
            device = MTLCreateSystemDefaultDevice()
            commandQueue = device?.makeCommandQueue()
            
            let library = device?.makeDefaultLibrary()
            let vertexFunction = library?.makeFunction(name: "vertex_main")
            let fragmentFunction = library?.makeFunction(name: "fragment_main")
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            // Enable alpha blending for transparency
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            
            do {
                pipelineState = try device?.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
                print("Error creating pipeline state: \(error)")
            }
        }
        
        func loadImage(from urlString: String) {
            // Fix URL if it's missing protocol
            var fixedUrlString = urlString
            if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
                fixedUrlString = "https://" + urlString
            }
            
            guard let url = URL(string: fixedUrlString) else { 
                print("Invalid image URL: \(urlString) -> \(fixedUrlString)")
                return 
            }
            
            print("Loading image from: \(urlString) -> \(fixedUrlString)")
            
            // Load main image
            loadImageTexture(from: url, isMain: true)
            
            // Generate and load mask URL
            let maskUrl = generateMaskUrl(from: fixedUrlString)
            if let maskUrl = maskUrl {
                loadImageTexture(from: maskUrl, isMain: false)
            }
        }
        
        private func generateMaskUrl(from urlString: String) -> URL? {
            guard let url = URL(string: urlString) else { return nil }
            
            let pathExtension = url.pathExtension
            let pathWithoutExtension = url.deletingPathExtension().absoluteString
            let maskUrlString = "\(pathWithoutExtension)_mask.\(pathExtension)"
            
            print("Generated mask URL: \(maskUrlString)")
            return URL(string: maskUrlString)
        }
        
        private func loadImageTexture(from url: URL, isMain: Bool) {
            print("Loading \(isMain ? "main" : "mask") texture from: \(url)")
            
            URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                guard let self = self,
                      let data = data,
                      error == nil,
                      let image = UIImage(data: data),
                      let cgImage = image.cgImage else {
                    print("Failed to load image from \(url): \(error?.localizedDescription ?? "unknown error")")
                    return
                }
                
                DispatchQueue.main.async {
                    if isMain {
                        self.texture = self.createTexture(from: cgImage)
                    } else {
                        self.maskTexture = self.createTexture(from: cgImage)
                    }
                    self.mtkView?.setNeedsDisplay()
                }
            }.resume()
        }
        
        private func createTexture(from cgImage: CGImage) -> MTLTexture? {
            guard let device = device else { return nil }
            
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: cgImage.width,
                height: cgImage.height,
                mipmapped: false
            )
            textureDescriptor.usage = [.shaderRead]
            
            guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
            
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let context = CGContext(
                data: nil,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            
            if let data = context?.data {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, cgImage.width, cgImage.height),
                    mipmapLevel: 0,
                    withBytes: data,
                    bytesPerRow: cgImage.width * 4
                )
            }
            
            return texture
        }
        
        // MTKViewDelegate methods
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle size changes
        }
        
        func draw(in view: MTKView) {
            guard let commandQueue = commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else {
                return
            }
            
            // Simple clear for now - could render the loaded texture here
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            
            if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                // Could add texture rendering here
                renderEncoder.endEncoding()
            }
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}