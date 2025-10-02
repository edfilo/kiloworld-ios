//
//  ImprovedGlobeVideoCapture.swift
//  kiloworld
//
//  Video capture that works WITH Mapbox's animation system, not against it
//

import Foundation
import MapboxMaps
import CoreLocation
import AVFoundation
import UIKit

class ImprovedGlobeVideoCapture {
    private weak var mapView: MapView?
    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // Use Mapbox's actual animation system instead of fighting it
    private var currentAnimators: [Cancelable] = []

    // Video capture state
    private var isRecording = false
    private var frameCount = 0
    private var startTime: CFTimeInterval = 0
    private let targetFPS: Double = 30
    private var videoURL: URL?

    // Completion handler
    var onVideoCompleted: ((URL?) -> Void)?

    init(mapView: MapView) {
        self.mapView = mapView
    }

    // MARK: - Setup Video Capture

    func setupVideoCapture(outputURL: URL) -> Bool {
        self.videoURL = outputURL

        do {
            videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

            // Instagram Reels format: 1080x1920, optimized for mobile
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1080,
                AVVideoHeightKey: 1920,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8000000, // 8 Mbps for high quality
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: 30 // Keyframe every second at 30fps
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

    // MARK: - Animation Sequence Using Mapbox's System

    func createJourneyVideo(
        startLocation: CLLocationCoordinate2D,
        journeyPath: [CLLocationCoordinate2D],
        endLocation: CLLocationCoordinate2D
    ) {
        guard let mapView = mapView,
              let videoWriter = videoWriter,
              let videoInput = videoInput else {
            onVideoCompleted?(nil)
            return
        }

        isRecording = true
        frameCount = 0
        startTime = CACurrentMediaTime()

        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)

        print("🎬 Starting journey video creation...")

        // Start the animation sequence
        performAnimationSequence(
            startLocation: startLocation,
            journeyPath: journeyPath,
            endLocation: endLocation
        )

        // Start frame capture using a more reliable method
        startFrameCapture()
    }

    private func performAnimationSequence(
        startLocation: CLLocationCoordinate2D,
        journeyPath: [CLLocationCoordinate2D],
        endLocation: CLLocationCoordinate2D
    ) {
        guard let mapView = mapView else { return }

        // Phase 1: Setup initial view (immediate)
        let initialCamera = CameraOptions(
            center: startLocation,
            zoom: 16.0,
            bearing: 0.0,
            pitch: 85.0
        )
        mapView.camera.ease(to: initialCamera, duration: 0.0)

        // Wait a moment for initial setup, then start sequence
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.performPhase1ZoomOut(startLocation: startLocation, journeyPath: journeyPath, endLocation: endLocation)
        }
    }

