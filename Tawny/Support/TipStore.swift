import Foundation
import Observation
import StoreKit

/// Tips, as StoreKit 2 consumables. App Review Guideline 3.1.1: "Apps may use
/// in-app purchase currencies to enable customers to 'tip' the developer."
/// Nothing is unlocked by a tip, and nothing in Tawny is locked.
///
/// The three products are created in App Store Connect with exactly these
/// IDs, type Consumable (see README, "Tips").
@MainActor @Observable
final class TipStore {
    enum Phase: Equatable { case loading, ready([Product]), unavailable }

    static let productIDs = [
        "com.tawny.monitor.tip.small",
        "com.tawny.monitor.tip.medium",
        "com.tawny.monitor.tip.large",
    ]

    private(set) var phase: Phase = .loading
    /// Tips this Apple Account has left, counted from StoreKit's own history
    /// (consumables are listed there because of the
    /// SKIncludeConsumableInAppPurchaseHistory key in Info.plist).
    private(set) var tipCount = 0
    private(set) var justTipped = false
    /// Links to payment outside the App Store are allowed on the US storefront
    /// only (Guidelines 3.1.1(a) and 3.1.3). Everywhere else they stay hidden.
    private(set) var offersExternal = false

    func load() async {
        phase = .loading
        do {
            let products = try await Product.products(for: Self.productIDs)
            phase = products.isEmpty ? .unavailable : .ready(products.sorted { $0.price < $1.price })
        } catch {
            Diag.shared.log("store", "products failed: \(error.localizedDescription)")
            phase = .unavailable
        }
        offersExternal = await Storefront.current?.countryCode == "USA"
        await countTips()
    }

    func countTips() async {
        var n = 0
        for await result in Transaction.all {
            if case .verified(let t) = result, Self.productIDs.contains(t.productID), t.revocationDate == nil { n += 1 }
        }
        tipCount = n
    }

    func completed(_ result: Result<Product.PurchaseResult, Error>) async {
        switch result {
        case .success(.success(let verification)):
            if case .verified(let t) = verification {
                await t.finish()
                justTipped = true
                await countTips()
            }
        case .success(.pending):
            Diag.shared.log("store", "tip pending approval")
        case .success(.userCancelled), .success:
            break
        case .failure(let error):
            Diag.shared.log("store", "tip failed: \(error.localizedDescription)")
        }
    }
}
