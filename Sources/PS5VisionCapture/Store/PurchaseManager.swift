import Foundation
import StoreKit

/// What the free version allows. Everything else needs Couchport Pro.
enum FreeTier {
    /// Length of one free Remote Play session (streaming time only).
    static let sessionLimit: TimeInterval = 10 * 60
    /// The "time is almost up" prompt appears this long before the end.
    static let warningLead: TimeInterval = 60
    static let maxResolution = 720
    /// Bitrates a free user can pick, in kbps.
    static let bitrates: [Int] = [10_000, 15_000, 20_000]

    static func clampBitrate(_ kbps: Int) -> Int {
        kbps == 0 ? bitrates[0] : min(bitrates.last!, max(bitrates[0], kbps))
    }
}

/// Why the paywall opened. Changes the headline only.
enum PaywallReason: String, Identifiable {
    case browse, timeUp, capture, feature
    var id: String { rawValue }
}

/// StoreKit 2: one non-consumable, `com.glooby.UVCTheater.pro`.
@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()
    static let proProductID = "com.glooby.UVCTheater.pro"
    private static let cacheKey = "store.isPro"

    /// Cached across launches so a Pro user is never treated as free while
    /// StoreKit is still answering; corrected by `refreshEntitlements()`.
    @Published private(set) var isPro: Bool
    /// True once StoreKit has answered at least once this launch.
    @Published private(set) var hasCheckedEntitlements = false
    @Published private(set) var product: Product?
    @Published private(set) var isBusy = false
    @Published var message: String?

    /// Set to show the paywall. The main window presents it.
    @Published var paywallRequest: PaywallReason?

    private var updatesTask: Task<Void, Never>?

    private init() {
        isPro = UserDefaults.standard.bool(forKey: Self.cacheKey)
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        Task { await refresh() }
    }

    func requestPaywall(_ reason: PaywallReason = .browse) {
        message = nil
        paywallRequest = reason
    }

    /// For buttons inside a sheet: the caller closes its sheet, and the
    /// paywall opens once that dismissal has finished.
    func requestPaywallAfterSheet(_ reason: PaywallReason = .feature) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            requestPaywall(reason)
        }
    }

    func refresh() async {
        await loadProduct()
        await refreshEntitlements()
    }

    func loadProduct() async {
        guard product == nil else { return }
        do {
            product = try await Product.products(for: [Self.proProductID]).first
        } catch {
            message = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.proProductID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        setPro(owned)
        hasCheckedEntitlements = true
    }

    /// Handles the result of SwiftUI's `PurchaseAction` (the visionOS way
    /// to buy: it attaches the payment sheet to the current scene).
    func buy(with purchase: PurchaseAction) async {
        if product == nil { await loadProduct() }
        guard let product else {
            message = String(localized: "The App Store is not available right now. Try again later.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        message = nil
        do {
            switch try await purchase(product) {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    setPro(true)
                case .unverified:
                    message = String(localized: "The purchase could not be verified.")
                }
            case .pending:
                message = String(localized: "The purchase is waiting for approval.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        isBusy = true
        defer { isBusy = false }
        message = nil
        do {
            try await AppStore.sync()
        } catch {
            message = error.localizedDescription
        }
        await refreshEntitlements()
        if !isPro && message == nil {
            message = String(localized: "No previous purchase was found for this Apple Account.")
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if transaction.productID == Self.proProductID {
            setPro(transaction.revocationDate == nil)
        }
        await transaction.finish()
    }

    private func setPro(_ value: Bool) {
        if isPro != value { isPro = value }
        UserDefaults.standard.set(value, forKey: Self.cacheKey)
    }
}
