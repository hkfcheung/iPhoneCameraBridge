import SwiftUI
import Combine
import Vision
import Contacts
import CoreML
import AVFoundation

// MARK: - Data types

private struct EnrolledFace {
    let name: String
    let embedding: [Float]
}

private struct FaceAnnotation {
    let rect: CGRect       // pixel coordinates in the image
    let name: String?
    let similarity: Float
}

/// Manages face detection (Vision), embedding (CoreML), contact enrollment, and matching.
///
/// **Setup required:** Add a CoreML face-embedding model (e.g. MobileFaceNet.mlmodel)
/// to the Xcode project. The model must accept a 112x112 (or 160x160) RGB image and
/// output a 1-D float array (embedding). Update `loadModel()` with the generated class name.
final class FaceRecognitionManager: ObservableObject {

    @Published var processedImage: UIImage?
    @Published var recognizedNames: [String] = []
    @Published var contactsAuthorized: Bool = false

    private let contactStore = CNContactStore()
    private var enrolledFaces: [EnrolledFace] = []
    private var model: VNCoreMLModel?
    private let matchThreshold: Float = 0.25
    private let processingQueue = DispatchQueue(label: "face.recognition", qos: .userInitiated)
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenName: String?
    private var lastSpokenTime: Date = .distantPast

    // MARK: - Init

