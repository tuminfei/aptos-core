module MyCoins::bird_coin {
    struct BirdCoin {}

    fun init_module(sender: &signer) {
        aptos_framework::managed_coin::initialize<BirdCoin>(
            sender,
            b"Bird Coin",
            b"BIRD",
            6,
            false,
        );
    }

    public fun transfer(sender: &signer, recipient: address, amount: u64) {
        aptos_framework::managed_coin::transfer<BirdCoin>(sender, recipient, amount)
    }

    public fun mint(sender: &signer, recipient: address, amount: u64) {
        aptos_framework::managed_coin::mint<BirdCoin>(sender, recipient, amount)
    }

    public fun burn(sender: &signer, amount: u64) {
        aptos_framework::managed_coin::burn<BirdCoin>(sender, amount)
    }
}
