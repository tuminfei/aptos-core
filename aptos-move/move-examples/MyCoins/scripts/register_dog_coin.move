script {
    fun register_dog_coin(account: &signer) {
        aptos_framework::managed_coin::register<MyCoins::dog_coin::DogCoin>(account)
    }
}
