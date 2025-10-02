//
//  TransparentModalViewController.swift
//  kiloworld
//
//  Created by Claude on 10/2/25.
//

import UIKit
import SwiftUI

// UIViewRepresentable to clear the UIHostingController background
struct BackgroundClearView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

final class TransparentModalViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        // Make the view completely transparent
        view.isOpaque = false
        view.backgroundColor = .clear
    }
}

// SwiftUI wrapper to present any view with a transparent background
struct TransparentModal<Content: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let content: Content

    init(isPresented: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self._isPresented = isPresented
        self.content = content()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if isPresented && uiViewController.presentedViewController == nil {
            let hostingController = UIHostingController(rootView: content)
            hostingController.modalPresentationStyle = .overFullScreen
            hostingController.modalTransitionStyle = .crossDissolve
            hostingController.view.backgroundColor = .clear

            uiViewController.present(hostingController, animated: true)
        } else if !isPresented && uiViewController.presentedViewController != nil {
            uiViewController.dismiss(animated: true)
        }
    }
}
