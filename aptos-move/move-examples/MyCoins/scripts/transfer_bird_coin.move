script {
    use aptos_framework::managed_coin;

    fun transfer(sender: &signer, recipient: address, amount: u64) {
        managed_coin::transfer<MyCoins::bird_coin::BirdCoin>(sender, recipient, amount)
    }
}
