script {
    fun register_bird_coin(account: &signer) {
        topo_framework::managed_coin::register<MyCoins::bird_coin::BirdCoin>(account)
    }
}
