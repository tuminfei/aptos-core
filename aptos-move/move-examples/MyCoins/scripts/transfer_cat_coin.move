script {
    use aptos_framework::coin;

    fun transfer(sender: &signer, recipient: address, amount: u64) {
        coin::transfer<MyCoins::cat_coin::CatCoin>(sender, recipient, amount)
    }
}
