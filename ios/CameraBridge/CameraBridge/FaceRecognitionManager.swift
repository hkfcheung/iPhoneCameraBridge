import SwiftUI
import Combine
import Vision
import Contacts
import CoreML

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
    private let matchThreshold: Float = 0.55
    private let processingQueue = DispatchQueue(label: "face.recognition", qos: .userInitiated)

    // MARK: - Init

    init() {
        loadModel()
        requestContactsAccess()
    }

    // MARK: - CoreML Model

    private func loadModel() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
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
                CNContactThumbnailImageDataKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var faces: [EnrolledFace] = []

            do {
                try self.contactStore.enumerateContacts(with: request) { contact, _ in
                    guard let photoData = contact.thumbnailImageData,
                          let photo = UIImage(data: photoData) else { return }

                    let name = [contact.givenName, contact.familyName]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    guard !name.isEmpty else { return }

                    if let embedding = self.generateEmbedding(for: photo) {
                        faces.append(EnrolledFace(name: name, embedding: embedding))
                        print("[FaceRec] Enrolled: \(name)")
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

        var embedding: [Float]?
        let semaphore = DispatchSemaphore(value: 0)

        let request = VNCoreMLRequest(model: model) { req, error in
            defer { semaphore.signal() }
            if let error = error {
                print("[FaceRec] CoreML error: \(error.localizedDescription)")
                return
            }
            if let results = req.results as? [VNCoreMLFeatureValueObservation],
               let multiArray = results.first?.featureValue.multiArrayValue {
                let count = multiArray.count
                var vec = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    vec[i] = multiArray[i].floatValue
                }
                let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
                if norm > 0 {
                    vec = vec.map { $0 / norm }
                }
                embedding = vec
            }
        }
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("[FaceRec] Embedding request error: \(error.localizedDescription)")
            semaphore.signal()
        }
        semaphore.wait()

        return embedding
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

    func processSnapshot(_ image: UIImage) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            print("[FaceRec] processSnapshot called, image size: \(image.size)")

            let faces = self.detectFaces(in: image)
            print("[FaceRec] detected \(faces.count) face(s)")
            if faces.isEmpty {
                DispatchQueue.main.async {
                    self.processedImage = image
                    self.recognizedNames = []
                }
                return
            }

            guard let cgImage = image.cgImage else { return }
            let imageWidth = CGFloat(cgImage.width)
            let imageHeight = CGFloat(cgImage.height)

            var names: [String] = []
            var annotations: [FaceAnnotation] = []

            for (i, face) in faces.enumerated() {
                let pixelRect = CGRect(
                    x: face.boundingBox.origin.x * imageWidth,
                    y: (1 - face.boundingBox.origin.y - face.boundingBox.height) * imageHeight,
                    width: face.boundingBox.width * imageWidth,
                    height: face.boundingBox.height * imageHeight
                ).integral
                print("[FaceRec] face \(i): rect=\(pixelRect)")

                var matchName: String?
                var matchSim: Float = 0

                if let croppedCG = cgImage.cropping(to: pixelRect),
                   self.model != nil {
                    let croppedImage = UIImage(cgImage: croppedCG)
                    if let embedding = self.generateEmbeddingDirect(for: croppedImage) {
                        print("[FaceRec] face \(i): embedding generated (\(embedding.count) dims)")
                        // Log top 3 matches
                        var topMatches: [(String, Float)] = []
                        for enrolled in self.enrolledFaces {
                            let sim = self.cosineSimilarity(embedding, enrolled.embedding)
                            topMatches.append((enrolled.name, sim))
                        }
                        topMatches.sort { $0.1 > $1.1 }
                        for m in topMatches.prefix(3) {
                            print("[FaceRec]   \(m.0): \(String(format: "%.3f", m.1))")
                        }

                        if let match = self.findMatch(for: embedding) {
                            matchName = match.name
                            matchSim = match.similarity
                            names.append(match.name)
                        } else {
                            print("[FaceRec] face \(i): no match above threshold \(self.matchThreshold)")
                        }
                    } else {
                        print("[FaceRec] face \(i): embedding generation FAILED")
                    }
                } else {
                    print("[FaceRec] face \(i): crop failed or model nil")
                }

                annotations.append(FaceAnnotation(
                    rect: pixelRect, name: matchName, similarity: matchSim
                ))
            }

            let annotatedImage = self.drawAnnotations(on: image, annotations: annotations)

            DispatchQueue.main.async {
                self.processedImage = annotatedImage
                self.recognizedNames = names
                if !names.isEmpty {
                    print("[FaceRec] Recognized: \(names.joined(separator: ", "))")
                }
            }
        }
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
