script {
    fun register_cat_coin(account: &signer) {
        topo_framework::managed_coin::register<MyCoins::cat_coin::CatCoin>(account)
    }
}
