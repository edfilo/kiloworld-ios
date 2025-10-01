//
//  LayerAudioEngine.swift
//  kiloworld
//
//  Audio engine for looping audio files from layer URLs
//

import AVFoundation
import Foundation

class LayerAudioEngine: ObservableObject {
    private var audioEngine: AVAudioEngine
    private var playerNodes: [String: AVAudioPlayerNode] = [:]
    private var audioBuffers: [String: AVAudioPCMBuffer] = [:]
    private var layerVolumes: [String: Float] = [:]
    private var isPlaying: [String: Bool] = [:]
    private var tempFileURLs: [String: URL] = [:] // Track temp files for cleanup

    @Published var masterVolume: Float = 0.7
    @Published var activeLayerCount: Int = 0

    init() {
        audioEngine = AVAudioEngine()
        setupAudioSession()
    }

    deinit {
        stopAllLayers()
        audioEngine.stop()

        // Clean up all temporary files
        for (layerId, tempFileURL) in tempFileURLs {
            do {
                try FileManager.default.removeItem(at: tempFileURL)
                print("🧹 LayerAudioEngine: Cleaned up temp file on deinit: \(tempFileURL.lastPathComponent)")
            } catch {
                print("⚠️ LayerAudioEngine: Failed to clean up temp file on deinit: \(error)")
            }
        }
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            print("🔧 LayerAudioEngine: Configuring audio session...")
            print("   - Current category: \(session.category)")
            print("   - Current options: \(session.categoryOptions)")
            print("   - Current mode: \(session.mode)")

            // Only configure session if not already properly set (to avoid conflicts with MetalWavetableSynth)
            if session.category != .playback {
                print("🔄 LayerAudioEngine: Changing audio session category to playback")
                try session.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .mixWithOthers])
                print("✅ LayerAudioEngine: Audio session category set to playback")
            } else {
                print("✅ LayerAudioEngine: Audio session already set to playback")
            }

            print("🔄 LayerAudioEngine: Activating audio session")
            try session.setActive(true)
            print("✅ LayerAudioEngine: Audio session activated")

            print("📊 LayerAudioEngine: Audio session configured:")
            print("   - Sample rate: \(session.sampleRate)Hz")
            print("   - Output route: \(session.currentRoute.outputs.first?.portName ?? "unknown")")
        } catch {
            print("❌ LayerAudioEngine: Failed to setup audio session: \(error)")
            if let nsError = error as NSError? {
                print("   - Error domain: \(nsError.domain)")
                print("   - Error code: \(nsError.code)")
                print("   - Error description: \(nsError.localizedDescription)")
            }
        }
    }

    private func ensureAudioEngineStarted() {
        if !audioEngine.isRunning {
            do {
                print("🔄 LayerAudioEngine: Starting audio engine")
                try audioEngine.start()
                print("✅ LayerAudioEngine: Audio engine started successfully")
            } catch {
                print("❌ LayerAudioEngine: Failed to start audio engine: \(error)")
            }
        }
    }

    func loadAudioLayer(layerId: String, url: URL, volume: Float = 1.0) async {
        print("🎵 LayerAudioEngine: Loading audio layer '\(layerId)' from \(url)")

        do {
            print("🌐 LayerAudioEngine: Downloading audio data from URL...")
            let (data, response) = try await URLSession.shared.data(from: url)

            if let httpResponse = response as? HTTPURLResponse {
                print("🌐 LayerAudioEngine: HTTP Response: \(httpResponse.statusCode)")
                print("🌐 LayerAudioEngine: Content-Type: \(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown")")
                print("🌐 LayerAudioEngine: Content-Length: \(data.count) bytes")
            }

            // Detect the actual audio format from the data header
            print("🔍 LayerAudioEngine: Detecting audio format from data...")
            let header = data.prefix(10)
            print("🔍 LayerAudioEngine: File header: \(header.map { String(format: "%02X", $0) }.joined(separator: " "))")

            // Determine correct file extension based on actual format
            var fileExtension = "mp3" // default
            let headerString = String(data: header.prefix(4), encoding: .ascii) ?? ""

            if header.count >= 3 && header[0] == 0xFF && (header[1] & 0xE0) == 0xE0 {
                print("✅ LayerAudioEngine: Valid MP3 header detected")
                fileExtension = "mp3"
            } else if headerString == "RIFF" {
                print("✅ LayerAudioEngine: WAV file detected (despite .mp3 URL)")
                fileExtension = "wav"
            } else if headerString.hasPrefix("ID3") {
                print("✅ LayerAudioEngine: MP3 with ID3 tag detected")
                fileExtension = "mp3"
            } else if headerString == "fLaC" {
                print("✅ LayerAudioEngine: FLAC file detected")
                fileExtension = "flac"
            } else if headerString == "OggS" {
                print("✅ LayerAudioEngine: Ogg file detected")
                fileExtension = "ogg"
            } else {
                print("⚠️ LayerAudioEngine: Unknown audio format, using original extension")
                print("   Header: \(headerString)")
                // Try to get extension from original URL
                fileExtension = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            }

            // Create a temporary file with the correct extension
            print("🎵 LayerAudioEngine: Creating temporary file for audio data...")
            let tempDirectory = FileManager.default.temporaryDirectory
            let tempFileName = "\(layerId)_\(UUID().uuidString).\(fileExtension)"
            let tempFileURL = tempDirectory.appendingPathComponent(tempFileName)

            // Write audio data to temporary file
            try data.write(to: tempFileURL)
            print("✅ LayerAudioEngine: Saved \(fileExtension.uppercased()) data to temporary file: \(tempFileURL.lastPathComponent)")

            print("🎵 LayerAudioEngine: Creating AVAudioFile from temporary file...")

            var audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(forReading: tempFileURL)
            } catch {
                print("⚠️ LayerAudioEngine: Direct file loading failed, trying alternative approach...")
                print("   Error: \(error)")

                // Try using AVPlayerItem to load and then export as a compatible format
                let asset = AVURLAsset(url: tempFileURL)

                // Check if the asset is readable
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard !tracks.isEmpty else {
                    throw NSError(domain: "LayerAudioEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "No audio tracks found in file"])
                }

                print("✅ LayerAudioEngine: AVAsset can read the file, found \(tracks.count) audio track(s)")

                // For now, re-throw the original error - we could implement conversion here if needed
                throw error
            }

            print("🎵 LayerAudioEngine: Audio file info:")
            print("   - Format: \(audioFile.processingFormat)")
            print("   - Length: \(audioFile.length) frames")
            print("   - Duration: \(Double(audioFile.length) / audioFile.processingFormat.sampleRate) seconds")

            guard let audioBuffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: AVAudioFrameCount(audioFile.length)
            ) else {
                print("❌ LayerAudioEngine: Failed to create audio buffer for \(layerId)")
                return
            }

            print("🎵 LayerAudioEngine: Reading audio data into buffer...")
            try audioFile.read(into: audioBuffer)

            await MainActor.run {
                audioBuffers[layerId] = audioBuffer
                layerVolumes[layerId] = volume
                tempFileURLs[layerId] = tempFileURL // Store for cleanup
                print("✅ LayerAudioEngine: Successfully loaded audio layer '\(layerId)'")
                print("   - Buffer frames: \(audioBuffer.frameLength)")
                print("   - Sample rate: \(audioBuffer.format.sampleRate)Hz")
                print("   - Channels: \(audioBuffer.format.channelCount)")
                print("   - Temp file: \(tempFileURL.lastPathComponent)")
            }

        } catch {
            print("❌ LayerAudioEngine: Failed to load audio for layer '\(layerId)': \(error)")
            if let nsError = error as NSError? {
                print("   - Error domain: \(nsError.domain)")
                print("   - Error code: \(nsError.code)")
                print("   - Error description: \(nsError.localizedDescription)")
            }

            // Clean up temp file if loading failed (best effort)
            let tempDirectory = FileManager.default.temporaryDirectory
            let tempFileName = "\(layerId)_"
            do {
                let tempFiles = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
                for tempFileURL in tempFiles where tempFileURL.lastPathComponent.hasPrefix(tempFileName) {
                    try FileManager.default.removeItem(at: tempFileURL)
                    print("🧹 LayerAudioEngine: Cleaned up failed temp file: \(tempFileURL.lastPathComponent)")
                }
            } catch {
                print("⚠️ LayerAudioEngine: Failed to clean up temp files after error: \(error)")
            }
        }
    }

    func playLayer(layerId: String, loop: Bool = true) {
        print("🎵 LayerAudioEngine: Attempting to play layer '\(layerId)'")

        guard let audioBuffer = audioBuffers[layerId] else {
            print("❌ LayerAudioEngine: No audio buffer found for layer '\(layerId)'")
            print("   Available buffers: \(Array(audioBuffers.keys))")
            return
        }

        if isPlaying[layerId] == true {
            print("⚠️ LayerAudioEngine: Layer '\(layerId)' is already playing")
            return
        }

        print("🎵 LayerAudioEngine: Creating player node for '\(layerId)'")
        let playerNode = AVAudioPlayerNode()
        let volume = layerVolumes[layerId] ?? 1.0

        audioEngine.attach(playerNode)
        print("✅ LayerAudioEngine: Player node attached")

        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioBuffer.format)
        print("✅ LayerAudioEngine: Player node connected to mixer")

        // Start the audio engine only after we have nodes attached
        ensureAudioEngineStarted()
        print("🎵 LayerAudioEngine: Audio engine running: \(audioEngine.isRunning)")

        playerNodes[layerId] = playerNode
        isPlaying[layerId] = true

        let finalVolume = volume * masterVolume
        playerNode.volume = finalVolume
        print("🔊 LayerAudioEngine: Set volume to \(finalVolume) (layer: \(volume), master: \(masterVolume))")

        if loop {
            playerNode.scheduleBuffer(audioBuffer, at: nil, options: .loops, completionHandler: nil)
            print("🔄 LayerAudioEngine: Scheduled buffer with looping")
        } else {
            playerNode.scheduleBuffer(audioBuffer, at: nil, options: [], completionHandler: { [weak self] in
                print("🎵 LayerAudioEngine: Non-looping playback completed for '\(layerId)'")
                DispatchQueue.main.async {
                    self?.stopLayer(layerId: layerId)
                }
            })
            print("➡️ LayerAudioEngine: Scheduled buffer without looping")
        }

        playerNode.play()
        print("▶️ LayerAudioEngine: Player node started")

        updateActiveLayerCount()

        print("✅ LayerAudioEngine: Successfully started playing layer '\(layerId)'")
        print("   - Loop: \(loop)")
        print("   - Volume: \(finalVolume)")
        print("   - Active layers: \(activeLayerCount)")
    }

    func stopLayer(layerId: String) {
        guard let playerNode = playerNodes[layerId] else {
            print("⚠️ LayerAudioEngine: No player node found for layer '\(layerId)'")
            return
        }

        playerNode.stop()
        audioEngine.detach(playerNode)

        playerNodes.removeValue(forKey: layerId)
        isPlaying[layerId] = false
        updateActiveLayerCount()

        print("🔇 LayerAudioEngine: Stopped layer '\(layerId)'")
    }

    func stopAllLayers() {
        for layerId in Array(playerNodes.keys) {
            stopLayer(layerId: layerId)
        }
        print("🔇 LayerAudioEngine: Stopped all layers")
    }

    func setLayerVolume(layerId: String, volume: Float) {
        let clampedVolume = max(0.0, min(1.0, volume))
        layerVolumes[layerId] = clampedVolume

        if let playerNode = playerNodes[layerId] {
            playerNode.volume = clampedVolume * masterVolume
        }

        print("🔊 LayerAudioEngine: Set layer '\(layerId)' volume to \(clampedVolume)")
    }

    func setMasterVolume(_ volume: Float) {
        let clampedVolume = max(0.0, min(1.0, volume))
        masterVolume = clampedVolume

        for (layerId, playerNode) in playerNodes {
            let layerVolume = layerVolumes[layerId] ?? 1.0
            playerNode.volume = layerVolume * masterVolume
        }

        print("🔊 LayerAudioEngine: Set master volume to \(clampedVolume)")
    }

    func isLayerPlaying(layerId: String) -> Bool {
        return isPlaying[layerId] ?? false
    }

    func getLayerVolume(layerId: String) -> Float {
        return layerVolumes[layerId] ?? 1.0
    }

    func getAllActiveLayers() -> [String] {
        return Array(playerNodes.keys)
    }

    private func updateActiveLayerCount() {
        activeLayerCount = playerNodes.count
    }

    func removeLayer(layerId: String) {
        stopLayer(layerId: layerId)
        audioBuffers.removeValue(forKey: layerId)
        layerVolumes.removeValue(forKey: layerId)
        isPlaying.removeValue(forKey: layerId)

        // Clean up temporary file
        if let tempFileURL = tempFileURLs.removeValue(forKey: layerId) {
            do {
                try FileManager.default.removeItem(at: tempFileURL)
                print("🧹 LayerAudioEngine: Cleaned up temp file: \(tempFileURL.lastPathComponent)")
            } catch {
                print("⚠️ LayerAudioEngine: Failed to clean up temp file: \(error)")
            }
        }

        print("🗑️ LayerAudioEngine: Removed layer '\(layerId)'")
    }

    func crossfade(fromLayerId: String, toLayerId: String, duration: TimeInterval = 2.0) {
        guard let fromNode = playerNodes[fromLayerId],
              let toBuffer = audioBuffers[toLayerId] else {
            print("❌ LayerAudioEngine: Cannot crossfade - missing nodes or buffers")
            return
        }

        let toNode = AVAudioPlayerNode()
        audioEngine.attach(toNode)
        audioEngine.connect(toNode, to: audioEngine.mainMixerNode, format: toBuffer.format)

        playerNodes[toLayerId] = toNode
        isPlaying[toLayerId] = true

        let startVolume = fromNode.volume
        let endVolume = (layerVolumes[toLayerId] ?? 1.0) * masterVolume

        toNode.volume = 0.0
        toNode.scheduleBuffer(toBuffer, at: nil, options: .loops, completionHandler: nil)
        toNode.play()

        let steps = Int(duration * 60) // 60 fps
        let stepDuration = duration / Double(steps)

        for step in 0...steps {
            let progress = Float(step) / Float(steps)

            DispatchQueue.main.asyncAfter(deadline: .now() + stepDuration * Double(step)) { [weak self] in
                fromNode.volume = startVolume * (1.0 - progress)
                toNode.volume = endVolume * progress

                if step == steps {
                    self?.stopLayer(layerId: fromLayerId)
                }
            }
        }

        updateActiveLayerCount()
        print("🌀 LayerAudioEngine: Crossfading from '\(fromLayerId)' to '\(toLayerId)' over \(duration)s")
    }
}