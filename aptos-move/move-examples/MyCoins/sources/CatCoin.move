module MyCoins::cat_coin {
    struct CatCoin {}

    fun init_module(sender: &signer) {
        aptos_framework::managed_coin::initialize<CatCoin>(
            sender,
            b"Cat Coin",
            b"CAT",
            6,
            false,
        );
    }

    public fun transfer(sender: &signer, recipient: address, amount: u64) {
        aptos_framework::coin::transfer<CatCoin>(sender, recipient, amount)
    }

    public entry fun mint(sender: &signer, recipient: address, amount: u64) {
        aptos_framework::managed_coin::mint<CatCoin>(sender, recipient, amount)
    }

    public entry fun burn(sender: &signer, amount: u64) {
        aptos_framework::managed_coin::burn<CatCoin>(sender, amount)
    }
}
