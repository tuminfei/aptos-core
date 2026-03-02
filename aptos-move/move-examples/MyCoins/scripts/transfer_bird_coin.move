script {
    use aptos_framework::coin;

    fun transfer_bird_coin(sender: &signer, recipient: address, amount: u64) {
        coin::transfer<MyCoins::bird_coin::BirdCoin>(sender, recipient, amount)
    }
}
