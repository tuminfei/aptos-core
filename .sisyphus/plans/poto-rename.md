# Move Framework 模块重命名计划: apt os*\* → poto*\*

## TL;DR

> **快速摘要**: 将 `0x1::` 命名空间下的 `aptos_account`, `aptos_coin`, `aptos_governance` 三个模块重命名为 `poto_account`, `poto_coin`, `poto_governance`。需要修改 Move 源文件、Rust 代码、测试文件和 JSON golden files。

> **交付物**:
>
> - 重命名 6 个 Move 源文件 (.move + .spec.move)
> - 更新所有 Rust 代码中的模块引用 (约 83 处)
> - 更新 JSON 测试数据 (23 个 golden files)
> - 编译和测试通过

> **预估工作量**: Large (约 15-25 小时)
> **并行执行**: YES - 多阶段并行
> **关键路径**: Move 源文件 → Rust 编译 → 测试验证

---

## 背景

### 原始需求

用户希望将 Aptos Framework 中 `0x1::` 下的模块命名从 `aptos_*` 替换为 `poto_*`。

### 模块范围

| 原模块名           | 新模块名          | 源文件                                                |
| ------------------ | ----------------- | ----------------------------------------------------- |
| `aptos_account`    | `poto_account`    | `aptos_account.move`, `aptos_account.spec.move`       |
| `aptos_coin`       | `poto_coin`       | `aptos_coin.move`, `aptos_coin.spec.move`             |
| `aptos_governance` | `poto_governance` | `aptos_governance.move`, `aptos_governance.spec.move` |

### 确认的决策

1. ✅ 只改模块名，不改地址 (`0x1::` 保持不变)
2. ✅ 结构体名也需要改 (`AptosCoin` → `PotoCoin`)
3. ❌ **不保留向后兼容别名** (用户确认: 直接替换)
4. ❌ **不修改 topo_coin** (用户确认: 保持原样)

---

## 实施计划

### 第一阶段: Move 源文件重命名 (Wave 1 - 并行)

#### Task 1.1: 重命名 Move 源文件

**需要重命名的文件:**

```
aptos-move/framework/aptos-framework/sources/
├── apt os_account.move → poto_account.move
├── apt os_account.spec.move → poto_account.spec.move
├── apt os_coin.move → poto_coin.move
├── apt os_coin.spec.move → poto_coin.spec.move
├── apt os_governance.move → poto_governance.move
└── apt os_governance.spec.move → poto_governance.spec.move
```

**操作步骤:**

```bash
# 1. 重命名文件
cd apt os-move/framework/aptos-framework/sources
mv apt os_account.move poto_account.move
mv apt os_account.spec.move poto_account.spec.move
mv apt os_coin.move poto_coin.move
mv apt os_coin.spec.move poto_coin.spec.move
mv apt os_governance.move poto_governance.move
mv apt os_governance.spec.move poto_governance.spec.move
```

**验证:**

- [ ] `ls poto_*.move` 显示 3 个主模块文件
- [ ] `ls poto_*.spec.move` 显示 3 个 spec 文件
- [ ] 确认旧文件名不存在

#### Task 1.2: 修改模块声明

**poto_account.move:**

```move
# 修改前
module apt os_framework::aptos_account {

# 修改后
module apt os_framework::poto_account {
```

**poto_coin.move:**

```move
# 修改前
module apt os_framework::aptos_coin {

# 修改后
module apt os_framework::poto_coin {
```

**poto_governance.move:**

```move
# 修改前
module apt os_framework::aptos_governance {

# 修改后
module apt os_framework::poto_governance {
```

**结构体名修改 (poto_coin.move):**

```move
# 修改前
struct AptosCoin has key {}

# 修改后
struct PotoCoin has key {}
```

#### Task 1.3: 修改模块内部引用

**在 poto_account.move 中:**

- `use apt os_framework::aptos_coin` → `use apt os_framework::poto_coin`

**在 poto_coin.move 中:**

- 无需修改 (不引用其他 apt os\_\* 模块)

**在 poto_governance.move 中:**

- `use apt os_framework::topo_coin` → `use apt os_framework::poto_coin` (如果是测试用途)

#### Task 1.4: 修改依赖模块的引用

**需要检查并修改以下文件的 import:**

- `apt os_framework/sources/account.move` - 可能引用 `aptos_account`
- `apt os_framework/sources/coin.move` - 可能引用 `aptos_coin`
- `apt os_framework/sources/genesis.move` - 可能引用 `aptos_coin`, `aptos_account`
- `apt os_framework/sources/stake.move` - 可能引用 `aptos_governance`

