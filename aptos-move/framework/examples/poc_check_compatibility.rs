// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! 只读比较两份框架产物的升级兼容性，不发布模块或修改输入文件。
//! cargo run -p topo-framework --example poc_check_compatibility -- OLD.mrb NEW.mrb
//! 任一输入也可为单个编译模块（.mv），用于核对已有源码但未收录到旧 bundle 的历史模块。

use anyhow::{bail, Context, Result};
use aptos_release_bundle::ReleaseBundle;
use move_binary_format::{compatibility::Compatibility, CompiledModule};
use move_core_types::language_storage::ModuleId;
use std::{collections::BTreeMap, env, fs, path::PathBuf};

/// 统一读取 bundle 或单模块，拒绝同一 bundle 中重复的模块标识。
fn read_modules(path: PathBuf) -> Result<BTreeMap<ModuleId, CompiledModule>> {
    if path.extension().is_some_and(|extension| extension == "mv") {
        let bytes = fs::read(&path).with_context(|| format!("reading {}", path.display()))?;
        let module = CompiledModule::deserialize(&bytes)
            .with_context(|| format!("deserializing {}", path.display()))?;
        return Ok(BTreeMap::from([(module.self_id(), module)]));
    }
    let bundle =
        ReleaseBundle::read(path.clone()).with_context(|| format!("reading {}", path.display()))?;
    let mut modules = BTreeMap::new();
    for bytecode in bundle.code() {
        let module = CompiledModule::deserialize(bytecode)
            .with_context(|| format!("deserializing a module in {}", path.display()))?;
        let id = module.self_id();
        if modules.insert(id.clone(), module).is_some() {
            bail!("duplicate module {id} in {}", path.display());
        }
    }
    Ok(modules)
}

fn main() -> Result<()> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.len() != 2 {
        bail!("usage: poc_check_compatibility OLD.mrb|OLD.mv NEW.mrb|NEW.mv");
    }
    let old = read_modules(PathBuf::from(&args[0]))?;
    let new = read_modules(PathBuf::from(&args[1]))?;
    let mut checked = 0;
    let mut missing = 0;
    let mut incompatible = 0;
    // 逐个旧模块检查公开、friend、entry 链接及结构布局；新模块单独计数。
    for (id, previous) in &old {
        match new.get(id) {
            None => {
                missing += 1;
                eprintln!("missing: {id}");
            },
            Some(current) => {
                checked += 1;
                if let Err(error) = Compatibility::full_check().check(previous, current) {
                    incompatible += 1;
                    eprintln!("incompatible: {id}: {error:?}");
                }
            },
        }
    }
    let added = new.keys().filter(|id| !old.contains_key(*id)).count();
    println!(
        "checked={checked} new={added} missing={missing} incompatible={incompatible} \
         old_total={} new_total={} checks=public-linking,friend-linking,entry-linking,struct-layout",
        old.len(),
        new.len(),
    );
    if missing != 0 || incompatible != 0 {
        bail!("release bundle compatibility failed");
    }
    Ok(())
}
