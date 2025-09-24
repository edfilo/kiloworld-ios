//
//  PolyphonicMTKView.swift
//  kiloworld
//
//  Created by Claude on 9/22/25.
//

import MetalKit
import UIKit

class PolyphonicMTKView: MTKView {
    weak var coordinator: FullscreenMetalView.FullscreenCoordinator?
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("🟢 PolyphonicMTKView.touchesBegan called with \(touches.count) touches")
        coordinator?.handleTouchesBegan(touches, with: event, in: self)
        
        // Forward touches to the view behind (map)
        if let parentView = self.superview {
            parentView.touchesBegan(touches, with: event)
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("🟡 PolyphonicMTKView.touchesMoved called with \(touches.count) touches")
        coordinator?.handleTouchesMoved(touches, with: event, in: self)
        
        // Forward touches to the view behind (map)
        if let parentView = self.superview {
            parentView.touchesMoved(touches, with: event)
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("🔴 PolyphonicMTKView.touchesEnded called with \(touches.count) touches")
        coordinator?.handleTouchesEnded(touches, with: event, in: self)
        
        // Forward touches to the view behind (map)
        if let parentView = self.superview {
            parentView.touchesEnded(touches, with: event)
        }
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("❌ PolyphonicMTKView.touchesCancelled called with \(touches.count) touches")
        coordinator?.handleTouchesEnded(touches, with: event, in: self)
        
        // Forward touches to the view behind (map)
        if let parentView = self.superview {
            parentView.touchesCancelled(touches, with: event)
        }
    }
}

// MARK: - Gesture Recognizer Delegate
extension FullscreenMetalView.FullscreenCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        print("🤏 Gesture delegate called: \(gestureRecognizer) vs \(otherGestureRecognizer)")
        return true // Allow simultaneous gestures for now
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        print("👆 Gesture should receive touch: \(gestureRecognizer)")
        return true
    }
}