//
//  MapboxObserverVideoCapture.swift
//  kiloworld
//
//  Video capture using Mapbox's built-in animation observers
//

import Foundation
import MapboxMaps
import CoreLocation
import AVFoundation
import UIKit

class MapboxObserverVideoCapture {
    private weak var mapView: MapView?

    // Video capture
    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // Animation tracking
    private var currentAnimator: BasicCameraAnimator?
    private var frameTimer: Timer?
    private var isRecording = false
    private var frameCount = 0
    private let fps: Int = 30

    // Animation sequence
    private var animationPhases: [(duration: Double, camera: CameraOptions)] = []
    private var currentPhaseIndex = 0

    // Completion
    var onVideoCompleted: ((URL?) -> Void)?
    var onProgress: ((Float) -> Void)?

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

    // MARK: - Animation Sequence Setup

    func createJourneyAnimation(
        startLocation: CLLocationCoordinate2D,
        journeyPath: [CLLocationCoordinate2D],
        endLocation: CLLocationCoordinate2D
    ) {
        animationPhases.removeAll()

        // Phase 1: Start position (immediate)
        animationPhases.append((
            duration: 0.0,
            camera: CameraOptions(
                center: startLocation,
                zoom: 16.0,
                bearing: 0.0,
                pitch: 85.0
            )
        ))

        // Phase 2: Zoom out to globe (8 seconds)
        animationPhases.append((
            duration: 8.0,
            camera: CameraOptions(
                center: startLocation,
                zoom: 0.5,
                bearing: 0.0,
                pitch: 0.0
            )
        ))

        // Phase 3: Rotate to show journey center (4 seconds)
        let journeyCenter = calculateJourneyCenter(journeyPath)
        animationPhases.append((
            duration: 4.0,
            camera: CameraOptions(
                center: journeyCenter,
                zoom: 0.5,
                bearing: 0.0,
                pitch: 0.0
            )
        ))

        // Phase 4: Globe rotation (10 seconds)
        animationPhases.append((
            duration: 10.0,
            camera: CameraOptions(
                center: journeyCenter,
                zoom: 0.5,
                bearing: 360.0, // Full rotation
                pitch: 0.0
            )
        ))

        // Phase 5: Zoom in to destination (8 seconds)
        animationPhases.append((
            duration: 8.0,
            camera: CameraOptions(
                center: endLocation,
                zoom: 16.0,
                bearing: 0.0,
                pitch: 85.0
            )
        ))

        print("🎬 Created animation sequence with \(animationPhases.count) phases")
    }

    // MARK: - Recording with Mapbox Observers

    func startRecording() {
        guard let videoWriter = videoWriter,
              let videoInput = videoInput else {
            onVideoCompleted?(nil)
            return
        }

        isRecording = true
        frameCount = 0
        currentPhaseIndex = 0

        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)

        print("🎥 Starting recording with Mapbox animation observers")

        // Start frame capture timer
        startFrameCapture()

