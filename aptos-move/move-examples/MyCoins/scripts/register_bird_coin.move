script {
    fun register(account: &signer) {
        aptos_framework::managed_coin::register<MyCoins::bird_coin::BirdCoin>(account)
    }
}
