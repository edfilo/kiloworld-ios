//
//  CompassBeamView.swift
//  kiloworld
//
//  Created by Claude on 9/24/25.
//

import SwiftUI

struct CompassBeamView: View {
    let heading: Double
    let isVisible: Bool
    
    var body: some View {
        ZStack {
            if isVisible {
                // Blue beam pointing in the compass direction (north is 0°)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.9), Color.cyan.opacity(0.2)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 120, height: 6)
                    .offset(x: 60) // Move beam so it starts from center and extends outward
                    .rotationEffect(.degrees(heading), anchor: .leading) // Rotate around the left edge (center point)
                    .shadow(color: .cyan.opacity(0.5), radius: 4, x: 0, y: 0)
                    .animation(.easeOut(duration: 0.5), value: heading)
                
                // Center dot to show the origin
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 8, height: 8)
                    .shadow(color: .cyan.opacity(0.7), radius: 2, x: 0, y: 0)
            }
        }
        .allowsHitTesting(false) // Don't block map touches
    }
}

#Preview {
    ZStack {
        Color.black
        CompassBeamView(heading: 45, isVisible: true)
    }
}