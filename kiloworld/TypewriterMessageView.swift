//
//  TypewriterMessageView.swift
//  kiloworld
//
//  Created by Claude on 9/24/25.
//

import SwiftUI

struct TypewriterMessageView: View {
    let latestMessage: String
    @State private var displayedText: String = ""
    @State private var currentIndex: Int = 0
    @State private var typewriterTimer: Timer?
    @State private var showCursor: Bool = true
    @State private var cursorTimer: Timer?
    
    var body: some View {
        GeometryReader { geometry in
            VStack {
                // Position at 30% from top of screen
                Spacer()
                    .frame(height: geometry.size.height * 0.3)
                
                HStack {
                    Spacer()
                    
                    Text(displayedText + (showCursor && currentIndex < latestMessage.count ? "|" : ""))
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.cyan, .blue, .purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .shadow(color: .cyan.opacity(0.5), radius: 3, x: 0, y: 1)
                    
                    Spacer()
                }
                
                Spacer()
            }
        }
        .allowsHitTesting(false) // Let touches pass through to map
        .onChange(of: latestMessage) { _, newMessage in
            startTypewriter(message: newMessage)
        }
        .onAppear {
            if !latestMessage.isEmpty {
                startTypewriter(message: latestMessage)
            }
            startCursorBlink()
        }
        .onDisappear {
            stopTypewriter()
            stopCursorBlink()
        }
    }
    
    private func startTypewriter(message: String) {
        // Reset state
        stopTypewriter()
        displayedText = ""
        currentIndex = 0
        
        // Don't show empty messages
        guard !message.isEmpty else { return }
        
        print("[typewriter] 🖨️ Starting typewriter for message: \"\(String(message.prefix(50)))...\"")
        
        // Start typing effect
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if currentIndex < message.count {
                let index = message.index(message.startIndex, offsetBy: currentIndex)
                displayedText = String(message[..<message.index(after: index)])
                currentIndex += 1
            } else {
                // Finished typing
                stopTypewriter()
            }
        }
    }
    
    private func stopTypewriter() {
        typewriterTimer?.invalidate()
        typewriterTimer = nil
    }
    
    private func startCursorBlink() {
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.1)) {
                showCursor.toggle()
            }
        }
    }
    
    private func stopCursorBlink() {
        cursorTimer?.invalidate()
        cursorTimer = nil
    }
}