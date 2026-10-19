import Foundation

// MARK: - What a route is sent for each attachment

/// What a route takes besides text.
public struct AttachmentRoute: Sendable, Equatable {
    /// Images (`image_url` parts, Bedrock image blocks).
    public var vision: Bool
    /// Native PDF documents (Bedrock document blocks).
    public var documents: Bool
    /// Image formats the route takes, by MIME type; nil = any.
    public var imageTypes: Set<String>?
    /// Per-message limits (Bedrock: 20 images of at most 3.75 MB, 5 documents of at most 4.5 MB).
    public var maxImages: Int?
    public var maxImageBytes: Int?
    public var maxDocuments: Int?
    public var maxDocumentBytes: Int?

    public init(vision: Bool, documents: Bool = false, imageTypes: Set<String>? = nil, maxImages: Int? = nil,
                maxImageBytes: Int? = nil, maxDocuments: Int? = nil, maxDocumentBytes: Int? = nil) {
        self.vision = vision
        self.documents = documents
        self.imageTypes = imageTypes
        self.maxImages = maxImages
        self.maxImageBytes = maxImageBytes
        self.maxDocuments = maxDocuments
        self.maxDocumentBytes = maxDocumentBytes
    }

    public static let textOnly = AttachmentRoute(vision: false)

    /// An OpenAI-compatible route (self-hosted servers, hosted APIs, Guardian): images when the model takes them
    /// (the route's setting, unless its server already turned one down), never a file part.
    /// A model its provider says reads text only (Z.ai's GLM text models) gets no images whatever the route says.
    public static func openAI(_ profile: ProviderProfile, model: String? = nil) -> AttachmentRoute {
        let rejected = VisionRejections.shared.rejected(VisionRejections.key(profile, model: model))
        let rules = ModelRequestRules.for(profile, model: model ?? profile.model)
        let takesImages = rules.acceptsImages != false && !rules.textOnlyContent
        return AttachmentRoute(vision: (profile.vision ?? true) && takesImages && !rejected)
    }

    /// A Bedrock route: Converse's image formats and limits, and PDF documents when the model reads them.
    public static func bedrock(_ profile: ProviderProfile, traits: BedrockModelTraits) -> AttachmentRoute {
        AttachmentRoute(vision: profile.vision ?? true, documents: traits.documents,
                        imageTypes: ["image/png", "image/jpeg", "image/gif", "image/webp"],
                        maxImages: 20, maxImageBytes: 3_750_000, maxDocuments: 5, maxDocumentBytes: 4_500_000)
    }

    /// Anthropic's own API: the same four image formats, PDFs as document blocks, and the Messages API's limits
    /// (5 MB an image, a 32 MB request — documents are kept well under it, base64 being a third larger).
    public static func anthropic(_ profile: ProviderProfile, traits: BedrockModelTraits) -> AttachmentRoute {
        AttachmentRoute(vision: profile.vision ?? true, documents: traits.documents,
                        imageTypes: ["image/png", "image/jpeg", "image/gif", "image/webp"],
                        maxImages: 20, maxImageBytes: 5_000_000, maxDocuments: 5, maxDocumentBytes: 15_000_000)
    }

    /// The route a profile is served on.
    public static func of(_ profile: ProviderProfile) -> AttachmentRoute {
        switch profile.kind {
        case .bedrock: bedrock(profile, traits: BedrockModels.traits(profile.model))
        case .anthropic: anthropic(profile, traits: BedrockModels.traits(profile.model))
        default: openAI(profile)
        }
    }
}

/// How one attachment goes to the model — what the composer chip says after the file's summary.
public enum AttachmentDelivery: Sendable, Equatable {
    case image
    case ocrText
    case document
    case pageImages(Int)
    case text
    case textInParts(Int)
    case nameOnly

    /// "sent as text", "sent as text in 13 parts", … (pinned wording, the same on Windows).
    public var label: String {
        switch self {
        case .image: "sent as image"
        case .ocrText: "sent as text (OCR)"
        case .document: "sent as PDF document"
        case .pageImages(let n): n == 1 ? "sent as 1 page image" : "sent as \(AttachmentText.grouped(n)) page images"
        case .text: "sent as text"
        case .textInParts(let n): "sent as text in \(AttachmentText.grouped(n)) parts"
        case .nameOnly: "can't be read — name only"
        }
    }
}

/// One piece of a user message on the wire.
public enum AttachmentWirePart: Sendable, Equatable {
    case text(String)
    case image(mime: String, data: Data)
    case document(name: String, data: Data)
}