    init() {
        configureAudioSession()
        loadModel()
        requestContactsAccess()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            print("[FaceRec] Audio session configured")
        } catch {
            print("[FaceRec] Audio session error: \(error.localizedDescription)")
        }
    }

    // MARK: - CoreML Model

    private func loadModel() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndGPU
            let mlModel = try MobileFaceNet(configuration: config).model
            model = try VNCoreMLModel(for: mlModel)
            print("[FaceRec] CoreML model loaded")
        } catch {
            print("[FaceRec] ERROR loading CoreML model: \(error.localizedDescription)")
        }
    }

    // MARK: - Contacts

    func requestContactsAccess() {
        contactStore.requestAccess(for: .contacts) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.contactsAuthorized = granted
            }
            if granted {
                self?.enrollContactFaces()
            } else if let error = error {
                print("[FaceRec] Contacts access denied: \(error.localizedDescription)")
            }
        }
    }

    private func enrollContactFaces() {
        processingQueue.async { [weak self] in
            guard let self = self, self.model != nil else { return }

            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactImageDataKey as CNKeyDescriptor,
                CNContactThumbnailImageDataKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var faces: [EnrolledFace] = []

            do {
                try self.contactStore.enumerateContacts(with: request) { contact, _ in
                    let name = [contact.givenName, contact.familyName]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    guard !name.isEmpty else { return }

                    // Prefer full-size photo for better face embeddings
                    let photoData = contact.imageData ?? contact.thumbnailImageData
                    guard let photoData = photoData,
                          let photo = UIImage(data: photoData) else { return }

                    let faceCount = self.detectFaces(in: photo)
                    print("[FaceRec] \(name): photo \(Int(photo.size.width))x\(Int(photo.size.height)), faces detected: \(faceCount.count)")

                    if faceCount.isEmpty {
                        print("[FaceRec] SKIPPING \(name) — no face detected in contact photo")
                        return
                    }

                    if let embedding = self.generateEmbedding(for: photo) {
                        faces.append(EnrolledFace(name: name, embedding: embedding))
                        print("[FaceRec] Enrolled: \(name)")
                    } else {
                        print("[FaceRec] SKIPPING \(name) — embedding generation failed")
                    }
                }
            } catch {
                print("[FaceRec] Error fetching contacts: \(error.localizedDescription)")
            }

            DispatchQueue.main.async {
                self.enrolledFaces = faces
                print("[FaceRec] Enrolled \(faces.count) contact face(s)")
            }
        }
    }

    // MARK: - Face Detection (Vision)

    private func detectFaces(in image: UIImage) -> [VNFaceObservation] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            return request.results ?? []
        } catch {
            print("[FaceRec] Face detection error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Face Embedding (CoreML)

    /// Generate embedding for a contact photo (detects face first, then crops)
    private func generateEmbedding(for image: UIImage) -> [Float]? {
        guard let cgImage = image.cgImage else { return nil }

        let faces = detectFaces(in: image)
        let faceRect: CGRect
        if let face = faces.first {
            let w = CGFloat(cgImage.width)
            let h = CGFloat(cgImage.height)
            faceRect = CGRect(
                x: face.boundingBox.origin.x * w,
                y: (1 - face.boundingBox.origin.y - face.boundingBox.height) * h,
                width: face.boundingBox.width * w,
                height: face.boundingBox.height * h
            ).integral
        } else {
            faceRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        }

        guard let croppedCG = cgImage.cropping(to: faceRect) else { return nil }
        return runEmbeddingModel(on: croppedCG)
    }

    /// Generate embedding for an already-cropped face image
    private func generateEmbeddingDirect(for faceImage: UIImage) -> [Float]? {
        guard let cgImage = faceImage.cgImage else { return nil }
        return runEmbeddingModel(on: cgImage)
    }

    /// Run the CoreML model on a CGImage and return the L2-normalized embedding
    private func runEmbeddingModel(on cgImage: CGImage) -> [Float]? {
        guard let model = model else { return nil }

        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("[FaceRec] Embedding request error: \(error.localizedDescription)")
            return nil
        }

        guard let results = request.results as? [VNCoreMLFeatureValueObservation],
              let multiArray = results.first?.featureValue.multiArrayValue else {
            return nil
        }

        let count = multiArray.count
        var vec = [Float](repeating: 0, count: count)
        for i in 0..<count {
            vec[i] = multiArray[i].floatValue
        }
        let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            vec = vec.map { $0 / norm }
        }
        return vec
    }

    // MARK: - Matching

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        return dot  // vectors are L2-normalized, so dot = cosine similarity
    }

    private func findMatch(for embedding: [Float]) -> (name: String, similarity: Float)? {
        var bestName: String?
        var bestSim: Float = -1

        for face in enrolledFaces {
            let sim = cosineSimilarity(embedding, face.embedding)
            if sim > bestSim {
                bestSim = sim
                bestName = face.name
            }
        }

        if let name = bestName, bestSim >= matchThreshold {
            return (name, bestSim)
        }
        return nil
    }

    // MARK: - Process Snapshot (public API)

    @Published var isProcessing: Bool = false

    func processSnapshot(_ image: UIImage) {
        // Show raw image immediately while processing runs in background
        DispatchQueue.main.async {
            self.processedImage = image
            self.recognizedNames = []
            self.isProcessing = true
        }

        processingQueue.async { [weak self] in
            guard let self = self else { return }

            let startTime = CFAbsoluteTimeGetCurrent()
            print("[FaceRec] processSnapshot called, image size: \(image.size)")

            let t0 = CFAbsoluteTimeGetCurrent()
            let faces = self.detectFaces(in: image)
            let t1 = CFAbsoluteTimeGetCurrent()
            print("[FaceRec] detected \(faces.count) face(s) in \(String(format: "%.0f", (t1-t0)*1000))ms")
            if faces.isEmpty {
                DispatchQueue.main.async {
                    self.processedImage = image
                    self.recognizedNames = []
                    self.isProcessing = false
                }
                return
            }

            guard let cgImage = image.cgImage else { return }
            let imageWidth = CGFloat(cgImage.width)
            let imageHeight = CGFloat(cgImage.height)

            // Build face rects
            var faceRects: [CGRect] = []
            for face in faces {
                faceRects.append(CGRect(
                    x: face.boundingBox.origin.x * imageWidth,
                    y: (1 - face.boundingBox.origin.y - face.boundingBox.height) * imageHeight,
                    width: face.boundingBox.width * imageWidth,
                    height: face.boundingBox.height * imageHeight
                ).integral)
            }

            // Show bounding boxes immediately (no names yet)
            let earlyAnnotations = faceRects.map {
                FaceAnnotation(rect: $0, name: nil, similarity: 0)
            }
            let earlyImage = self.drawAnnotations(on: image, annotations: earlyAnnotations)
            DispatchQueue.main.async {
                self.processedImage = earlyImage
            }

            let t2 = CFAbsoluteTimeGetCurrent()
            print("[FaceRec] bounding boxes shown in \(String(format: "%.0f", (t2-t0)*1000))ms")

            // Now run embedding + matching
            var names: [String] = []
            var annotations: [FaceAnnotation] = []

            for (i, pixelRect) in faceRects.enumerated() {
                var matchName: String?
                var matchSim: Float = 0

                if let croppedCG = cgImage.cropping(to: pixelRect),
                   self.model != nil {
                    let croppedImage = UIImage(cgImage: croppedCG)
                    if let embedding = self.generateEmbeddingDirect(for: croppedImage) {
                        if let match = self.findMatch(for: embedding) {
                            matchName = match.name
                            matchSim = match.similarity
                            names.append(match.name)
                        }
                        // Log top match
                        var bestName = "?"
                        var bestSim: Float = 0
                        for enrolled in self.enrolledFaces {
                            let sim = self.cosineSimilarity(embedding, enrolled.embedding)
                            if sim > bestSim { bestSim = sim; bestName = enrolled.name }
                        }
                        print("[FaceRec] face \(i): best=\(bestName) (\(String(format: "%.3f", bestSim)))")
                    }
                }

                annotations.append(FaceAnnotation(
                    rect: pixelRect, name: matchName, similarity: matchSim
                ))
            }

            let annotatedImage = self.drawAnnotations(on: image, annotations: annotations)
            let totalTime = CFAbsoluteTimeGetCurrent() - startTime
            print("[FaceRec] total processing: \(String(format: "%.0f", totalTime*1000))ms")

            DispatchQueue.main.async {
                self.processedImage = annotatedImage
                self.recognizedNames = names
                self.isProcessing = false
                if !names.isEmpty {
                    print("[FaceRec] Recognized: \(names.joined(separator: ", "))")
                    self.speakNames(names)
                }
            }
        }
    }

    // MARK: - Speech

    private func speakNames(_ names: [String]) {
        let combined = names.joined(separator: ", ")

        // Don't repeat the same name within 5 seconds
        if combined == lastSpokenName && Date().timeIntervalSince(lastSpokenTime) < 5 {
            return
        }

        lastSpokenName = combined
        lastSpokenTime = Date()

        // Stop any current speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: combined)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    // MARK: - Drawing

    private func drawAnnotations(on image: UIImage, annotations: [FaceAnnotation]) -> UIImage {
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            image.draw(at: .zero)
            let ctx = context.cgContext

            for ann in annotations {
                let hasMatch = ann.name != nil

                // Bounding box
                ctx.setStrokeColor(hasMatch ? UIColor.green.cgColor : UIColor.yellow.cgColor)
                ctx.setLineWidth(max(size.width / 200, 2))
                ctx.stroke(ann.rect)

                // Name label above the box
                if let name = ann.name {
                    let fontSize = max(size.width / 30, 14)
                    let font = UIFont.boldSystemFont(ofSize: fontSize)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: UIColor.white,
                        .backgroundColor: UIColor.black.withAlphaComponent(0.6)
                    ]
                    let textSize = (name as NSString).size(withAttributes: attrs)
                    let labelOrigin = CGPoint(
                        x: ann.rect.origin.x,
                        y: max(ann.rect.origin.y - textSize.height - 4, 0)
                    )
                    (name as NSString).draw(at: labelOrigin, withAttributes: attrs)
                }
            }
        }
    }
}
