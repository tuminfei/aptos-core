// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use topo_framework::{path_in_crate, BuildOptions, BuiltPackage};

#[test]
fn topo_framework_package_metadata_uses_renamed_package_name() {
    let built = BuiltPackage::build(path_in_crate("topo-framework"), BuildOptions::default())
        .expect("topo-framework package should build");

    assert_eq!(built.name(), "TopoFramework");

    let metadata = built
        .extract_metadata()
        .expect("topo-framework metadata should extract");
    assert_eq!(metadata.name, "TopoFramework");
}
