script {
    use aptos_framework::managed_coin;
    use aptos_framework::coin;

    fun transfer(sender: &signer, recipient: address, amount: u64) {
        managed_coin::transfer<DogCoin::dog_coin::DogCoin>(sender, recipient, amount)
    }
}
