//
//  ChatView.swift
//  kiloworld
//
//  Created by Claude on 9/22/25.
//

import SwiftUI
import FirebaseDatabase

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String
    let content: String
    
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        return lhs.id == rhs.id && lhs.role == rhs.role && lhs.content == rhs.content
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let isThinking: Bool

    var body: some View {
        HStack {
            Spacer() // Always push to right regardless of role

            if isThinking {
                // Thinking indicator
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(Color.white)
                            .frame(width: 6, height: 6)
                            .scaleEffect(thinking ? 1.0 : 0.5)
                            .animation(
                                Animation.easeInOut(duration: 0.6)
                                    .repeatForever()
                                    .delay(Double(index) * 0.2),
                                value: thinking
                            )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(12)
                .onAppear {
                    thinking = true
                }
            } else {
                Text(message.content)
                    .font(.system(size: 14, weight: .regular)) // Non-bold font
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black)
                    .foregroundColor(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1) // Light border
                    )
                    .cornerRadius(12)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.55) // Up to 55% screen width
            }
        }
        .padding(.horizontal, 5) // 5px from edges
    }

    @State private var thinking = false
}

struct ChatView: View {
    @Binding var messageText: String
    @Binding var chatMessages: [ChatMessage]
    @Binding var statusText: String
    @Binding var isListening: Bool
    @Binding var sessionXid: String?
    @Binding var currentXid: String?
    @Binding var generatedImages: [String]

    // Location and activity data for contextual AI responses
    let stepCount: Int
    let nearestCity: String
    let currentLocation: String?

    // Add location button callback
    var onLocationTapped: (() -> Void)?

    // Callback to provide latest AI message to parent view
    var onLatestMessageChanged: ((String) -> Void)?
    
    private let database = Database.database().reference()
    
