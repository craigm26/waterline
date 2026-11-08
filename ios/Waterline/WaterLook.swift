import UIKit
import RealityKit
import Metal

/// How water and its sense of scale look in 3D, for the iPhone camera and the Vision Pro room:
/// murky moving flood water, a staff gauge marked in feet, and a 5 ft 9 in person.
enum WaterLook {
    /// Flood water is murky, not pool blue: a brown-grey surface with soft streaks, tiled
    /// every 2.5 m and drifting slowly so it reads as moving water.
    static func material() -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.42, green: 0.37, blue: 0.27, alpha: 1))
        if let img = streaks(), let tex = try? TextureResource.generate(from: img, options: .init(semantic: .color)) {
            let d = MTLSamplerDescriptor()
            d.sAddressMode = .repeat; d.tAddressMode = .repeat
            d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
            // The tint darkens the streaks toward muddy brown, so a bright room doesn't turn it silver.
            m.baseColor = .init(tint: UIColor(red: 0.78, green: 0.68, blue: 0.5, alpha: 1), texture: .init(tex, sampler: .init(d)))
        }
        m.roughness = .init(floatLiteral: 0.15)
        m.metallic = .init(floatLiteral: 0.0)
        m.blending = .transparent(opacity: .init(floatLiteral: 0.78))
        m.textureCoordinateTransform.scale = SIMD2<Float>(12, 12)
        return m
    }

    /// A seamless 256 px tile: sums of whole-period waves, so its edges meet.
    private static func streaks() -> CGImage? {
        let n = 256
        var px = [UInt8](repeating: 255, count: n * n * 4)
        let tau = Float.pi * 2
        for y in 0..<n {
            for x in 0..<n {
                let u = Float(x) / Float(n), v = Float(y) / Float(n)
                var t = sin(tau * (3 * u + 2 * v)) * 0.5 + sin(tau * (5 * u - 3 * v) + 1.3) * 0.3
                t += sin(tau * (2 * u + 7 * v) + 2.1) * 0.25 + sin(tau * (9 * u + 4 * v) + 0.7) * 0.12
                let k = max(0, min(1, (t + 1.2) / 2.4))
                let hi = pow(k, 3)                       // a few bright ridges
                let i = (y * n + x) * 4
                px[i] = UInt8(min(255, 95 + 55 * k + 70 * hi))
                px[i + 1] = UInt8(min(255, 84 + 50 * k + 66 * hi))
                px[i + 2] = UInt8(min(255, 60 + 38 * k + 60 * hi))
            }
        }
        return px.withUnsafeMutableBytes { b in
            CGContext(data: b.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
    }

    /// A person 5 ft 9 in (1.75 m) tall, in plain grey blocks, standing on the ground.
    static func person() -> Entity {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: UIColor(white: 0.85, alpha: 1))
        mat.roughness = .init(floatLiteral: 0.8)
        mat.blending = .transparent(opacity: .init(floatLiteral: 0.92))
        let p = Entity()
        func part(_ mesh: MeshResource, _ at: SIMD3<Float>) {
            let e = ModelEntity(mesh: mesh, materials: [mat]); e.position = at; p.addChild(e)
        }
        part(.generateBox(size: SIMD3<Float>(0.13, 0.84, 0.15), cornerRadius: 0.05), SIMD3<Float>(-0.09, 0.42, 0))
        part(.generateBox(size: SIMD3<Float>(0.13, 0.84, 0.15), cornerRadius: 0.05), SIMD3<Float>(0.09, 0.42, 0))
        part(.generateBox(size: SIMD3<Float>(0.38, 0.62, 0.21), cornerRadius: 0.07), SIMD3<Float>(0, 1.15, 0))
        part(.generateBox(size: SIMD3<Float>(0.08, 0.6, 0.1), cornerRadius: 0.04), SIMD3<Float>(-0.25, 1.13, 0))
        part(.generateBox(size: SIMD3<Float>(0.08, 0.6, 0.1), cornerRadius: 0.04), SIMD3<Float>(0.25, 1.13, 0))
        part(.generateSphere(radius: 0.11), SIMD3<Float>(0, 1.62, 0))
        let tag = ModelEntity(mesh: .generateText("5 ft 9 in", extrusionDepth: 0.002, font: .systemFont(ofSize: 0.06)),
                              materials: [UnlitMaterial(color: .white)])
        tag.position = SIMD3<Float>(-0.14, 1.8, 0)
        p.addChild(tag)
        return p
    }

    /// A staff gauge: a white board marked every half foot, numbered every foot, tall enough
    /// to stand a foot over the water.
    static func ruler(feet: Int) -> Entity {
        let r = Entity()
        let ftM = Float(1 / Geo.ftPerM)
        let h = Float(feet) * ftM
        let board = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.06, h, 0.012)), materials: [UnlitMaterial(color: .white)])
        board.position = SIMD3<Float>(0, h / 2, 0)
        r.addChild(board)
        for k in 1...(feet * 2) {
            let y = Float(k) * ftM / 2, whole = k % 2 == 0
            let tick = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(whole ? 0.06 : 0.03, 0.008, 0.014)), materials: [UnlitMaterial(color: .black)])
            tick.position = SIMD3<Float>(whole ? 0 : -0.015, y, 0.001)
            r.addChild(tick)
            if whole {
                let t = ModelEntity(mesh: .generateText("\(k / 2) ft", extrusionDepth: 0.002, font: .boldSystemFont(ofSize: 0.05)),
                                    materials: [UnlitMaterial(color: .white)])
                t.position = SIMD3<Float>(0.045, y - 0.02, 0)
                r.addChild(t)
            }
        }
        return r
    }
}
