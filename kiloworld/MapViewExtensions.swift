//
//  MapViewExtensions.swift
//  kiloworld
//
//  Created by Claude on 9/22/25.
//

import MapboxMaps
import UIKit

extension MapView {
    func applyNeonGridStyle() {
        print("[map] 🎨 Starting neon grid style application...")
        
        // 1) Background tint (deep purple/near-black)
        var bg = BackgroundLayer(id: "neon-bg")
        bg.backgroundColor = .constant(StyleColor(UIColor(red: 0.02, green: 0.01, blue: 0.05, alpha: 1)))
        do {
            try self.mapboxMap.addLayer(bg, layerPosition: .at(0))
            print("[map] ✅ Added dark background layer")
        } catch {
            print("[map] ❌ Failed to add background: \(error)")
        }

        // 2) Add stars layer using Mapbox's sky layer with fog
        var skyLayer = SkyLayer(id: "stars-sky")
        skyLayer.skyType = .constant(.atmosphere)
        skyLayer.skyAtmosphereSun = .constant([0.0, 90.0]) // Sun at zenith (creates dark sky)
        skyLayer.skyAtmosphereSunIntensity = .constant(0.1) // Very low sun intensity for dark sky
        skyLayer.skyOpacity = .constant(0.8)
        do {
            try self.mapboxMap.addLayer(skyLayer, layerPosition: .at(1))
            print("[map] ✅ Added stars sky layer")
        } catch {
            print("[map] ❌ Failed to add stars sky layer: \(error)")
        }

        // 3) Streets source (Mapbox Streets v8)
        var streets = VectorSource(id: "neon-streets")
        streets.url = "mapbox://mapbox.mapbox-streets-v8"
        do {
            try self.mapboxMap.addSource(streets)
            print("[map] ✅ Added streets source")
        } catch {
            print("[map] ❌ Failed to add streets source: \(error)")
        }
        
        // Road filter for drivable roads
        let roadFilter: Exp = Exp(.any) {
            Exp(.eq) { Exp(.get) { "class" }; "motorway" }
            Exp(.eq) { Exp(.get) { "class" }; "motorway_link" }
            Exp(.eq) { Exp(.get) { "class" }; "trunk" }
            Exp(.eq) { Exp(.get) { "class" }; "trunk_link" }
            Exp(.eq) { Exp(.get) { "class" }; "primary" }
            Exp(.eq) { Exp(.get) { "class" }; "primary_link" }
            Exp(.eq) { Exp(.get) { "class" }; "secondary" }
            Exp(.eq) { Exp(.get) { "class" }; "secondary_link" }
            Exp(.eq) { Exp(.get) { "class" }; "tertiary" }
            Exp(.eq) { Exp(.get) { "class" }; "tertiary_link" }
            Exp(.eq) { Exp(.get) { "class" }; "street" }
            Exp(.eq) { Exp(.get) { "class" }; "street_limited" }
            Exp(.eq) { Exp(.get) { "class" }; "service" }
        }
        
        // Brighter white neon colors
        let neonCore = StyleColor(UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1))   // pure white
        let neonGlow = StyleColor(UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1))   // pure white glow
        
        // Zoom-driven width expressions - thinner roads
        let wideByZoom: Exp = Exp(.interpolate) {
            Exp(.exponential, 1.2)
            Exp(.zoom)
            5;  0.5
            10; 2.0
            13; 4.0
            16; 8.0
            18; 12.0
        }
        let thinByZoom: Exp = Exp(.interpolate) {
            Exp(.exponential, 1.2)
            Exp(.zoom)
            5;  0.2
            10; 0.8
            13; 2.0
            16; 4.0
            18; 6.0
        }
        
        // 4) GLOW layer (fat, blurred, low opacity)
        var glow = LineLayer(id: "neon-glow", source: "neon-streets")
        glow.sourceLayer = "road"
        glow.filter = roadFilter
        glow.lineColor = .constant(neonGlow)
        glow.lineOpacity = .constant(0.8)
        glow.lineWidth = .expression(wideByZoom)
        glow.lineBlur = .expression(Exp(.interpolate) {
            Exp(.linear); Exp(.zoom)
            5;  1.0
            12; 3.0
            16; 8.0
            18; 15.0
        })
        glow.lineCap = .constant(.round)
        glow.lineJoin = .constant(.round)
        do {
            try self.mapboxMap.addLayer(glow)
            print("[map] ✅ Added neon glow layer")
        } catch {
            print("[map] ❌ Failed to add glow layer: \(error)")
        }
        
        // 5) CORE layer (sharp center line)
        var core = LineLayer(id: "neon-core", source: "neon-streets")
        core.sourceLayer = "road"
        core.filter = roadFilter
        core.lineColor = .constant(neonCore)
        core.lineOpacity = .constant(1.0)
        core.lineWidth = .expression(thinByZoom)
        core.lineCap = .constant(.round)
        core.lineJoin = .constant(.round)
        do {
            try self.mapboxMap.addLayer(core)
            print("[map] ✅ Added neon core layer")
        } catch {
            print("[map] ❌ Failed to add core layer: \(error)")
        }
        
        print("[map] 🎨 Neon grid style application complete")
    }
}