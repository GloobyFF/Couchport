import Foundation

/// Detailed errors for Metal renderer initialization and runtime failures.
/// Replaces silent `nil` returns with actionable diagnostics.
enum MetalRendererError: LocalizedError {
    case deviceUnavailable
    case commandQueueCreationFailed
    case shaderLibraryNotFound
    case shaderFunctionNotFound(String)
    case pipelineCompilationFailed(function: String, underlying: Error)
    case textureCacheCreationFailed
    case textureCreationFailed(width: Int, height: Int, format: String)
    case blitEncoderCreationFailed
    case drawableAcquisitionFailed

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "Metal is unavailable on this device. Vision Pro requires Metal support."
        case .commandQueueCreationFailed:
            return "Failed to create Metal command queue. GPU may be unavailable."
        case .shaderLibraryNotFound:
            return "Could not load the Metal shader library. The app bundle may be corrupted."
        case .shaderFunctionNotFound(let name):
            return "Shader function '\(name)' not found in the Metal library."
        case .pipelineCompilationFailed(let function, let error):
            return "Failed to compile Metal pipeline for '\(function)': \(error.localizedDescription)"
        case .textureCacheCreationFailed:
            return "Failed to create CVMetalTextureCache. Memory may be exhausted."
        case .textureCreationFailed(let width, let height, let format):
            return "Failed to create \(width)×\(height) texture (format: \(format)). GPU memory may be full."
        case .blitEncoderCreationFailed:
            return "Failed to create blit command encoder. GPU command buffer may be full."
        case .drawableAcquisitionFailed:
            return "Failed to acquire next drawable from CAMetalLayer. Display system may be overloaded."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .deviceUnavailable:
            return "Ensure you are running on a real Vision Pro device, not the Simulator."
        case .commandQueueCreationFailed, .textureCacheCreationFailed:
            return "Try restarting the app. If the issue persists, restart the device."
        case .shaderLibraryNotFound, .shaderFunctionNotFound:
            return "Reinstall the app. The shader bundle may be corrupted."
        case .pipelineCompilationFailed:
            return "This is likely a shader compilation bug. Report to the developer with device info."
        case .textureCreationFailed:
            return "Try lowering the capture resolution or closing other GPU-intensive apps."
        case .blitEncoderCreationFailed, .drawableAcquisitionFailed:
            return "GPU command buffer is full. This usually resolves itself; if not, restart the app."
        }
    }
}
