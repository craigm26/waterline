import SwiftUI
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Automatically detects and Gaussian-blurs human faces on-device using Apple
/// Vision + CoreImage before any public camera snapshot is rendered.
/// Zero image data is uploaded anywhere.
actor FaceBlurProcessor {
    static let shared = FaceBlurProcessor()

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 80
    }

    func fetchAndBlur(url: URL) async -> (image: UIImage, blurredFaces: Int)? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            return (cached, 0)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rawImage = UIImage(data: data) else {
            return nil
        }

        let (processed, count) = blurFaces(in: rawImage)
        cache.setObject(processed, forKey: key)
        return (processed, count)
    }

    private func blurFaces(in image: UIImage) -> (UIImage, Int) {
        guard let cgImage = image.cgImage else { return (image, 0) }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return (image, 0)
        }

        guard let faces = request.results, !faces.isEmpty else {
            return (image, 0)
        }

        let ciInput = CIImage(cgImage: cgImage)
        let extent = ciInput.extent

        // Create a heavily blurred copy of the image, then composite only over
        // expanded face ellipses so the rest of the river/road stays sharp.
        let blurRadius = max(14.0, min(extent.width, extent.height) * 0.035)
        let blurred = ciInput
            .clampedToExtent()
            .applyingGaussianBlur(sigma: blurRadius)
            .cropped(to: extent)

        var mask: CIImage?
        for face in faces {
            let box = VNImageRectForNormalizedRect(face.boundingBox, Int(extent.width), Int(extent.height))
            let padX = box.width * 0.25
            let padY = box.height * 0.30
            let expanded = box.insetBy(dx: -padX, dy: -padY)
            let center = CIVector(x: expanded.midX, y: expanded.midY)
            let radius = max(expanded.width, expanded.height) * 0.55

            let radial = CIFilter.radialGradient()
            radial.center = CGPoint(x: center.x, y: center.y)
            radial.radius0 = Float(radius * 0.72)
            radial.radius1 = Float(radius)
            radial.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            radial.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let dot = radial.outputImage?.cropped(to: extent) else { continue }

            if let existing = mask {
                let comp = CIFilter.sourceOverCompositing()
                comp.inputImage = dot
                comp.backgroundImage = existing
                mask = comp.outputImage
            } else {
                mask = dot
            }
        }

        guard let finalMask = mask else { return (image, faces.count) }
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = blurred
        blend.backgroundImage = ciInput
        blend.maskImage = finalMask

        guard let output = blend.outputImage,
              let outCG = context.createCGImage(output, from: extent) else {
            return (image, faces.count)
        }
        return (UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation), faces.count)
    }
}

/// Drop-in SwiftUI view that fetches a camera snapshot and automatically
/// applies on-device Vision face blurring before displaying it.
struct PrivacyBlurredCameraImage: View {
    let url: URL
    var contentMode: ContentMode = .fill

    @State private var uiImage: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                ZStack {
                    Color(.tertiarySystemFill)
                    Image(systemName: "video.slash").foregroundStyle(.secondary)
                }
            } else {
                ZStack {
                    Color(.tertiarySystemFill)
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: url) {
            failed = false
            if let result = await FaceBlurProcessor.shared.fetchAndBlur(url: url) {
                uiImage = result.image
            } else {
                failed = true
            }
        }
    }
}