**使用 ast_grep 搜索引用并修改:**

```bash
# 搜索 apt os_framework 中对 apt os_account 的引用
ast_grep_search --lang move \
  --pattern 'apt os_framework::aptos_account' \
  --path apt os-move/framework/aptos-framework/sources
```

#### Task 1.5: 验证 Move 编译

**编译测试:**

```bash
cargo test -p apt os-framework -- --skip prover 2>&1 | head -100
```

**预期结果:**

- 编译通过
- 单元测试通过 (跳过 prover)

---

### 第二阶段: Rust 代码引用替换 (Wave 2 - 并行)

#### Task 2.1: 替换 apt os_coin 引用 (41 处)

**主要文件:**
| 文件 | 修改内容 |
|------|----------|
| `sdk/src/types.rs` | `APTOS_COIN_TYPE_STR` → `POTO_COIN_TYPE_STR` |
| `sdk/src/coin_client.rs` | `"0x1::aptos_coin::AptosCoin"` → `"0x1::poto_coin::PotoCoin"` |
| `api/types/src/derives.rs` | 类型字符串替换 |
| `aptos-move/e2e-tests/src/executor.rs` | 引用替换 |

**替换命令 (使用 ast_grep_replace):**

```bash
# 替换 Rust 代码中的 apt os_coin 引用
ast_grep_replace --lang rust \
  --pattern 'aptos_coin::AptosCoin' \
  --rewrite 'poto_coin::PotoCoin' \
  --path .
```

#### Task 2.2: 替换 apt os_account 引用 (28 处)

**主要文件:**
| 文件 | 修改内容 |
|------|----------|
| `api/src/tests/multisig_transactions_test.rs` | 11 处函数引用 |
| `api/src/tests/view_function.rs` | 函数引用 |
| `crates/aptos-rosetta/src/construction.rs` | 注释和代码 |
| `aptos-move/script-composer/src/tests/mod.rs` | 模块加载 |

**替换命令:**

```bash
# 替换 apt os_account 模块引用
ast_grep_replace --lang rust \
  --pattern 'aptos_account::' \
  --rewrite 'poto_account::' \
  --path .
```

#### Task 2.3: 替换 apt os_governance 引用 (14 处)

**主要文件:**
| 文件 | 修改内容 |
|------|----------|
| `execution/executor/tests/internal_indexer_test.rs` | 类型引用 |
| `types/src/account_config/events/mod.rs` | 事件类型 |
| `testsuite/forge/src/interface/aptos.rs` | Forge 接口 |
| `crates/aptos/src/governance/mod.rs` | Governance 模块 |

**替换命令:**

```bash
# 替换 apt os_governance 模块引用
ast_grep_replace --lang rust \
  --pattern 'aptos_governance::' \
  --rewrite 'poto_governance::' \
  --path .
```

#### Task 2.4: 编译验证 Rust 代码

**编译命令:**

```bash
# 核心包编译
cargo build -p apt os-api
cargo build -p apt os-executor
cargo build -p apt os-types
cargo build -p apt os-rosetta
```

**预期结果:**

- 编译通过，无错误

---

### 第三阶段: JSON Golden Files 更新 (Wave 3)

#### Task 3.1: 更新 API Golden Files

**需要更新的文件 (23 个):**

```
api/goldens/aptos_api__tests__transactions_test__*.json
```

**批量替换命令:**

```bash
# 替换 JSON 中的 apt os_coin 引用
find api/goldens -name "*.json" -exec \
  sed -i '' 's/0x1::aptos_coin::AptosCoin/0x1::poto_coin::PotoCoin/g' {} \;

find api/goldens -name "*.json" -exec \
  sed -i '' 's/0x1::aptos_coin::/0x1::poto_coin::/g' {} \;
```

#### Task 3.2: 更新 OpenAPI Spec

**检查并更新:**

- `api/doc/spec.yaml`
- `api/doc/spec.json`

**重新生成 (如果需要):**

```bash
cargo run -p apt os-openapi-spec-generator -- \
  -f yaml -o api/doc/spec.yaml

cargo run -p apt os-openapi-spec-generator -- \
  -f json -o api/doc/spec.json
```

---

### 第四阶段: 测试验证 (Wave 4 - 顺序)

#### Task 4.1: 运行 API 测试

**测试命令:**

```bash
cargo test -p apt os-api -- --test-threads=1 2>&1 | tee test_output.log
```

**预期结果:**

- 所有 API 测试通过
- Golden files 匹配

**如果测试失败:**

- 检查失败的测试输出
- 重新生成 golden files: `UPDATE_GOLDENS=1 cargo test -p apt os-api`