    private func performPhase1ZoomOut(
        startLocation: CLLocationCoordinate2D,
        journeyPath: [CLLocationCoordinate2D],
        endLocation: CLLocationCoordinate2D
    ) {
        guard let mapView = mapView else { return }

        print("🎬 Phase 1: Zooming out from start location")

        // Zoom out to globe view (8 seconds)
        let globeCamera = CameraOptions(
            center: startLocation,
            zoom: 0.5,
            bearing: 0.0,
            pitch: 0.0
        )

        let animator = mapView.camera.fly(to: globeCamera, duration: 8.0, curve: .easeOut) { [weak self] _ in
            print("🎬 Phase 1 complete, starting Phase 2")

            // Wait a moment then start globe rotation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.performPhase2GlobeRotation(
                    journeyPath: journeyPath,
                    endLocation: endLocation
                )
            }
        }

        currentAnimators.append(animator)
    }

    private func performPhase2GlobeRotation(
        journeyPath: [CLLocationCoordinate2D],
        endLocation: CLLocationCoordinate2D
    ) {
        guard let mapView = mapView else { return }

        print("🎬 Phase 2: Globe rotation sequence")

        // Calculate journey center for rotation focus
        let journeyCenter = calculateJourneyCenter(journeyPath)

        // Perform a series of rotation animations (12 seconds total)
        performRotationSequence(
            center: journeyCenter,
            rotations: [0, 60, 120, 180, 240, 300, 360],
            currentIndex: 0,
            endLocation: endLocation
        )
    }

    private func performRotationSequence(
        center: CLLocationCoordinate2D,
        rotations: [Double],
        currentIndex: Int,
        endLocation: CLLocationCoordinate2D
    ) {
        guard let mapView = mapView, currentIndex < rotations.count else {
            // Rotation complete, start zoom in
            performPhase3ZoomIn(endLocation: endLocation)
            return
        }

        let bearing = rotations[currentIndex]
        let rotationCamera = CameraOptions(
            center: center,
            zoom: 0.5,
            bearing: bearing,
            pitch: 0.0
        )

        let animator = mapView.camera.ease(to: rotationCamera, duration: 2.0, curve: .linear) { [weak self] _ in
            // Continue to next rotation
            self?.performRotationSequence(
                center: center,
                rotations: rotations,
                currentIndex: currentIndex + 1,
                endLocation: endLocation
            )
        }

        currentAnimators.append(animator)
    }

    private func performPhase3ZoomIn(endLocation: CLLocationCoordinate2D) {
        guard let mapView = mapView else { return }

        print("🎬 Phase 3: Zooming in to destination")

        // Final zoom in to destination (8 seconds)
        let finalCamera = CameraOptions(
            center: endLocation,
            zoom: 16.0,
            bearing: 0.0,
            pitch: 85.0
        )

        let animator = mapView.camera.fly(to: finalCamera, duration: 8.0, curve: .easeIn) { [weak self] _ in
            print("🎬 Phase 3 complete, finishing video")

            // Wait a moment then finish recording
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.finishRecording()
            }
        }

        currentAnimators.append(animator)
    }

    // MARK: - Frame Capture (Different Approach)

    private func startFrameCapture() {
        // Instead of CADisplayLink, use a timer that captures frames periodically
        // This works better with Mapbox's async rendering
        let captureInterval = 1.0 / targetFPS

        Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] timer in
            guard let self = self, self.isRecording else {
                timer.invalidate()
                return
            }

            self.captureCurrentFrame()
        }
    }

    private func captureCurrentFrame() {
        guard let mapView = mapView,
              let pixelBufferAdaptor = pixelBufferAdaptor,
              pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData else {
            return
        }

        // Capture the current frame asynchronously to avoid blocking
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Create snapshot of current map state
            let renderer = UIGraphicsImageRenderer(bounds: mapView.bounds)
            let image = renderer.image { context in
                mapView.layer.render(in: context.cgContext)
            }

            // Convert to pixel buffer and add to video
            if let pixelBuffer = self.createPixelBuffer(from: image) {
                let frameTime = CMTime(value: Int64(self.frameCount), timescale: Int32(self.targetFPS))
                pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: frameTime)

                self.frameCount += 1

                let elapsed = CACurrentMediaTime() - self.startTime
                print("🎬 Captured frame \(self.frameCount) at \(String(format: "%.1f", elapsed))s")
            }
        }
    }

    private func finishRecording() {
        guard let videoInput = videoInput,
              let videoWriter = videoWriter else { return }

        isRecording = false
        currentAnimators.forEach { $0.cancel() }
        currentAnimators.removeAll()

        videoInput.markAsFinished()

        videoWriter.finishWriting { [weak self] in
            DispatchQueue.main.async {
                if videoWriter.status == .completed {
                    print("✅ Journey video completed successfully!")
                    self?.onVideoCompleted?(self?.videoURL)
                } else {
                    print("❌ Video recording failed: \(videoWriter.error?.localizedDescription ?? "Unknown error")")
                    self?.onVideoCompleted?(nil)
                }
            }
        }
    }

    // MARK: - Utility Functions

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
            1080,  // Fixed size for social media
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

        // Scale and center the map view to fit 1080x1920
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

// MARK: - Integration with CustomMapView

extension CustomMapView.Coordinator {
    func createJourneyReel(
        startLocation: CLLocationCoordinate2D,
        journeyPath: [CLLocationCoordinate2D],
        endLocation: CLLocationCoordinate2D,
        completion: @escaping (URL?) -> Void
    ) {
        guard let mapView = mapView else {
            completion(nil)
            return
        }

        let videoCapture = ImprovedGlobeVideoCapture(mapView: mapView)

        // Setup video output
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoURL = documentsPath.appendingPathComponent("journey_reel_\(Date().timeIntervalSince1970).mp4")

        if videoCapture.setupVideoCapture(outputURL: videoURL) {
            videoCapture.onVideoCompleted = completion

            videoCapture.createJourneyVideo(
                startLocation: startLocation,
                journeyPath: journeyPath,
                endLocation: endLocation
            )
        } else {
            completion(nil)
        }
    }
}