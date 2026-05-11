script {
    use topo_framework::managed_coin;
    use topo_framework::coin;

    fun transfer(sender: &signer, recipient: address, amount: u64) {
        managed_coin::transfer<DogCoin::dog_coin::DogCoin>(sender, recipient, amount)
    }
}
