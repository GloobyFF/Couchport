import Metal
import QuartzCore

/// Reusable texture pool to reduce allocation overhead and memory fragmentation
/// at 60fps. Textures are keyed by (width, height, usage) and reused when
/// possible instead of creating new ones every frame.
final class MetalTexturePool {
    private let device: MTLDevice
    private let lock = NSLock()

    /// Pool entries indexed by descriptor hash. Each entry holds textures that
    /// are currently available for reuse.
    private var pool: [PoolKey: [MTLTexture]] = [:]

    /// Textures currently in use (checked out). Tracks them so we can reclaim
    /// on explicit flush or dealloc.
    private var inUse: Set<ObjectIdentifier> = []

    /// Maximum textures to keep per size/usage combination. Prevents unbounded
    /// growth if capture resolution keeps changing.
    private let maxTexturesPerKey = 3

    /// Idle timeout: textures unused for this duration are purged (seconds).
    private var lastAccessTime: [PoolKey: TimeInterval] = [:]
    private let idleTimeout: TimeInterval = 5.0

    init(device: MTLDevice) {
        self.device = device
    }

    struct PoolKey: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
        let usageRawValue: UInt  // MTLTextureUsage.rawValue for hashing

        init(width: Int, height: Int, pixelFormat: MTLPixelFormat, usage: MTLTextureUsage) {
            self.width = width
            self.height = height
            self.pixelFormat = pixelFormat
            self.usageRawValue = usage.rawValue
        }

        var usage: MTLTextureUsage {
            MTLTextureUsage(rawValue: usageRawValue)
        }
    }

    /// Retrieves a texture from the pool or creates a new one. The texture is
    /// marked as in-use and should be returned via `returnTexture` when done,
    /// or it will be reclaimed on the next purge cycle.
    func getTexture(width: Int, height: Int,
                    pixelFormat: MTLPixelFormat = .bgra8Unorm,
                    usage: MTLTextureUsage) -> MTLTexture? {
        let key = PoolKey(width: width, height: height,
                         pixelFormat: pixelFormat, usage: usage)

        lock.lock()
        defer { lock.unlock() }

        lastAccessTime[key] = CACurrentMediaTime()

        // Try to reuse an existing texture.
        if var available = pool[key], !available.isEmpty {
            let texture = available.removeLast()
            pool[key] = available
            inUse.insert(ObjectIdentifier(texture))
            return texture
        }

        // Create a new one.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height,
            mipmapped: false)
        desc.usage = usage
        desc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: desc) else {
            return nil
        }

        inUse.insert(ObjectIdentifier(texture))
        return texture
    }

    /// Returns a texture to the pool for future reuse. Idempotent (safe to
    /// call multiple times or with textures not from this pool).
    func returnTexture(_ texture: MTLTexture) {
        let key = PoolKey(width: texture.width, height: texture.height,
                         pixelFormat: texture.pixelFormat, usage: texture.usage)

        lock.lock()
        defer { lock.unlock() }

        let id = ObjectIdentifier(texture)
        guard inUse.remove(id) != nil else { return }

        var available = pool[key, default: []]
        guard available.count < maxTexturesPerKey else { return }
        available.append(texture)
        pool[key] = available
    }

    /// Purges textures that haven't been accessed in `idleTimeout` seconds.
    /// Call this periodically (e.g. once per second) to free memory when the
    /// user switches to a lower resolution or pauses capture.
    func purgeIdleTextures() {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        var keysToRemove: [PoolKey] = []

        for (key, lastAccess) in lastAccessTime {
            if now - lastAccess > idleTimeout {
                pool.removeValue(forKey: key)
                keysToRemove.append(key)
            }
        }

        for key in keysToRemove {
            lastAccessTime.removeValue(forKey: key)
        }
    }

    /// Immediately releases all pooled textures. Call when stopping capture or
    /// before a major resolution change.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        pool.removeAll()
        inUse.removeAll()
        lastAccessTime.removeAll()
    }
}
