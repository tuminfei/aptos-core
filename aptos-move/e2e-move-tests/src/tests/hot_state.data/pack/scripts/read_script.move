script {
    use topo_framework::coin;
    use topo_framework::topo_coin::TopoCoin;

    /// Reads a plain resource under `target` (a data read) and framework coin state via
    /// `coin::supply` (whose module is an immediate dependency of this script). Nothing is
    /// written, so the read resource, the user module, and the script's framework module
    /// dependency must all be promoted to hot state.
    fun main(target: address) {
        0xcafe::read_helper::read_plain(target);
        let _ = coin::supply<TopoCoin>();
    }
}
