//
//  FrameCallbackVideoCapture.swift
//  kiloworld
//
//  Video capture using Mapbox's actual frame callbacks via camera observer
//

import Foundation
import MapboxMaps
import CoreLocation
import AVFoundation
import UIKit

class FrameCallbackVideoCapture {
    private weak var mapView: MapView?

    // Video capture
    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // Frame tracking using Mapbox's internal cycle
    private var cameraObserver: Cancelable?
    private var isRecording = false
    private var frameCount = 0
    private let targetFPS: Int = 30
    private var lastCaptureTime: CFTimeInterval = 0
    private let frameInterval: CFTimeInterval

    // Animation sequence
    private var animationPhases: [AnimationPhase] = []
    private var currentPhaseIndex = 0
    private var currentAnimator: BasicCameraAnimator?
    private var phaseStartTime: CFTimeInterval = 0

    // Frame deduplication
    private var lastCameraState: CameraState?
    private let minimumChangeThreshold: Double = 0.001 // Minimum change to warrant new frame

    struct AnimationPhase {
        let duration: Double
        let camera: CameraOptions
        let name: String
    }

    // Completion
    var onVideoCompleted: ((URL?) -> Void)?
    var onProgress: ((Float) -> Void)?
    var onFrameCaptured: ((Int) -> Void)?

    init(mapView: MapView) {
        self.mapView = mapView
        self.frameInterval = 1.0 / Double(targetFPS) // 33.33ms at 30fps
    }

    deinit {
        stopFrameObserver()
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
                    AVVideoMaxKeyFrameIntervalKey: targetFPS
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

        // Phase 1: Initial setup (immediate)
        animationPhases.append(AnimationPhase(
            duration: 0.0,
            camera: CameraOptions(
                center: startLocation,
                zoom: 16.0,
                bearing: 0.0,
                pitch: 85.0
            ),
            name: "Initial Setup"
        ))

        // Phase 2: Zoom out to space (8 seconds)
        animationPhases.append(AnimationPhase(
            duration: 8.0,
            camera: CameraOptions(
                center: startLocation,
                zoom: 0.5,
                bearing: 0.0,
                pitch: 0.0
            ),
            name: "Zoom to Space"
        ))

        // Phase 3: Pan to journey center (3 seconds)
        let journeyCenter = calculateJourneyCenter(journeyPath)
        animationPhases.append(AnimationPhase(
            duration: 3.0,
            camera: CameraOptions(
                center: journeyCenter,
                zoom: 0.5,
                bearing: 0.0,
                pitch: 0.0
            ),
            name: "Pan to Journey"
        ))

        // Phase 4: Globe rotation (12 seconds)
        animationPhases.append(AnimationPhase(
            duration: 12.0,
            camera: CameraOptions(
                center: journeyCenter,
                zoom: 0.5,
                bearing: 360.0,
                pitch: 0.0
            ),
            name: "Globe Rotation"
        ))

        // Phase 5: Pan to destination (2 seconds)
        animationPhases.append(AnimationPhase(
            duration: 2.0,
            camera: CameraOptions(
                center: endLocation,
                zoom: 0.5,
                bearing: 0.0,
                pitch: 0.0
            ),
            name: "Pan to Destination"
        ))

        // Phase 6: Zoom in to destination (5 seconds)
        animationPhases.append(AnimationPhase(
            duration: 5.0,
            camera: CameraOptions(
                center: endLocation,
                zoom: 16.0,
                bearing: 0.0,
                pitch: 85.0
            ),
            name: "Zoom to Destination"
        ))

        print("🎬 Created \(animationPhases.count) animation phases")
    }

    // MARK: - Frame Callback System

    func startRecording() {
        guard let videoWriter = videoWriter,
              let videoInput = videoInput else {
            onVideoCompleted?(nil)
            return
        }

        isRecording = true
        frameCount = 0
        currentPhaseIndex = 0
        lastCaptureTime = CACurrentMediaTime()

        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)

        print("🎥 Starting frame-callback video capture")

        // Start observing Mapbox's frame updates
        startFrameObserver()

