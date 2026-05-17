---
date: 2026-05-17
tags: [finding]
---

# FlameGraph 比較 — `-c25 -m50` vs ベースライン（`-c50 -m100`）

最高スループット構成（-c25 -m50、1,300 Ractors）とベースライン（-c50 -m100、5,100 Ractors）の CPU プロファイルを比較した。

Raw sources: `raw/flamegraph_c25_m50.svg`（比較元: `raw/flamegraph_baseline.svg`）

## CPU 占有率の比較

| カテゴリ | 関数 | baseline | -c25 -m50 | 変化 |
|---------|------|----------|-----------|------|
| Ractor 生成 | `thread_create_core` | 7.14% | 5.24% | **▼ 減少** |
| Ractor 生成 | `native_thread_create` | 6.79% | 5.24% | **▼ 減少** |
| Ractor 生成 | `nt_alloc_stack` | 4.64% | （top30 外） | **▼ 大幅減** |
| futex 系 | `do_futex` + `futex_wake` 等 | ~16% | ~11% | **▼ 減少** |
| GC | `gc_sweep_*` + `rb_gc_mark_children` | ~11% | ~8% | ▼ 小幅減 |
| **Ruby VM 実行** | `vm_exec_core` | ~10% | **~14%** | **▲ 増加** |
| 未解決シンボル | `[unknown]` | 28% | 24% | ▼ 小幅改善 |

（サンプル数: baseline 280 / -c25 -m50 191）

## 分析

### オーバーヘッドが減り、有効仕事の割合が上がった

`vm_exec_core`（Ruby VM インタープリタ本体）の比率が 10% → 14% に増加した。これは Ractor 数を 5,100 → 1,300 に減らしたことで、OS スケジューリングや futex 待機に費やされる CPU が削減され、その分が実際の Ruby 処理に回っていることを示す。

### Ractor 生成コストの半減

`thread_create_core` + `native_thread_create` + `nt_alloc_stack` の合計はベースラインで ~18%、-c25 -m50 では ~10% に低下。これは同時ストリーム数の減少（最大 5,000 → 1,250）に比例しており、[[internals/ractor-architecture]] で確認した「ストリームごとに Ractor 生成」の設計と一致する。

### futex オーバーヘッドは依然として高い（~11%）

Ractor 数を 4 分の 1 にしても futex 比率は 16% → 11% の低下に留まる。[[internals/ractor-port-implementation]] で確認したように、1 メッセージ送信 = 1 `pthread_cond_broadcast` であり、リクエスト数（10,000 固定）に比例する部分があるため、Ractor 数だけでは大きく削減できない。

### GC は微減（~11% → ~8%）

GC 圧力も小幅に減少。Ractor 数の減少でオブジェクトの生成・破棄サイクルが緩やかになっていると考えられるが、GET リクエストのボディなしシナリオでは元々の GC 圧力が低いため変化幅が小さい。

## スループット比較

| 構成 | Ractors | req/s | vm_exec_core 比率 |
|------|---------|-------|-----------------|
| baseline: -c50 -m100 | 5,100 | 4,981 | ~10% |
| -c25 -m50 | 1,300 | 7,695 | ~14% |

Ractor 数を 74% 削減 → スループット +54%、vm_exec_core +40%。オーバーヘッド削減の効果が明確に現れている。

## 次に調べると良いこと

- さらに Ractor 数を減らした場合（例: -c10 -m10 = 120 Ractors）で vm_exec_core がどこまで上がるか
- futex の絶対コストを減らすには Ractor 間のメッセージ数自体を減らす設計変更が必要
- GC の絶対量を増やすには POST ボディ付きシナリオで測定する

## 関連ページ

- [[findings/flamegraph-baseline-cpu-profile]]
- [[scenarios/sweep-c-parameter]]
- [[scenarios/sweep-m-parameter]]
- [[internals/ractor-architecture]]
- [[internals/ractor-port-implementation]]
