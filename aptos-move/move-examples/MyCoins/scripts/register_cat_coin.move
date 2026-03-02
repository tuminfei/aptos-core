script {
    fun register(account: &signer) {
        aptos_framework::managed_coin::register<MyCoins::cat_coin::CatCoin>(account)
    }
}