#### Task 4.2: 运行 Smoke Tests

**测试命令:**

```bash
cargo test -p smoke-test 2>&1 | tee smoke_test.log
```

#### Task 4.3: 运行 Move 框架测试

**测试命令:**

```bash
cargo test -p apt os-framework 2>&1 | tee framework_test.log
```

#### Task 4.4: 运行 Executor 测试

**测试命令:**

```bash
cargo test -p apt os-executor 2>&1 | tee executor_test.log
```

---

### 第五阶段: 清理和最终验证 (Wave 5)

#### Task 5.1: 检查遗漏的引用

**全局搜索确认:**

```bash
# 确认没有遗漏的 apt os_ 引用
grep -r "aptos_coin::" --include="*.rs" --include="*.move" .
grep -r "aptos_account::" --include="*.rs" --include="*.move" .
grep -r "aptos_governance::" --include="*.rs" --include="*.move" .
```

#### Task 5.2: Lint 检查

**Lint 命令:**

```bash
cargo xclippy -p apt os-api --allow-dirty
cargo +nightly fmt --check
```

#### Task 5.3: 最终构建验证

**完整构建:**

```bash
cargo build --release 2>&1 | tail -50
```

---

## 文件修改清单

### Move 源文件 (6 个)

| 文件                                                 | 操作                                 |
| ---------------------------------------------------- | ------------------------------------ |
| `aptos-framework/sources/aptos_account.move`         | 重命名为 `poto_account.move`         |
| `aptos-framework/sources/aptos_account.spec.move`    | 重命名为 `poto_account.spec.move`    |
| `aptos-framework/sources/aptos_coin.move`            | 重命名为 `poto_coin.move`            |
| `aptos-framework/sources/aptos_coin.spec.move`       | 重命名为 `poto_coin.spec.move`       |
| `aptos-framework/sources/aptos_governance.move`      | 重命名为 `poto_governance.move`      |
| `aptos-framework/sources/aptos_governance.spec.move` | 重命名为 `poto_governance.spec.move` |

### Rust 源文件 (约 39 个)

| 包               | 文件数 | 主要文件                                                  |
| ---------------- | ------ | --------------------------------------------------------- |
| `aptos-api`      | 8      | `tests/*.rs`, `types/src/derives.rs`                      |
| `aptos-sdk`      | 2      | `src/types.rs`, `src/coin_client.rs`                      |
| `aptos-executor` | 2      | `tests/internal_indexer_test.rs`                          |
| `aptos-types`    | 1      | `src/account_config/events/mod.rs`                        |
| `aptos-rosetta`  | 1      | `src/construction.rs`                                     |
| `testsuite`      | 3      | `forge/src/interface/aptos.rs`, `smoke-test/*.rs`         |
| `aptos-move`     | 15+    | `e2e-tests/`, `e2e-move-tests/`, `script-composer/tests/` |

### JSON 文件 (23 个)

```
api/goldens/aptos_api__tests__transactions_test__*.json
```

---

## 回滚策略

如果出现问题:

1. **快速回滚**: 使用 git revert 撤销更改

   ```bash
   git revert --no-commit HEAD
   git commit -m "Revert: temporary rollback for fix"
   ```

2. **分支策略**: 建议在 feature 分支上工作
   ```bash
   git checkout -b feature/poto-rename
   ```

---

## 成功标准

- [ ] Move 模块编译通过 (`cargo build -p apt os-framework`)
- [ ] Rust 核心包编译通过 (`apt os-api`, `apt os-executor`, `apt os-types`)
- [ ] API 测试通过 (`cargo test -p apt os-api`)
- [ ] Smoke 测试通过 (`cargo test -p smoke-test`)
- [ ] 无遗漏的 `apt os_*` 引用 (grep 验证)
- [ ] Lint 检查通过

---

## 预估时间

| 阶段                  | 时间           | 并行度            |
| --------------------- | -------------- | ----------------- |
| 第一阶段: Move 源文件 | 2-4 小时       | 并行 (文件重命名) |
| 第二阶段: Rust 代码   | 2-3 小时       | 并行 (多文件)     |
| 第三阶段: JSON/Golden | 2-4 小时       | 顺序              |
| 第四阶段: 测试验证    | 4-8 小时       | 顺序              |
| 第五阶段: 清理        | 1-2 小时       | 并行              |
| **总计**              | **11-21 小时** |                   |

---

## 下一步

请确认以下问题后开始执行:

1. **是否需要保留向后兼容别名？** (AptosCoin = PotoCoin)
2. **是否包括 topo_coin 的重命名？**

确认后可以开始执行第一阶段。
