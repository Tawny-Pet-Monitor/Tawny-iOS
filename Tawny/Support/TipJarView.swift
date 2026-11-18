import SwiftUI
import StoreKit

/// Support Tawny: an honest note about what tips pay for, three tips through
/// the App Store, and (on the US storefront only) Ko-fi and Bitcoin.
struct TipJarView: View {
    @Environment(AppModel.self) private var model
    @State private var store = TipStore()

    var body: some View {
        List {
            Section {
                Text("Tawny is free, with nothing locked and no ads. Tips pay for the relay that connects your phones when you're away from home, and for the time that goes into each update.")
                    .foregroundStyle(Color.ink)
                    .padding(.vertical, 4)
            }

            Section {
                switch store.phase {
                case .loading:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading tips").foregroundStyle(Color.inkDim)
                    }
                    .frame(minHeight: 44)
                case .unavailable:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tips aren't available right now")
                            .font(.headline)
                            .foregroundStyle(Color.ink)
                        Text("The App Store didn't answer. Check your connection, then try again.")
                            .font(.subheadline)
                            .foregroundStyle(Color.inkDim)
                        Button("Try again") { Task { await store.load() } }
                            .frame(minHeight: 44)
                    }
                    .padding(.vertical, 4)
                case .ready(let products):
                    ForEach(products) { product in
                        ProductView(product) {
                            Image(systemName: symbol(for: product.id))
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 44, height: 44)
                                .background(Color.accentColor.opacity(0.12), in: .circle)
                        }
                        .productViewStyle(.compact)
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("Leave a tip")
            } footer: {
                Text("A one-time payment through the App Store. It doesn't renew.")
            }

            if store.tipCount > 0 || store.justTipped {
                Section {
                    Label {
                        Text(store.justTipped ? "Thank you. That really does keep the relay running."
                             : store.tipCount == 1 ? "You've left a tip before. Thank you."
                             : "You've left \(store.tipCount) tips. Thank you.")
                            .foregroundStyle(Color.ink)
                    } icon: {
                        Image(systemName: "heart.fill").foregroundStyle(Color.berry)
                    }
                    .padding(.vertical, 4)
                }
            }

            if store.offersExternal {
                Section {
                    Link(destination: Links.kofi) {
                        Label("Buy a coffee on Ko-fi", systemImage: "cup.and.saucer")
                    }
                    NavigationLink(value: Screen.lightning) {
                        Label("Tip in Bitcoin", systemImage: "bolt")
                    }
                } header: {
                    Text("Other ways to give")
                } footer: {
                    Text("These open outside the App Store, and go straight to the developer.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .tawnyListBackground()
        .navigationTitle("Support Tawny")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .onInAppPurchaseCompletion { _, result in await store.completed(result) }
        .sensoryFeedback(.success, trigger: store.justTipped)
    }

    private func symbol(for id: String) -> String {
        switch id {
        case "com.tawny.monitor.tip.small": "cup.and.saucer.fill"
        case "com.tawny.monitor.tip.medium": "pawprint.fill"
        default: "heart.fill"
        }
    }
}

/// A Lightning tip by hand-off: Tawny shows the address and opens the
/// person's own wallet. It never holds a key, a balance or an invoice of its
/// own, so it is not a wallet (Guideline 3.1.5). US storefront only.
struct LightningTipView: View {
    @Environment(\.openURL) private var openURL
    @State private var copied = false
    @State private var noWallet = false

    var body: some View {
        List {
            Section {
                Text("Send any amount of bitcoin over the Lightning Network. Your wallet pays the developer directly. Tawny never sees your money or your keys.")
                    .foregroundStyle(Color.ink)
                    .padding(.vertical, 4)
            }

            Section("Lightning address") {
                HStack {
                    Text(Links.lightningAddress)
                        .font(.body.monospaced())
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = Links.lightningAddress
                        copied = true
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .sensoryFeedback(.success, trigger: copied)
                }
                .frame(minHeight: 44)
            }

            Section {
                Button {
                    guard let url = URL(string: "lightning:\(Links.lightningAddress)") else { return }
                    openURL(url) { accepted in noWallet = !accepted }
                } label: {
                    Label("Open in my wallet", systemImage: "wallet.bifold")
                }
                Link(destination: Links.lightningWeb) {
                    Label("Pay on strike.me instead", systemImage: "safari")
                }
            } footer: {
                if noWallet {
                    Text("No Lightning wallet on this iPhone answered. Copy the address into the wallet you use, or pay on strike.me.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .tawnyListBackground()
        .navigationTitle("Tip in Bitcoin")
        .navigationBarTitleDisplayMode(.inline)
    }
}
