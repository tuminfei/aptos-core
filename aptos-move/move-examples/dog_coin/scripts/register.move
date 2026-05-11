script {
    fun register(account: &signer) {
        topo_framework::managed_coin::register<DogCoin::dog_coin::DogCoin>(account)
    }
}