public enum AttachmentWire {
    /// How `attachment` goes on `route`. `parts` overrides the attachment's own count (the composer, before the
    /// message is prepared).
    public static func delivery(_ attachment: MessageAttachment, route: AttachmentRoute, parts: Int? = nil) -> AttachmentDelivery {
        switch attachment.kind {
        case .image:
            if route.vision, route.imageTypes.map({ $0.contains(attachment.mime) }) ?? true { return .image }
            return .ocrText
        case .file:
            guard let digest = attachment.digest else {
                // Read by nobody (an older caller): a PDF goes as a document where the route takes one, text as text.
                if attachment.mime == "application/pdf" { return route.documents ? .document : .nameOnly }
                return AttachmentReader.decodeText(attachment.data, lenient: false) == nil ? .nameOnly : .text
            }
            let count = parts ?? attachment.parts ?? 1
            if digest.format == .pdf, digest.problem == nil {
                if digest.scanned, route.vision, !digest.pageImages.isEmpty { return .pageImages(digest.pageImages.count) }
                if route.documents, !digest.scanned, count == 1, !attachment.data.isEmpty,
                   attachment.data.count <= (route.maxDocumentBytes ?? .max) {
                    return .document
                }
            }
            guard digest.readable else { return .nameOnly }
            return count > 1 ? .textInParts(count) : .text
        }
    }

    /// The wire pieces for a user message's attachments, in order, within the route's per-message limits (past
    /// them, a picture or document goes as its text instead).
    public static func parts(for attachments: [MessageAttachment], route: AttachmentRoute) -> [AttachmentWirePart] {
        var out: [AttachmentWirePart] = []
        var images = 0, documents = 0
        func imageFits(_ data: Data) -> Bool {
            images < (route.maxImages ?? .max) && data.count <= (route.maxImageBytes ?? .max)
        }
        for attachment in attachments {
            switch delivery(attachment, route: route) {
            case .image:
                if imageFits(attachment.data) {
                    out.append(.image(mime: attachment.mime, data: attachment.data))
                    images += 1
                } else {
                    out.append(.text(fallbackText(attachment)))
                }
            case .ocrText:
                out.append(.text(fallbackText(attachment)))
            case .document:
                if documents < (route.maxDocuments ?? .max) {
                    out.append(.document(name: attachment.name, data: attachment.data))
                    documents += 1
                } else {
                    out.append(.text(fallbackText(attachment)))
                }
            case .pageImages:
                let digest = attachment.digest!
                let room = max(0, (route.maxImages ?? .max) - images)
                let pages = digest.pageImages.prefix(room).filter { $0.count <= (route.maxImageBytes ?? .max) }
                guard !pages.isEmpty else { out.append(.text(fallbackText(attachment))); continue }
                let total = digest.pages ?? pages.count
                var head = "[Attached file: \(attachment.name) — \(digest.summary) — it has no text layer, so "
                head += pages.count == total ? "its pages follow as images]" : "its first \(pages.count) of \(total) pages follow as images]"
                out.append(.text(head))
                for page in pages { out.append(.image(mime: "image/png", data: page)) }
                images += pages.count
                // Pages past the images: what OCR read from the whole file.
                if pages.count < total, digest.ocr { out.append(.text(fallbackText(attachment))) }
            case .text, .textInParts, .nameOnly:
                out.append(.text(fallbackText(attachment)))
            }
        }
        return out
    }

    /// The text sent in an attachment's place: what preparing it produced, else what can be made of it now.
    public static func fallbackText(_ attachment: MessageAttachment) -> String {
        if let text = attachment.text { return text }
        if let digest = attachment.digest {
            if attachment.kind == .image { return AttachmentReader.imageText(name: attachment.name, ocrText: digest.text) }
            return AttachmentPrep.inlineText(name: attachment.name, digest: digest,
                                             budget: AttachmentBudget(window: 1_000_000), readable: nil).text
        }
        // Nobody read it: its bytes when they are text (never a PDF's), else a note.
        if attachment.mime != "application/pdf", let text = AttachmentReader.decodeText(attachment.data, lenient: false) {
            return "[Attached file: \(attachment.name)]\n\(text)"
        }
        return "[Attached file: \(attachment.name) (\(attachment.data.count) bytes of binary data, not shown)]"
    }
}

// MARK: - Servers that turned down an image

/// Routes (base URL + model) whose server answered an image with an error saying it takes none — learned once, so
/// later requests send the image's OCR text instead of failing again. Pinned bodies: llama.cpp "image input is not
/// supported - hint: if this is unexpected, you may need to provide the mmproj"; vLLM "Resolving modality {'image'}
/// requires a multimodal processor but none is available." and (older) "At most 0 image(s) may be provided in one
/// prompt."
public final class VisionRejections: @unchecked Sendable {
    public static let shared = VisionRejections()
    private let lock = NSLock()
    private var routes: Set<String> = []

    public static func key(_ profile: ProviderProfile, model: String? = nil) -> String {
        "\(profile.baseURL)|\((model?.isEmpty ?? true) ? profile.model : model!)"
    }

    public func rejected(_ key: String) -> Bool { lock.withLock { routes.contains(key) } }
    public func learn(_ key: String) { lock.withLock { _ = routes.insert(key) } }
    public func reset() { lock.withLock { routes.removeAll() } }

    /// Whether an error body says the model takes no images.
    public static func saysNoImages(_ body: String) -> Bool {
        let lower = body.lowercased()
        let phrases = [
            "image input is not supported", "requires a multimodal processor", "at most 0 image",
            "does not support image", "doesn't support image", "do not support image", "not support images",
            "images are not supported", "image inputs are not supported", "is not a multimodal model",
            "does not support vision", "vision is not supported", "multimodal input is not supported",
            "model does not support multimodal",
        ]
        return phrases.contains { lower.contains($0) }
    }
}
