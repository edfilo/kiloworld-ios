//
//  CustomGlobeAnimator.swift
//  kiloworld
//
//  Frame-by-frame globe animation controller for video capture
//

import Foundation
import MapboxMaps
import CoreLocation
import AVFoundation

class CustomGlobeAnimator {
    private weak var mapView: MapView?
    private var displayLink: CADisplayLink?
    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // Animation state
    private var animationProgress: Float = 0.0
    private var totalFrames: Int = 0
    private var currentFrame: Int = 0
    private var isRecording: Bool = false

    // Animation parameters
    struct AnimationKeyframe {
        let center: CLLocationCoordinate2D
        let zoom: Double
        let pitch: Double
        let bearing: Double
        let timestamp: Float // 0.0 to 1.0
    }

    private var keyframes: [AnimationKeyframe] = []

    init(mapView: MapView) {
        self.mapView = mapView
    }

    // MARK: - Video Capture Setup

    func setupVideoCapture(outputURL: URL, duration: TimeInterval, fps: Int = 30) -> Bool {
        guard let mapView = mapView else { return false }

        totalFrames = Int(duration * Double(fps))

        do {
            // Create video writer
            videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

            // Video settings for social media (1080x1920 for Instagram Reels)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1080,
                AVVideoHeightKey: 1920,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 6000000, // 6 Mbps for high quality
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]

            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = false

            // Pixel buffer adaptor
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 1080,
                kCVPixelBufferHeightKey as String: 1920
            ]

            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput!,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )

            guard let videoInput = videoInput,
                  let videoWriter = videoWriter else { return false }

            videoWriter.add(videoInput)

            return true
        } catch {
            print("❌ Failed to setup video capture: \(error)")
            return false
        }
    }

    // MARK: - Animation Keyframes

    func createJourneyAnimation(
        startLocation: CLLocationCoordinate2D,
        journeyPath: [CLLocationCoordinate2D],
        endLocation: CLLocationCoordinate2D
    ) {
        keyframes.removeAll()

        // Phase 1: Zoom out from start location (0.0 - 0.2)
        keyframes.append(AnimationKeyframe(
            center: startLocation,
            zoom: 16.0,
            pitch: 85.0,
            bearing: 0.0,
            timestamp: 0.0
        ))

        keyframes.append(AnimationKeyframe(
            center: startLocation,
            zoom: 2.0,
            pitch: 45.0,
            bearing: 0.0,
            timestamp: 0.15
        ))

        keyframes.append(AnimationKeyframe(
            center: startLocation,
            zoom: 0.5,
            pitch: 0.0,
            bearing: 0.0,
            timestamp: 0.25
        ))

        // Phase 2: Globe rotation showing journey (0.25 - 0.75)
        let journeyCenter = calculateJourneyCenter(journeyPath)
        for i in 0...5 {
            let progress = 0.25 + (0.5 * Float(i) / 5.0)
            let bearing = Double(i) * 72.0 // 360° over 5 keyframes

            keyframes.append(AnimationKeyframe(
                center: journeyCenter,
                zoom: 0.5,
                pitch: 0.0,
                bearing: bearing,
                timestamp: progress
            ))
        }

        // Phase 3: Zoom into end location (0.75 - 1.0)
        keyframes.append(AnimationKeyframe(
            center: endLocation,
            zoom: 2.0,
            pitch: 45.0,
            bearing: 0.0,
            timestamp: 0.85
        ))

        keyframes.append(AnimationKeyframe(
            center: endLocation,
            zoom: 16.0,
            pitch: 85.0,
            bearing: 0.0,
            timestamp: 1.0
        ))

        print("🎬 Created journey animation with \(keyframes.count) keyframes")
    }

    // MARK: - Frame-by-Frame Animation

    func startRecording() {
        guard let videoWriter = videoWriter,
              let videoInput = videoInput else {
            print("❌ Video capture not set up")
            return
        }

        currentFrame = 0
        isRecording = true

        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)

        // Start display link for frame capture
        displayLink = CADisplayLink(target: self, selector: #selector(captureFrame))
        displayLink?.preferredFramesPerSecond = 30
        displayLink?.add(to: .main, forMode: .common)

        print("🎥 Started recording globe animation")
    }

    @objc private func captureFrame() {
        guard isRecording,
              currentFrame < totalFrames,
              let mapView = mapView,
              let videoInput = videoInput,
              let pixelBufferAdaptor = pixelBufferAdaptor else {
            return
        }

        // Calculate animation progress (0.0 to 1.0)
        animationProgress = Float(currentFrame) / Float(totalFrames)

        // Interpolate camera position from keyframes
        let cameraState = interpolateCameraState(at: animationProgress)

        // Update map camera
        let cameraOptions = CameraOptions(
            center: cameraState.center,
            zoom: cameraState.zoom,
            bearing: cameraState.bearing,
            pitch: cameraState.pitch
        )

        mapView.camera.ease(to: cameraOptions, duration: 0.0) { [weak self] _ in
            // Capture frame after camera update
            self?.captureMapFrame()
        }
    }

    private func captureMapFrame() {
        guard let mapView = mapView,
              let pixelBufferAdaptor = pixelBufferAdaptor,
              pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData else {
            return
        }

        // Create pixel buffer from map view
        let renderer = UIGraphicsImageRenderer(bounds: mapView.bounds)
        let image = renderer.image { context in
            mapView.layer.render(in: context.cgContext)
        }

        // Convert to pixel buffer
        if let pixelBuffer = createPixelBuffer(from: image) {
            let frameTime = CMTime(value: Int64(currentFrame), timescale: 30)
            pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: frameTime)
        }

        currentFrame += 1

        // Check if recording is complete
        if currentFrame >= totalFrames {
            finishRecording()
        }

        print("🎬 Captured frame \(currentFrame)/\(totalFrames) - progress: \(Int(animationProgress * 100))%")
    }

    private func finishRecording() {
        displayLink?.invalidate()
        displayLink = nil
        isRecording = false

        guard let videoInput = videoInput,
              let videoWriter = videoWriter else { return }

        videoInput.markAsFinished()

        videoWriter.finishWriting { [weak self] in
            DispatchQueue.main.async {
                if videoWriter.status == .completed {
                    print("✅ Globe animation video saved successfully!")
                    self?.onVideoCompleted?(videoWriter.outputURL)
                } else {
                    print("❌ Video recording failed: \(videoWriter.error?.localizedDescription ?? "Unknown error")")
                }
            }
        }
    }

    // MARK: - Utility Functions

    private func interpolateCameraState(at progress: Float) -> (center: CLLocationCoordinate2D, zoom: Double, pitch: Double, bearing: Double) {
        // Find surrounding keyframes
        var beforeKeyframe: AnimationKeyframe?
        var afterKeyframe: AnimationKeyframe?

        for i in 0..<keyframes.count {
            let keyframe = keyframes[i]
            if keyframe.timestamp <= progress {
                beforeKeyframe = keyframe
            }
            if keyframe.timestamp >= progress && afterKeyframe == nil {
                afterKeyframe = keyframe
                break
            }
        }

        guard let before = beforeKeyframe,
              let after = afterKeyframe else {
            // Use first or last keyframe if out of bounds
            let keyframe = progress <= 0.0 ? keyframes.first! : keyframes.last!
            return (keyframe.center, keyframe.zoom, keyframe.pitch, keyframe.bearing)
        }

        // Calculate interpolation factor
        let segmentDuration = after.timestamp - before.timestamp
        let segmentProgress = segmentDuration > 0 ? (progress - before.timestamp) / segmentDuration : 0.0

        // Smooth interpolation using easing
        let easedProgress = easeInOutCubic(Float(segmentProgress))

        // Interpolate all camera properties
        let center = interpolateCoordinate(before.center, after.center, factor: easedProgress)
        let zoom = interpolateDouble(before.zoom, after.zoom, factor: easedProgress)
        let pitch = interpolateDouble(before.pitch, after.pitch, factor: easedProgress)
        let bearing = interpolateDouble(before.bearing, after.bearing, factor: easedProgress)

        return (center, zoom, pitch, bearing)
    }

    private func easeInOutCubic(_ t: Float) -> Float {
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private func interpolateCoordinate(_ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D, factor: Float) -> CLLocationCoordinate2D {
        let lat = start.latitude + Double(factor) * (end.latitude - start.latitude)
        let lon = start.longitude + Double(factor) * (end.longitude - start.longitude)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func interpolateDouble(_ start: Double, _ end: Double, factor: Float) -> Double {
        return start + Double(factor) * (end - start)
    }

    private func calculateJourneyCenter(_ path: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !path.isEmpty else { return CLLocationCoordinate2D(latitude: 0, longitude: 0) }

        let totalLat = path.reduce(0.0) { $0 + $1.latitude }
        let totalLon = path.reduce(0.0) { $0 + $1.longitude }

        return CLLocationCoordinate2D(
            latitude: totalLat / Double(path.count),
            longitude: totalLon / Double(path.count)
        )
    }

    private func createPixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(image.size.width),
            Int(image.size.height),
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        let pixelData = CVPixelBufferGetBaseAddress(buffer)

        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: pixelData,
            width: Int(image.size.width),
            height: Int(image.size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }

        context.translateBy(x: 0, y: image.size.height)
        context.scaleBy(x: 1.0, y: -1.0)

        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
        UIGraphicsPopContext()

        CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))

        return buffer
    }

    // MARK: - Completion Handler

    var onVideoCompleted: ((URL) -> Void)?
}

// MARK: - Usage Example

extension CustomMapView.Coordinator {
    func createJourneyVideo(
        startLocation: CLLocationCoordinate2D,
        journeyPath: [CLLocationCoordinate2D],
        endLocation: CLLocationCoordinate2D,
        completion: @escaping (URL?) -> Void
    ) {
        guard let mapView = mapView else {
            completion(nil)
            return
        }

        let animator = CustomGlobeAnimator(mapView: mapView)

        // Setup video capture (30 second video at 30fps)
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoURL = documentsPath.appendingPathComponent("journey_\(Date().timeIntervalSince1970).mp4")

        if animator.setupVideoCapture(outputURL: videoURL, duration: 30.0, fps: 30) {
            animator.createJourneyAnimation(
                startLocation: startLocation,
                journeyPath: journeyPath,
                endLocation: endLocation
            )

            animator.onVideoCompleted = { url in
                completion(url)
            }

            animator.startRecording()
        } else {
            completion(nil)
        }
    }
}