        // Begin animation sequence
        executeNextPhase()
    }

    private func startFrameCapture() {
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
    }

    private func executeNextPhase() {
        guard currentPhaseIndex < animationPhases.count,
              let mapView = mapView else {
            finishRecording()
            return
        }

        let phase = animationPhases[currentPhaseIndex]
        print("🎬 Executing phase \(currentPhaseIndex + 1)/\(animationPhases.count) - duration: \(phase.duration)s")

        if phase.duration == 0.0 {
            // Immediate camera set
            mapView.camera.ease(to: phase.camera, duration: 0.0) { [weak self] _ in
                self?.currentPhaseIndex += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.executeNextPhase()
                }
            }
        } else {
            // Create animated transition
            createObservedAnimation(to: phase.camera, duration: phase.duration)
        }
    }

    private func createObservedAnimation(to camera: CameraOptions, duration: TimeInterval) {
        guard let mapView = mapView else { return }

        // Create animator using Mapbox's system
        let animator = mapView.camera.makeAnimator(
            duration: duration,
            curve: .easeInOut
        ) { transition in
            transition.center.toValue = camera.center
            transition.zoom.toValue = camera.zoom
            transition.bearing.toValue = camera.bearing
            transition.pitch.toValue = camera.pitch
        }

        currentAnimator = animator

        // Observe animation completion
        animator.addCompletion { [weak self] _ in
            print("🎬 Phase \(self?.currentPhaseIndex ?? -1) completed")
            self?.currentPhaseIndex += 1

            // Small delay then continue to next phase
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.executeNextPhase()
            }
        }

        // Start the animation
        animator.startAnimation()

        print("🎬 Started animation to zoom=\(camera.zoom ?? 0), bearing=\(camera.bearing ?? 0)°")
    }

    private func captureFrame() {
        guard isRecording,
              let mapView = mapView,
              let pixelBufferAdaptor = pixelBufferAdaptor,
              pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData else {
            return
        }

        // Get current animation progress for logging
        let animationProgress = currentAnimator?.fractionComplete ?? 0.0

        // Capture current map state
        let renderer = UIGraphicsImageRenderer(bounds: mapView.bounds)
        let image = renderer.image { context in
            mapView.layer.render(in: context.cgContext)
        }

        // Convert to pixel buffer
        if let pixelBuffer = createPixelBuffer(from: image) {
            let frameTime = CMTime(value: Int64(frameCount), timescale: Int32(fps))

            if pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: frameTime) {
                let totalProgress = (Float(currentPhaseIndex) + Float(animationProgress)) / Float(animationPhases.count)
                onProgress?(totalProgress)

                if frameCount % 30 == 0 { // Log every second
                    print("📹 Frame \(frameCount) - Phase \(currentPhaseIndex)/\(animationPhases.count) - Animation: \(Int(animationProgress * 100))%")
                }
            }
        }

        frameCount += 1
    }

    private func finishRecording() {
        frameTimer?.invalidate()
        frameTimer = nil
        isRecording = false

        guard let videoInput = videoInput,
              let videoWriter = videoWriter else { return }

        videoInput.markAsFinished()

        videoWriter.finishWriting { [weak self] in
            DispatchQueue.main.async {
                if videoWriter.status == .completed {
                    print("✅ Mapbox observer video completed successfully!")
                    print("📊 Total frames captured: \(self?.frameCount ?? 0)")
                    self?.onVideoCompleted?(videoWriter.outputURL)
                } else {
                    print("❌ Video recording failed: \(videoWriter.error?.localizedDescription ?? "Unknown error")")
                    self?.onVideoCompleted?(nil)
                }
            }
        }
    }

    // MARK: - Enhanced Animation Control

    func pauseRecording() {
        frameTimer?.invalidate()
        currentAnimator?.pauseAnimation()
        print("⏸️ Recording paused")
    }

    func resumeRecording() {
        startFrameCapture()
        currentAnimator?.startAnimation()
        print("▶️ Recording resumed")
    }

    func getAnimationProgress() -> (phase: Int, phaseProgress: Float, totalProgress: Float) {
        let phaseProgress = Float(currentAnimator?.fractionComplete ?? 0.0)
        let totalProgress = (Float(currentPhaseIndex) + phaseProgress) / Float(animationPhases.count)

        return (currentPhaseIndex, phaseProgress, totalProgress)
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
    func createObservedJourneyVideo(
        startLocation: CLLocationCoordinate2D,
        journeyPath: [CLLocationCoordinate2D],
        endLocation: CLLocationCoordinate2D,
        completion: @escaping (URL?) -> Void
    ) {
        guard let mapView = mapView else {
            completion(nil)
            return
        }

        let videoCapture = MapboxObserverVideoCapture(mapView: mapView)

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoURL = documentsPath.appendingPathComponent("observed_journey_\(Date().timeIntervalSince1970).mp4")

        if videoCapture.setupVideoCapture(outputURL: videoURL) {
            videoCapture.onVideoCompleted = completion

            videoCapture.onProgress = { progress in
                print("🎬 Video progress: \(Int(progress * 100))%")
            }

            // Create animation sequence
            videoCapture.createJourneyAnimation(
                startLocation: startLocation,
                journeyPath: journeyPath,
                endLocation: endLocation
            )

            // Start recording with Mapbox observers
            videoCapture.startRecording()
        } else {
            completion(nil)
        }
    }
}