    // Get latest AI response message
    private var latestAIMessage: String {
        return chatMessages.last(where: { $0.role == "assistant" })?.content ?? ""
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Latest message or thinking indicator - flexible height
            VStack(spacing: 4) {
                Spacer()

                if isListening && !statusText.isEmpty {
                    // Show thinking indicator when processing
                    ChatBubble(message: ChatMessage(role: "assistant", content: ""), isThinking: true)
                } else if let latestMessage = chatMessages.last {
                    // Show latest message
                    ChatBubble(message: latestMessage, isThinking: false)
                }
            }
            .allowsHitTesting(false) // Don't block map touches
            
            // Status text - more compact
            if !statusText.isEmpty {
                Text(statusText)
                    .font(.system(size: 9)) // Even smaller status text
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
            
            // Message input with location button - 55px height
            HStack(spacing: 8) {
                // GPS button - 55px height
                if let onLocationTapped = onLocationTapped {
                    Button(action: onLocationTapped) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    }
                    .frame(width: 55, height: 55)
                    .background(Color.blue) // Opaque blue
                    .clipShape(Circle())
                }
                
                TextField("Message...", text: $messageText)
                    .font(.system(size: 12)) // Readable font size
                    .foregroundColor(.black) // Dark text
                    .padding(.horizontal, 12)
                    .frame(height: 55) // 55px height
                    .background(Color.white) // Solid white background
                    .cornerRadius(27.5) // Half of height for rounded ends
                    .onSubmit {
                        sendMessage()
                    }
                    // Aggressive keyboard performance optimizations
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(true) // Disable heavy autocorrection
                    .disableAutocorrection(true) // Double disable for performance
                    .keyboardType(.default)
                    .submitLabel(.send)
                    // Reduce keyboard animation blocking
                    .animation(nil, value: messageText) // Disable text animations
                    .onTapGesture {} // Prevent gesture conflicts
                
                // Send button - 55px height, black with white border
                Button(action: {
                    sendMessage()
                }) {
                    Text("Send")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 70, height: 55)
                .background(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white, lineWidth: 2)
                )
                .cornerRadius(12)
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 5) // 5px from edges
        }
    }
    
    // MARK: - Chat Functions
    
    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let userMessage = messageText
        messageText = "" // Clear immediately for better UX

        // Add user message to chat immediately (no dispatch needed - already on main thread)
        chatMessages.append(ChatMessage(role: "user", content: userMessage))

        // Move heavy operations to background queue to prevent keyboard blocking
        DispatchQueue.global(qos: .userInitiated).async {
            // Use existing session ID or create a new one
            let xid: String
            if self.sessionXid == nil {
                xid = "exhibit-\(UUID().uuidString.prefix(8))"
                DispatchQueue.main.async {
                    self.sessionXid = xid
                }
            } else {
                xid = self.sessionXid!
            }

            // Update UI on main thread
            DispatchQueue.main.async {
                self.currentXid = xid
                self.isListening = true
                self.statusText = "Sending message..."
                // Close keyboard after UI updates to prevent blocking
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }

            // Perform heavy network operations on background thread
            let url = URL(string: "http://172.20.10.5:3000/talk")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10

            // Create payload on background thread (avoid main thread blocking)
            let messagesPayload = self.chatMessages.map { ["role": $0.role, "content": $0.content] }
            print("[chat] 💬 Sending \(messagesPayload.count) messages in conversation history")

            let payload = [
                "xid": xid,
                "text": userMessage,
                "messages": messagesPayload,
                "user": [
                    "id": "ios-user-42",
                    "selfies": [],
                    "aspectRatioString": "21:9",
                    "stepCount": self.stepCount,
                    "location": self.nearestCity,
                    "coordinates": self.currentLocation ?? "unknown"
                ]
            ] as [String: Any]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            } catch {
                print("Error serializing JSON: \(error)")
                DispatchQueue.main.async {
                    self.statusText = "Error sending message"
                    self.isListening = false
                }
                return
            }
            // Perform network request on background thread
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    print("Network error: \(error)")
                    DispatchQueue.main.async {
                        self.statusText = "Network error"
                        self.isListening = false
                    }
                    return
                }

                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    print("Response: \(responseString)")
                }
            }.resume()

            // Set up Firebase listeners on background thread
            self.setupFirebaseListeners(xid: xid)
        } // End of background dispatch block
    }
    
    private func setupFirebaseListeners(xid: String) {
        print("Setting up Firebase listeners for xid: \(xid)")
        let currentUserId = "ios-user-42" // Match the user ID we send in the API call
        
        // 1. Listen for chat history in /exhibits/{xid}/messages
        let messagesRef = database.child("exhibits").child(xid).child("messages")
        messagesRef.observe(.childAdded) { snapshot in
            guard let messageData = snapshot.value as? [String: Any],
                  let mode = messageData["mode"] as? String,
                  let message = messageData["message"] as? String else {
                print("Invalid message data: \(snapshot.value ?? "nil")")
                return
            }
            
            DispatchQueue.main.async {
                // Only add if we don't already have this message
                if !chatMessages.contains(where: { $0.content == message && $0.role == mode }) {
                    chatMessages.append(ChatMessage(role: mode, content: message))
                    print("Added \(mode) message: \(message)")
                }
            }
        }
        
        // 2. Listen for editObject changes for status + images
        let editObjectRef = database.child("exhibits").child(xid).child("editObject")
        editObjectRef.observe(.value) { snapshot in
            print("🔥 ChatView: Firebase editObject listener triggered")
            guard let editData = snapshot.value as? [String: Any],
                  let edits = editData["edits"] as? [[String: Any]] else {
                print("No edits found in editObject: \(snapshot.value ?? "nil")")
                return
            }
            
            // 3. Find our user's edit
            guard let userEdit = edits.first(where: { edit in
                (edit["userId"] as? String) == currentUserId
            }) else {
                print("No edit found for user: \(currentUserId)")
                return
            }
            
            DispatchQueue.main.async {
                // 4. Render status from edit.status
                if let status = userEdit["status"] as? String {
                    statusText = status
                    print("Status update: \(status)")
                }
                
                // 5. Render images from edit.item.layers[].url (only image layers, not audio)
                if let item = userEdit["item"] as? [String: Any],
                   let layers = item["layers"] as? [[String: Any]] {

                    print("🔥 ChatView: Processing \(layers.count) layers")

                    // Only process image layers, not audio layers
                    let newImageUrls = layers.compactMap { layer -> String? in
                        print("🔥 ChatView: Raw layer data: \(layer)")
                        guard let url = layer["url"] as? String else {
                            print("🔥 ChatView: Layer missing URL")
                            return nil
                        }

                        // Skip audio layers - they should be handled by LayerAudioEngine
                        let layerType = layer["type"] as? String ?? "image"
                        print("🔥 ChatView: Layer type detected: '\(layerType)' for URL: \(url)")

                        if layerType == "audio" || layerType == "music" {
                            print("🎵 ChatView: Skipping \(layerType) layer URL: \(url)")
                            return nil
                        }

                        // Verify it's actually an image file
                        let isImageFile = url.hasSuffix(".jpg") || url.hasSuffix(".jpeg") ||
                                        url.hasSuffix(".png") || url.hasSuffix(".gif") ||
                                        url.hasSuffix(".webp") || url.hasSuffix(".bmp") ||
                                        url.hasSuffix(".tiff") || url.hasSuffix(".svg")

                        if isImageFile {
                            print("🖼️ ChatView: Found image layer URL: \(url)")
                            return url
                        } else {
                            print("🚫 ChatView: Skipping non-image file for \(layerType) layer: \(url)")
                            return nil
                        }
                    }

                    // Add new images that we don't already have
                    for imageUrl in newImageUrls {
                        if !generatedImages.contains(imageUrl) {
                            print("🔥 ChatView: Adding image URL to generatedImages: \(imageUrl)")
                            generatedImages.append(imageUrl)
                            print("✅ ChatView: Added image URL: \(imageUrl)")
                        } else {
                            print("⚠️ ChatView: Image URL already exists: \(imageUrl)")
                        }
                    }
                }
                
                // Keep listening for ongoing conversations and new image generations
            }
        }
        
        print("Firebase listeners set up successfully")
    }
}
