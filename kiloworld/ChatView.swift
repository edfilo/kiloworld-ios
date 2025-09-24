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
    
    var body: some View {
        HStack {
            Spacer()
            
            Text(message.content)
                .font(.system(size: 12)) // Minimum readable size
                .padding(6) // Compact padding
                .background(Color.black) // Solid black background
                .foregroundColor(.white)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.4), lineWidth: 1) // Thin border
                )
                .frame(maxWidth: UIScreen.main.bounds.width * 0.5) // Max half screen width
        }
        .padding(.trailing, 5) // 5px from right edge
        .padding(.leading, 50) // Space from left edge
    }
}

struct ChatView: View {
    @Binding var messageText: String
    @Binding var chatMessages: [ChatMessage]
    @Binding var statusText: String
    @Binding var isListening: Bool
    @Binding var sessionXid: String?
    @Binding var currentXid: String?
    @Binding var generatedImages: [String]
    
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
            /* COMMENTED OUT - Chat bubbles replaced with typewriter display
            // Chat messages with bottom-aligned layout
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    ZStack {
                        // Background layer - passes touches to map
                        Rectangle()
                            .fill(Color.clear)
                            .allowsHitTesting(false) // Transparent to map touches
                        
                        // Scrollable messages - only bubble area captures touches
                        ScrollView {
                            VStack(spacing: 4) {
                                // Calculate spacer height to push messages to bottom
                                let contentHeight = CGFloat(chatMessages.count * 40) // Approximate message height
                                let availableHeight = geometry.size.height - 8 // Account for padding
                                let spacerHeight = max(0, availableHeight - contentHeight)
                                
                                Spacer()
                                    .frame(height: spacerHeight)
                                    .allowsHitTesting(false) // Let touches pass through to map
                                
                                // Messages stack from bottom up - only these capture scroll touches
                                LazyVStack(spacing: 4) {
                                    ForEach(chatMessages) { message in
                                        ChatBubble(message: message)
                                            .id(message.id)
                                    }
                                }
                                .allowsHitTesting(true) // Only message bubbles capture touches for scrolling
                            }
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4) // Space above input controls
                            .frame(minHeight: geometry.size.height, alignment: .bottom)
                        }
                        .allowsHitTesting(false) // ScrollView itself doesn't capture touches
                        .overlay(
                            // Invisible overlay just over message area for scrolling
                            VStack {
                                Spacer()
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(height: min(CGFloat(chatMessages.count * 44), geometry.size.height - 60)) // Only message height
                                    .allowsHitTesting(chatMessages.count > 2) // Only when scrolling needed
                                Spacer().frame(height: 60) // Leave space for input controls
                            }
                        )
                    }
                }
                .allowsHitTesting(false) // GeometryReader doesn't need to capture touches
                .onChange(of: chatMessages.count) { _, _ in
                    // Auto-scroll to latest message when new message added
                    if let lastMessage = chatMessages.last {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    // Scroll to latest message on appear
                    if let lastMessage = chatMessages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
            */
            
            // Spacer to replace chat message area
            Spacer()
                .onAppear {
                    // Notify parent of latest AI message on appear
                    onLatestMessageChanged?(latestAIMessage)
                }
                .onChange(of: chatMessages) { _, _ in
                    // Notify parent when messages change
                    onLatestMessageChanged?(latestAIMessage)
                }
            
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
                
                // Send button - 55px height, beautiful magenta rectangle
                Button(action: {
                    sendMessage()
                }) {
                    Text("Send")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 70, height: 55)
                .background(Color(red: 1.0, green: 0.0, blue: 1.0)) // Beautiful magenta
                .cornerRadius(12) // Rounded rectangle
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 5) // 5px from edges
            .padding(.bottom, 5) // 5px from bottom
        }
    }
    
    // MARK: - Chat Functions
    
    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        // Close keyboard when sending message
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        let userMessage = messageText
        
        // Use existing session ID or create a new one
        if sessionXid == nil {
            sessionXid = "exhibit-\(UUID().uuidString.prefix(8))"
        }
        let xid = sessionXid!
        
        // Add user message to chat
        DispatchQueue.main.async {
            chatMessages.append(ChatMessage(role: "user", content: userMessage))
        }
        messageText = ""
        
        // Start Firebase listeners
        currentXid = xid
        isListening = true
        statusText = "Sending message..."
        
        //"http://192.168.40.34:3000/talk"
        let url = URL(string: "http://172.20.10.5:3000/talk")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        
        let payload = [
            "xid": xid,
            "text": userMessage,
            "messages": [["role": "user", "content": userMessage]],
            "user": [
                "id": "ios-user-42",
                "selfies": [],
                "aspectRatioString": "21:9"
            ]
        ] as [String: Any]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            print("Error serializing JSON: \(error)")
            statusText = "Error sending message"
            isListening = false
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Network error: \(error)")
                DispatchQueue.main.async {
                    statusText = "Network error"
                    isListening = false
                }
                return
            }
            
            if let data = data, let responseString = String(data: data, encoding: .utf8) {
                print("Response: \(responseString)")
            }
        }.resume()
        
        // Set up Firebase listeners
        setupFirebaseListeners(xid: xid)
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
                
                // 5. Render images from edit.item.layers[].url
                if let item = userEdit["item"] as? [String: Any],
                   let layers = item["layers"] as? [[String: Any]] {
                    
                    let newImageUrls = layers.compactMap { $0["url"] as? String }
                    
                    // Add new images that we don't already have
                    for imageUrl in newImageUrls {
                        if !generatedImages.contains(imageUrl) {
                            generatedImages.append(imageUrl)
                            print("Added image URL: \(imageUrl)")
                        }
                    }
                }
                
                // Keep listening for ongoing conversations and new image generations
            }
        }
        
        print("Firebase listeners set up successfully")
    }
}
