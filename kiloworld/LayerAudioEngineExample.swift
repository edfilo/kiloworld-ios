//
//  LayerAudioEngineExample.swift
//  kiloworld
//
//  Example usage of LayerAudioEngine
//

import SwiftUI
import Foundation

struct LayerAudioEngineExample: View {
    @StateObject private var audioEngine = LayerAudioEngine()
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Layer Audio Engine Test")
                .font(.title)
                .padding()

            Text("Active Layers: \(audioEngine.activeLayerCount)")
                .font(.headline)

            VStack {
                Button("Load Test Audio from URL") {
                    loadTestAudio()
                }
                .disabled(isLoading)

                Button("Play Layer") {
                    audioEngine.playLayer(layerId: "test_layer")
                }

                Button("Stop Layer") {
                    audioEngine.stopLayer(layerId: "test_layer")
                }

                Button("Stop All Layers") {
                    audioEngine.stopAllLayers()
                }
            }
            .padding()

            Slider(value: Binding(
                get: { audioEngine.masterVolume },
                set: { audioEngine.setMasterVolume($0) }
            ), in: 0...1)
            .padding()

            Text("Master Volume: \(String(format: "%.2f", audioEngine.masterVolume))")
        }
        .padding()
    }

    private func loadTestAudio() {
        // Example: Load an audio file from a remote URL
        // In a real app, you'd get this URL from your layer data
        guard let url = URL(string: "https://example.com/audio/ambient.mp3") else {
            print("❌ Invalid test URL")
            return
        }

        isLoading = true

        Task {
            await audioEngine.loadAudioLayer(layerId: "test_layer", url: url, volume: 0.8)

            await MainActor.run {
                isLoading = false
                print("✅ Test audio loaded and ready to play")
            }
        }
    }
}

// MARK: - Integration Example

/*
Example layer data structure that would come from Firebase:

```json
{
  "layers": [
    {
      "type": "audio",
      "url": "https://example.com/audio/ambient-forest.mp3",
      "volume": 0.7,
      "loop": true,
      "autoplay": true
    },
    {
      "type": "audio",
      "url": "https://example.com/audio/rain-sounds.wav",
      "volume": 0.5,
      "loop": true,
      "autoplay": false
    },
    {
      "type": "image",
      "url": "https://example.com/images/forest-scene.jpg"
    }
  ]
}
```

The LayerAudioEngine will automatically:
1. Load audio layers from URLs
2. Start playing them if autoplay is true
3. Loop them if loop is true
4. Set appropriate volume levels
5. Allow crossfading between layers
6. Handle multiple concurrent audio layers

Usage in your app:
1. Add LayerAudioEngine as @StateObject in your main view
2. Process layer data from Firebase
3. Call loadAudioLayer() for audio type layers
4. Use playLayer(), stopLayer(), setLayerVolume() etc. as needed
*/