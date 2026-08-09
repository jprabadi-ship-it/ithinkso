import Foundation
import StoreKit

/// 7日間無料トライアル → 買い切り（非消耗型IAP）のライセンス管理。
///
/// - トライアル: 初回起動日を UserDefaults に記録し、経過日数で判定。
///   コンテナ削除でリセットできてしまうが、この規模のアプリでは割り切る
/// - 購入: StoreKit 2。Transaction.currentEntitlements が真実の状態
/// - App Store Connect に商品（com.ithinkso.app.unlock / 非消耗型 / ¥500）を
///   登録するまで product は取得できない。UI は displayPrice が取れない間
///   フォールバック表記を出す
@MainActor
final class StoreManager: ObservableObject {

    static let productID = "com.ithinkso.app.unlock"
    static let trialDays = 7
    /// 商品情報が取れない間の表示用（App Store Connect 登録後は displayPrice が優先）
    static let fallbackPrice = "¥500"

    @Published private(set) var isPurchased = false
    @Published private(set) var trialDaysRemaining = StoreManager.trialDays
    @Published private(set) var product: Product?

    /// 開発機で購入済み扱いにするフラグ。
    /// 設定:   defaults write com.ithinkso.app ITSLicenseOverride "rabadi-dev"
    /// 解除:   defaults delete com.ithinkso.app ITSLicenseOverride
    /// クライアント側の判定はどのみち改変可能なので、これは利便性の仕掛けであって
    /// 保護機構ではない（トライアル起点の UserDefaults と同じ割り切り）
    var isDevUnlocked: Bool {
        UserDefaults.standard.string(forKey: "ITSLicenseOverride") == "rabadi-dev"
    }

    /// 機能を使ってよい状態か（開発フラグ or 購入済み or トライアル中）
    var isEntitled: Bool { isDevUnlocked || isPurchased || trialDaysRemaining > 0 }

    var displayPrice: String { product?.displayPrice ?? Self.fallbackPrice }

    /// 状態変化の通知先（AppState が keyMonitor の起動/停止に使う）
    var onEntitlementChange: (() -> Void)?

    private let firstLaunchKey = "ITSFirstLaunchDate"
    private var updatesTask: Task<Void, Never>?
    private var dailyTimer: Timer?

    init() {
        let ud = UserDefaults.standard
        if ud.object(forKey: firstLaunchKey) == nil {
            ud.set(Date(), forKey: firstLaunchKey)
        }
        refreshTrial()

        // 購入・返金・ファミリー共有などの変化を受け取る
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
        Task { [weak self] in
            await self?.refreshEntitlement()
            await self?.loadProduct()
        }

        // トライアル失効を跨いでも起動しっぱなしの常駐アプリなので、定期再評価する
        dailyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasEntitled = self.isEntitled
                self.refreshTrial()
                if wasEntitled != self.isEntitled {
                    self.onEntitlementChange?()
                }
            }
        }
    }

    private func refreshTrial() {
        let start = (UserDefaults.standard.object(forKey: firstLaunchKey) as? Date) ?? Date()
        let elapsed = Calendar.current.dateComponents([.day], from: start, to: Date()).day ?? 0
        trialDaysRemaining = max(0, Self.trialDays - elapsed)
    }

    private func refreshEntitlement() async {
        var purchased = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                purchased = true
            }
        }
        if purchased != isPurchased {
            isPurchased = purchased
            onEntitlementChange?()
        }
    }

    private func loadProduct() async {
        product = try? await Product.products(for: [Self.productID]).first
    }

    func purchase() {
        Task { [weak self] in
            guard let self else { return }
            if self.product == nil { await self.loadProduct() }
            guard let product = self.product else {
                itsLog.error("IAP 商品を取得できない（App Store Connect 未登録か通信不可）")
                return
            }
            do {
                let result = try await product.purchase()
                if case .success(let verification) = result,
                   case .verified(let transaction) = verification {
                    await transaction.finish()
                    await self.refreshEntitlement()
                }
            } catch {
                itsLog.error("購入フロー失敗: \(error)")
            }
        }
    }

    /// 別 Mac・再インストール時の復元（審査要件）
    func restore() {
        Task { [weak self] in
            try? await AppStore.sync()
            await self?.refreshEntitlement()
        }
    }
}
