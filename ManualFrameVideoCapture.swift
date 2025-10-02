//
//  ManualFrameVideoCapture.swift
//  kiloworld
//
//  True frame-by-frame control for smooth video capture
//

import Foundation
import MapboxMaps
import CoreLocation
import AVFoundation
import UIKit

class ManualFrameVideoCapture {
    private weak var mapView: MapView?

    // Video capture
    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // Frame control
    private let fps: Int = 30
    private let totalDuration: Double = 30.0 // 30 second video
    private var totalFrames: Int { Int(totalDuration * Double(fps)) }
    private var currentFrame: Int = 0

    // Animation parameters
    private var keyframes: [AnimationKeyframe] = []

    // Completion
    var onVideoCompleted: ((URL?) -> Void)?
    var onProgress: ((Float) -> Void)?

    struct AnimationKeyframe {
        let center: CLLocationCoordinate2D
        let zoom: Double
        let pitch: Double
        let bearing: Double
        let frameNumber: Int
    }

    init(mapView: MapView) {
        self.mapView = mapView
    }

    // MARK: - Setup

    func setupVideoCapture(outputURL: URL) -> Bool {
        do {
            videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1080,
                AVVideoHeightKey: 1920,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8000000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: fps
                ]
            ]

            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = false

            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 1080,
                kCVPixelBufferHeightKey as String: 1920
            ]

            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput!,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )

            guard let videoInput = videoInput else { return false }
            videoWriter?.add(videoInput)

            return true
        } catch {
            print("❌ Failed to setup video capture: \(error)")
            return false
        }
    }

    // MARK: - Keyframe Generation

    func createJourneyKeyframes(
        startLocation: CLLocationCoordinate2D,
        journeyPath: [CLLocationCoordinate2D],
        endLocation: CLLocationCoordinate2D
    ) {
        keyframes.removeAll()

        print("🎬 Generating \(totalFrames) keyframes for \(totalDuration)s video")

        // Phase 1: Zoom out (0-8 seconds = frames 0-240)
        let phase1EndFrame = Int(8.0 * Double(fps)) // Frame 240
        addZoomOutKeyframes(
            startLocation: startLocation,
            startFrame: 0,
            endFrame: phase1EndFrame
        )

        // Phase 2: Globe rotation (8-22 seconds = frames 240-660)
        let phase2EndFrame = Int(22.0 * Double(fps)) // Frame 660
        addGlobeRotationKeyframes(
            journeyPath: journeyPath,
            startFrame: phase1EndFrame,
            endFrame: phase2EndFrame
        )

        // Phase 3: Zoom in (22-30 seconds = frames 660-900)
        addZoomInKeyframes(
            endLocation: endLocation,
            startFrame: phase2EndFrame,
            endFrame: totalFrames
        )

        print("✅ Generated \(keyframes.count) keyframes")
    }

    private func addZoomOutKeyframes(
        startLocation: CLLocationCoordinate2D,
        startFrame: Int,
        endFrame: Int
    ) {
        let frameCount = endFrame - startFrame

        for i in 0..<frameCount {
            let progress = Float(i) / Float(frameCount - 1)

            // Smooth zoom out curve
            let easedProgress = easeInOutCubic(progress)

            let zoom = interpolate(from: 16.0, to: 0.5, progress: easedProgress)
            let pitch = interpolate(from: 85.0, to: 0.0, progress: easedProgress)

            keyframes.append(AnimationKeyframe(
                center: startLocation,
                zoom: zoom,
                pitch: pitch,
                bearing: 0.0,
                frameNumber: startFrame + i
            ))
        }
    }

    private func addGlobeRotationKeyframes(
        journeyPath: [CLLocationCoordinate2D],
        startFrame: Int,
        endFrame: Int
    ) {
        let frameCount = endFrame - startFrame
        let journeyCenter = calculateJourneyCenter(journeyPath)

        for i in 0..<frameCount {
            let progress = Float(i) / Float(frameCount - 1)

            // Smooth rotation (720 degrees total for dramatic effect)
            let bearing = Double(progress) * 720.0

            keyframes.append(AnimationKeyframe(
                center: journeyCenter,
                zoom: 0.5,
                pitch: 0.0,
                bearing: bearing,
                frameNumber: startFrame + i
            ))
        }
    }

    private func addZoomInKeyframes(
        endLocation: CLLocationCoordinate2D,
        startFrame: Int,
        endFrame: Int
    ) {
        let frameCount = endFrame - startFrame

        for i in 0..<frameCount {
            let progress = Float(i) / Float(frameCount - 1)

            // Smooth zoom in curve
            let easedProgress = easeInOutCubic(progress)

            let zoom = interpolate(from: 0.5, to: 16.0, progress: easedProgress)
            let pitch = interpolate(from: 0.0, to: 85.0, progress: easedProgress)

            keyframes.append(AnimationKeyframe(
                center: endLocation,
                zoom: zoom,
                pitch: pitch,
                bearing: 0.0,
                frameNumber: startFrame + i
            ))
        }
    }

    // MARK: - Manual Frame Rendering

    func startRecording() {
        guard let videoWriter = videoWriter,
              let videoInput = videoInput else {
            onVideoCompleted?(nil)
            return
        }

        currentFrame = 0

        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)

        print("🎥 Starting manual frame-by-frame recording")

        // Start rendering frames one by one
        renderNextFrame()
    }

    private func renderNextFrame() {
        guard currentFrame < totalFrames,
              let mapView = mapView else {
            finishRecording()
            return
        }

        // Find the keyframe for this frame number
        guard let keyframe = keyframes.first(where: { $0.frameNumber == currentFrame }) else {
            print("❌ No keyframe found for frame \(currentFrame)")
            currentFrame += 1
            renderNextFrame()
            return
        }

        // Set camera to exact position for this frame
        let cameraOptions = CameraOptions(
            center: keyframe.center,
            zoom: keyframe.zoom,
            bearing: keyframe.bearing,
            pitch: keyframe.pitch
        )

        // CRITICAL: Use duration 0 to set camera immediately
        mapView.camera.ease(to: cameraOptions, duration: 0.0) { [weak self] _ in
            // Wait a moment for render to complete, then capture
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.captureCurrentFrame()
            }
        }
    }

    private func captureCurrentFrame() {
        guard let mapView = mapView,
              let pixelBufferAdaptor = pixelBufferAdaptor,
              pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData else {
            // Skip this frame if not ready
            currentFrame += 1
            renderNextFrame()
            return
        }

        // Capture the exact current state
        let renderer = UIGraphicsImageRenderer(bounds: mapView.bounds)
        let image = renderer.image { context in
            mapView.layer.render(in: context.cgContext)
        }

        // Convert to pixel buffer
        if let pixelBuffer = createPixelBuffer(from: image) {
            let frameTime = CMTime(value: Int64(currentFrame), timescale: Int32(fps))

            if pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: frameTime) {
                let progress = Float(currentFrame) / Float(totalFrames)
                onProgress?(progress)

                print("📹 Frame \(currentFrame)/\(totalFrames) captured (\(Int(progress * 100))%)")
            } else {
                print("❌ Failed to append frame \(currentFrame)")
            }
        }

        currentFrame += 1

        // Small delay to ensure frame is processed before next one
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.renderNextFrame()
        }
    }

    private func finishRecording() {
        guard let videoInput = videoInput,
              let videoWriter = videoWriter else { return }

        videoInput.markAsFinished()

        videoWriter.finishWriting { [weak self] in
            DispatchQueue.main.async {
                if videoWriter.status == .completed {
                    print("✅ Manual frame video completed successfully!")
                    self?.onVideoCompleted?(videoWriter.outputURL)
                } else {
                    print("❌ Video recording failed: \(videoWriter.error?.localizedDescription ?? "Unknown error")")
                    self?.onVideoCompleted?(nil)
                }
            }
        }
    }

    // MARK: - Utility Functions

    private func easeInOutCubic(_ t: Float) -> Float {
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private func interpolate(from start: Double, to end: Double, progress: Float) -> Double {
        return start + Double(progress) * (end - start)
    }

    private func calculateJourneyCenter(_ path: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !path.isEmpty else {
            return CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }

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
            1080,
            1920,
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
            width: 1080,
            height: 1920,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }

        // Scale and center the map to fit 1080x1920
        let mapBounds = image.size
        let targetSize = CGSize(width: 1080, height: 1920)

        let scaleX = targetSize.width / mapBounds.width
        let scaleY = targetSize.height / mapBounds.height
        let scale = min(scaleX, scaleY)

        let scaledSize = CGSize(
            width: mapBounds.width * scale,
            height: mapBounds.height * scale
        )

        let x = (targetSize.width - scaledSize.width) / 2
        let y = (targetSize.height - scaledSize.height) / 2

        context.translateBy(x: 0, y: targetSize.height)
        context.scaleBy(x: 1.0, y: -1.0)

        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: x, y: y, width: scaledSize.width, height: scaledSize.height))
        UIGraphicsPopContext()

        CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))

        return buffer
    }
}

// MARK: - Usage Example

extension CustomMapView.Coordinator {
    func createPrecisionJourneyVideo(
        startLocation: CLLocationCoordinate2D,
        journeyPath: [CLLocationCoordinate2D],
        endLocation: CLLocationCoordinate2D,
        completion: @escaping (URL?) -> Void
    ) {
        guard let mapView = mapView else {
            completion(nil)
            return
        }

        let videoCapture = ManualFrameVideoCapture(mapView: mapView)

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoURL = documentsPath.appendingPathComponent("precision_journey_\(Date().timeIntervalSince1970).mp4")

        if videoCapture.setupVideoCapture(outputURL: videoURL) {
            videoCapture.onVideoCompleted = completion

            videoCapture.onProgress = { progress in
                print("🎬 Video progress: \(Int(progress * 100))%")
            }

            // Generate all keyframes upfront
            videoCapture.createJourneyKeyframes(
                startLocation: startLocation,
                journeyPath: journeyPath,
                endLocation: endLocation
            )

            // Start frame-by-frame recording
            videoCapture.startRecording()
        } else {
            completion(nil)
        }
    }
}