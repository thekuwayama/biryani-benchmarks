---
date: 2026-11-09
type: issue
status: 候補
---

# グローバル GC の取り合いに負けると major GC が minor GC になり、`heap_prepare` が `rb_bug` で落ちる

per-Ractor GC（4.1.0-preview1 `2d08b5f42f`、上流 master `2cd57fe63d` も同じコード）で、Ractor の objspace のヒープが 1 ページしかないとき、
`heap_prepare` が頼りにしている「2 回目の `gc_start` は major GC になる」が、別の Ractor のグローバル GC と重なると崩れる。
同じ最終状態を `GC.stress` で起こす未マージの PR [ruby/ruby#19734](https://github.com/ruby/ruby/pull/19734) があり、その変更でこの経路も直ることを確かめた。

## 問題・提案

**問題**: `heap_prepare` の 2 回目の `gc_start` が `gc_start_global` に進み、VM ロックを待つ間に別の Ractor のグローバル GC が走ると、

1. グローバル GC がこの objspace の `need_major_gc` を NONE に戻す
2. ロックを取った後の再確認で `gc_need_global_p` が偽になり、`gc_start` は local GC にフォールスルーする
3. `need_major_gc` が消えているので、この local GC は minor になる。sweep の最初に、グローバル GC が作った `free_pages` を捨て、1 ページしかないヒープの唯一のページをまた pool（`pooled_pages`）に入れる
4. minor GC が `MAJOR_BY_OLDGEN` を立て直すので、pool は `free_pages` に戻らない → 確保できず `rb_bug("cannot create a new page after major GC")`

詳しい経路と図は [findings/gc-cannot-create-page-after-major-gc](../findings/gc-cannot-create-page-after-major-gc.md)。

**提案（どちらか、または両方）**:

- **(1) PR #19734 への情報提供（コメント）**: PR は `GC.stress`・`ObjectSpace.each_object`・終了時など、major GC が incremental でなく走る場合をきっかけに挙げている。
  `GC.stress` を使わない実際のワークロード（Ractor を多数使う HTTP/2 サーバー）でも、グローバル GC との重なりという別のきっかけで同じ最終状態になり、PR の変更でそれも直ることを伝える。
  4.1.0 のリリース前に PR を進める材料になる
- **(2) 案 A（別の PR 候補）**: `gc_start` で、待っている間に別の Ractor のグローバル GC が走っていたら、local GC をせずに返す。
  グローバル GC がこの objspace も回収した直後なので、local GC は要らない（フォールスルーした時点で、48 回中 45 回は全ヒープに空きページがあった）

```c
    if (!(reason & GPR_FLAG_METHOD) && gc_need_global_p(objspace)) {
        const size_t global_count = global_objspace->global_gc.count;
        /* A global GC is always a major, so autocompact applies. */
        if (gc_start_global(objspace, reason, ruby_enable_autocompact, true)) {
            return TRUE;
        }
        /* Another Ractor's global GC collected this objspace while we waited. */
        if (global_objspace->global_gc.count != global_count) {
            return TRUE;
        }
        /* Fall through to a local GC */
    }
```

2 つは独立している。PR #19734 は `heap_prepare` 側で、pool に残ったページを使えるようにする（どのきっかけでも効く）。
案 A は `gc_start` 側で、重なったときの要らない local GC をなくす（`GC.stress` のきっかけには効かない）。

### PR #19734 と案 A の比較（2026-11-09）

| 観点 | PR #19734 | 案 A |
|------|-----------|------|
| 変更する場所 | `heap_prepare` の major 分岐（2 回目の `gc_start` と `gc_continue` の後） | `gc_start` のグローバル GC からのフォールスルー |
| 直すもの | 結果（ページが pool に残ったまま確保に行き詰まる） | 原因の 1 つ（major の要求が消えたまま minor GC が走る） |
| `GC.stress` などのきっかけ（PR の再現） | 直る（5 回中 0 回） | 直らない（5 回中 5 回） |
| グローバル GC との重なり（biryani） | 直る（20 回中 0 回、重なり 1 回） | 直る（20 回中 0 回、重なり 2 回） |
| 重なったときの余分な minor GC | 残る。グローバル GC が作った `free_pages` は捨てられ、作り直される | なくなる（10 回で 48 回あったフォールスルーがなくなる） |
| 設計との関係 | 「pool は incremental marking のためのもの。そのステップが走らないなら普通の空きページ」という PR の説明に沿う。既存の設計は変えない | 「負けた側は local GC をする」というコメントの設計を変える |
| 影響が及ぶ範囲 | `heap_prepare` が `rb_bug` に向かうときだけ | `gc_need_global_p` が真のときの全呼び出し元（`NEWOBJ`・`MALLOC`・C API の `rb_gc` など） |
| 気になる点 | pool を移しても `rincgc.pooled_slots` は減らない（[`heap_move_pooled_pages_to_free_pages`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L7497-L7514) は触らない）。次の major GC の incremental marking の歩数は[この値から決まる](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L8093)（500 スロットごとに 1 歩）ので、移した 1 ヒープ分（slot 512 なら 127、最大でも 2,047 スロット）だけ歩数が多めに見積もられる。正しさには関わらず、影響は小さいと読んだ（未計測） | 返った後に空きページのないヒープが残ることがある（48 回中 3 回）。そのときは、グローバル GC の最後の手当て（予算か空きページ）に頼る。呼び出し元の要求（malloc 起因の GC・`rb_gc` の full mark と即時 sweep）は、グローバル GC が満たしているはず（未検証） |
| 状態 | 上流に PR があり、レビュー待ち。CI は ModGC の `check (mmtk, release, ubuntu-latest)` だけ落ちているが、PR とは関係ない（下記） | この wiki の実験ビルドだけにある |

**PR #19734 の CI（2026-11-09 確認）**: 135 件中、失敗は ModGC の `check (mmtk, release, ubuntu-latest)` の 1 件だけ（2026-11-05 14:50 の実行）。
落ちたのは `TestRactor#test_shared_native_threads_stay_capped_across_blocking_io`（`Expected 11 to be <= 10.`）で、プロセスのスレッド数を数えて上限 10 と比べるテストである。
MMTk は GC 用に自前のスレッドを持つので数が超える。このジョブは `+GC[mmtk]` で動くので、PR が変えた `gc/default/default.c` のコードはそもそも走らない。
同じ日に master の ModGC でも同じテストが 2 回落ちていて（`364cd99232`・`cd4f33f0bb`）、上流は `13786f1302`「Fix failing ractor test under MMTk」で、default 以外の GC ではこのテストを omit するようにした。
PR はその後リベースされていないので、リベースか再実行で消えるはずである。

**読み**: クラッシュを直すのは PR #19734 で足り、カバーする範囲も広い。案 A は直すというより、重なったときの無駄を省く改善である。
最初のコントリビュートとしては、PR #19734 に「グローバル GC との重なりという別のきっかけがあり、PR の変更で直る」というデータを伝えるのが筋がよい。
案 A を別に出すなら、余分な minor GC がどれだけのコストになっているか（例えば Ractor が多いときのグローバル GC 1 回あたりのフォールスルーの数と時間）を先に測る必要がある。今のデータでは、無駄の大きさは分からない。

## 根拠（ベンチマーク・プロファイラ結果へのリンク）

計装ビルド（preview1 + トレース + 修正の切り替え）で `bundle exec rake load`（`h2load -n10000 -c50 -m100 -t10`）を流した結果:

| 設定 | 実行回数 | クラッシュ | 他の Ractor のグローバル GC と重なった major 分岐 |
|------|---------|-----------|------------------------------------------------|
| 修正なし | 20 | **5** | 7 回（7 回ともクラッシュ） |
| 案 A | 20 | 0 | 2 回（2 回とも成功） |
| PR #19734 の変更 | 20 | 0 | 1 回（成功） |

- 修正なしでは、重ならなかった major 分岐は 1,064 回すべて成功した。クラッシュは重なった回だけで起きている
- PR #19734 の 1 行の再現（`RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR=0.1 ruby -e 'Ractor.new { GC.stress = true; +"" }.value'`）は、preview1 のリリースビルドで 5 回中 5 回落ちた。PR の変更では 5 回とも通り、案 A だけでは 5 回とも落ちた
- 2026-11-03 のコアダンプ（リリースビルド）でも、落ちた objspace は「最後の GC が minor（`latest_gc_info = 0x100`）、`need_major_gc = MAJOR_BY_OLDGEN`、唯一のページが pool、`free_pages` が NULL」で、トレースで見た状態と同じだった
- 詳細: [findings/gc-cannot-create-page-after-major-gc](../findings/gc-cannot-create-page-after-major-gc.md)

**再現できるシナリオ**: biryani の `rake load` で確率的に起きる（リリースビルドで 4 GB の VM で 10 回中 2 回、8 GiB の VM で 8 回中 1 回・25 回中 1 回）。
biryani なしの最小再現はまだない（findings の「biryani なしの最小再現」）。

## 関連する ruby/ruby のコード

| ファイル | 行 | 内容 |
|----------|---|------|
| [`gc/default/default.c`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L3160-L3178) | 3160-3178 | `heap_prepare` の major 分岐と `rb_bug` |
| [`gc/default/default.c`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L8886-L8892) | 8886-8892 | `gc_start` のグローバル GC への分岐と local GC へのフォールスルー |
| [`gc/default/default.c`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L9245-L9254) | 9245-9254 | `gc_enter` の `global_auto`: VM ロックの後に `gc_need_global_p` を再確認して false を返す |
| [`gc/default/default.c`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L9621-L9623) | 9621-9623 | 「負けた側は local GC をする」という設計のコメント |
| [`gc/default/default.c`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L9698-L9704) | 9698-9704 | グローバル GC のステップ 5: `need_major_gc` を NONE に戻し、pool を `free_pages` に移す |
| [`gc/default/default.c`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L5456-L5457) | 5456-5457 | `gc_sweep_start_heap`: sweep の最初に `free_pages` と `pooled_pages` を捨てる |
| [`gc/default/default.c`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L5754-L5757) | 5754-5757 | `gc_sweep_step`: 最初のページを pool に入れる |
| [`gc/default/default.c`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L5652-L5663) | 5652-5663 | `gc_sweep_finish`: 次が major なら pool を戻さない |
| [`gc/default/default.c`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L8113) | 8113 | `gc_marks_start`: major GC の開始時に pool を `free_pages` に移す |

## 次のステップ

1. 人間が PR #19734 とこの経路を理解したうえで、PR にコメントするかを判断する（この wiki からは書き込まない）。コメントするなら、biryani を使わない再現があると伝わりやすい
2. 案 A を出すなら、フォールスルーの設計意図を確かめる。負けた側の local GC でしか満たせない条件がないか（`reason` が `GPR_FLAG_MALLOC` のときなど。グローバル GC は全 objspace の malloc カウンタを戻すので、満たされているはず）。
   `make test-all`（少なくとも `test/ruby/test_gc.rb`、`test/ruby/test_ractor.rb`）と `make btest` を通す
3. biryani なしの最小再現を作る（多数の若い Ractor が初めて `MAJOR_BY_OLDGEN` を立てる瞬間に、グローバル GC の取り合いを起こす）
4. 計装なしのリリースビルドに PR #19734 だけを当てて、`rake load` を多数回流す
