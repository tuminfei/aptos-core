module DogCoin::dog_coin {
    struct DogCoin {}

    fun init_module(sender: &signer) {
        topo_framework::managed_coin::initialize<DogCoin>(
            sender,
            b"Dog Coin",
            b"DOG",
            6,
            false,
        );
    }
}
