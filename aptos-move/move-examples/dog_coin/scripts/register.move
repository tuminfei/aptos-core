script {
    fun register(account: &signer) {
        aptos_framework::managed_coin::register<DogCoin::dog_coin::DogCoin>(account)
    }
}
