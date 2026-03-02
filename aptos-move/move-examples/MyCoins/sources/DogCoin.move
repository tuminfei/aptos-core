module MyCoins::dog_coin {
    struct DogCoin {}

    fun init_module(sender: &signer) {
        aptos_framework::managed_coin::initialize<DogCoin>(
            sender,
            b"Dog Coin",
            b"DOG",
            6,
            false,
        );
    }

    public fun transfer(sender: &signer, recipient: address, amount: u64) {
        aptos_framework::coin::transfer<DogCoin>(sender, recipient, amount)
    }

    public entry fun mint(sender: &signer, recipient: address, amount: u64) {
        aptos_framework::managed_coin::mint<DogCoin>(sender, recipient, amount)
    }

    public entry fun burn(sender: &signer, amount: u64) {
        aptos_framework::managed_coin::burn<DogCoin>(sender, amount)
    }
}