        // Begin animation sequence
        executeNextPhase()
    }

    private func startFrameObserver() {
        guard let mapView = mapView else { return }

        // Hook into Mapbox's camera change observer - this fires on every frame during animations
        cameraObserver = mapView.mapboxMap.onCameraChanged.observe { [weak self] _ in
            guard let self = self, self.isRecording else { return }

            // This callback fires on Mapbox's actual frame update cycle
            self.onMapFrameUpdate()
        }

        print("📹 Started observing Mapbox frame updates")
    }

    private func stopFrameObserver() {
        cameraObserver?.cancel()
        cameraObserver = nil
    }

    private func onMapFrameUpdate() {
        let currentTime = CACurrentMediaTime()
        let timeSinceLastCapture = currentTime - lastCaptureTime

        // Only capture at our target frame rate (30fps = 33.33ms intervals)
        guard timeSinceLastCapture >= frameInterval else { return }

        // Check if camera actually changed significantly
        guard let mapView = mapView else { return }
        let currentCameraState = mapView.mapboxMap.cameraState

        if shouldCaptureFrame(currentCameraState) {
            captureFrame()
            lastCaptureTime = currentTime
            lastCameraState = currentCameraState
        }
    }

    private func shouldCaptureFrame(_ cameraState: CameraState) -> Bool {
        guard let lastState = lastCameraState else { return true }

        // Check if camera changed significantly enough to warrant a new frame
        let zoomChange = abs(cameraState.zoom - lastState.zoom)
        let pitchChange = abs(cameraState.pitch - lastState.pitch)
        let bearingChange = abs(cameraState.bearing - lastState.bearing)
        let centerChange = cameraState.center.distance(to: lastState.center)

        return zoomChange > minimumChangeThreshold ||
               pitchChange > minimumChangeThreshold ||
               bearingChange > minimumChangeThreshold ||
               centerChange > minimumChangeThreshold
    }

    private func captureFrame() {
        guard let mapView = mapView,
              let pixelBufferAdaptor = pixelBufferAdaptor,
              pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData else {
            return
        }

        // Capture current map state - this happens exactly when Mapbox renders
        let renderer = UIGraphicsImageRenderer(bounds: mapView.bounds)
        let image = renderer.image { context in
            mapView.layer.render(in: context.cgContext)
        }

        // Convert to pixel buffer
        if let pixelBuffer = createPixelBuffer(from: image) {
            let frameTime = CMTime(value: Int64(frameCount), timescale: Int32(targetFPS))

            if pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: frameTime) {
                frameCount += 1

                // Calculate progress
                let animationProgress = currentAnimator?.fractionComplete ?? 0.0
                let totalProgress = (Float(currentPhaseIndex) + Float(animationProgress)) / Float(animationPhases.count)

                onProgress?(totalProgress)
                onFrameCaptured?(frameCount)

                if frameCount % 30 == 0 { // Log every second
                    print("📹 Frame \(frameCount) captured - Phase: \(currentPhaseIndex + 1)/\(animationPhases.count) (\(Int(animationProgress * 100))%)")
                }
            }
        }
    }

    // MARK: - Animation Control

    private func executeNextPhase() {
        guard currentPhaseIndex < animationPhases.count,
              let mapView = mapView else {
            finishRecording()
            return
        }

        let phase = animationPhases[currentPhaseIndex]
        print("🎬 Executing: \(phase.name) (duration: \(phase.duration)s)")

        if phase.duration == 0.0 {
            // Immediate camera set
            mapView.camera.ease(to: phase.camera, duration: 0.0) { [weak self] _ in
                self?.currentPhaseIndex += 1
                // Small delay to ensure frame is rendered
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.executeNextPhase()
                }
            }
        } else {
            // Animated transition using Mapbox's optimized system
            phaseStartTime = CACurrentMediaTime()

            let animator = mapView.camera.makeAnimator(
                duration: phase.duration,
                curve: .easeInOut
            ) { transition in
                transition.center.toValue = phase.camera.center
                transition.zoom.toValue = phase.camera.zoom
                transition.bearing.toValue = phase.camera.bearing
                transition.pitch.toValue = phase.camera.pitch
            }

            currentAnimator = animator

            animator.addCompletion { [weak self] _ in
                print("✅ Completed: \(phase.name)")
                self?.currentPhaseIndex += 1

                // Brief pause between phases
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.executeNextPhase()
                }
            }

            animator.startAnimation()
        }
    }

    private func finishRecording() {
        stopFrameObserver()
        isRecording = false

        guard let videoInput = videoInput,
              let videoWriter = videoWriter else { return }

        videoInput.markAsFinished()

        videoWriter.finishWriting { [weak self] in
            DispatchQueue.main.async {
                if videoWriter.status == .completed {
                    print("✅ Frame-callback video completed!")
                    print("📊 Total frames captured: \(self?.frameCount ?? 0)")
                    print("📊 Average FPS: \(String(format: "%.1f", Double(self?.frameCount ?? 0) / 30.0))")
                    self?.onVideoCompleted?(videoWriter.outputURL)
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

// MARK: - Integration

extension CustomMapView.Coordinator {
    func createFrameCallbackJourneyVideo(
        startLocation: CLLocationCoordinate2D,
        journeyPath: [CLLocationCoordinate2D],
        endLocation: CLLocationCoordinate2D,
        completion: @escaping (URL?) -> Void
    ) {
        guard let mapView = mapView else {
            completion(nil)
            return
        }

        let videoCapture = FrameCallbackVideoCapture(mapView: mapView)

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoURL = documentsPath.appendingPathComponent("frame_callback_journey_\(Date().timeIntervalSince1970).mp4")

        if videoCapture.setupVideoCapture(outputURL: videoURL) {
            videoCapture.onVideoCompleted = completion

            videoCapture.onProgress = { progress in
                print("🎬 Video progress: \(Int(progress * 100))%")
            }

            videoCapture.onFrameCaptured = { frameCount in
                if frameCount % 60 == 0 { // Every 2 seconds
                    print("📹 Captured \(frameCount) frames")
                }
            }

            videoCapture.createJourneyAnimation(
                startLocation: startLocation,
                journeyPath: journeyPath,
                endLocation: endLocation
            )

            videoCapture.startRecording()
        } else {
            completion(nil)
        }
    }
}