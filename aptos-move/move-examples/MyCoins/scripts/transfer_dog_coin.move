script {
    use aptos_framework::coin;

    fun transfer_dog_coin(sender: &signer, recipient: address, amount: u64) {
        coin::transfer<MyCoins::dog_coin::DogCoin>(sender, recipient, amount)
    }
}
