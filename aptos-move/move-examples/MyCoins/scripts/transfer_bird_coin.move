script {
    use aptos_framework::coin;

    fun transfer_bird_coin(sender: &signer, recipient: address, amount: u64) {
        coin::transfer<0x0c0084b96923d3281d39c5a6561ac957fb9af07cc65132fc8806a89ec071b28b::bird_coin::BirdCoin>(sender, recipient, amount)
    }
}
