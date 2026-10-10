---
date: 2026-10-11
type: pr
status: 候補
---

# objspace_absorb の free page チェーン連結を O(dst) から O(src) にする

## 問題・提案

per-Ractor GC（master `17aeb89200`）の [`objspace_absorb`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/gc/default/default.c#L10066-L10072)
は、終了した Ractor の objspace（src）を別の objspace（dst）に統合する。そのとき src の free page チェーンを
**dst のチェーンの末尾**に付けるために、dst の連結リストを毎回先頭から辿っている。

```c
/* Append the free-page chain to the tail. */
if (sheap->free_pages) {
    struct heap_page **tail = &dheap->free_pages;
    while (*tail) tail = &(*tail)->free_next;
    *tail = sheap->free_pages;
    sheap->free_pages = NULL;
}
```

absorb のたびに dst のチェーンは伸びるので、1 つの dst に N 個の objspace が集まると O(N²) になる。
これは join されなかった Ractor の objspace が main にまとめて吸収される経路（disowned zombie / VM 終了時）で起きる。

提案（実験ビルドで効果を確認済み）: src の（短い）チェーンを辿って末尾を見つけ、**dst の先頭に付け替える**。

```c
/* Prepend src's free-page chain: walking src's (short) chain to its tail keeps
 * the merge O(src pages), where walking dst's chain made N absorbs O(N^2). */
if (sheap->free_pages) {
    struct heap_page *stail = sheap->free_pages;
    while (stail->free_next) stail = stail->free_next;
    stail->free_next = dheap->free_pages;
    dheap->free_pages = sheap->free_pages;
    sheap->free_pages = NULL;
}
```

別案: `rb_heap_t` に free_pages の末尾ポインタを持たせれば、「末尾に付ける」順序のまま O(1) にできる。
ただし sweep など free_pages を書き換える箇所すべてで末尾ポインタを保守する必要がある。

## 根拠（ベンチマーク・プロファイラ結果へのリンク）

- `perf annotate`: `objspace_absorb` のサンプルの 99.6% がこの `while` 行に集中。master の biryani 計測では、`objspace_absorb` の self がプロセス全体の 58.5% を占めた
- 実験ビルド（`17aeb89200` + 上記変更）:
  - Ractor 20,000 個の逐次生成・join: 4.09 s → **1.52 s**（4.0.5 は 1.19 s）。所要時間が Ractor 数に対して線形になった
  - biryani `-c25 -m50 -n10000`: プロセス全体の wall time が 9.15 s → **3.81 s**（終了時の absorb が約 6 s → 約 0.5 s）
  - h2load のスループットは変わらない（約 3,400 req/s）。リクエスト処理中の主なコストは retire GC と heap 初期化で、absorb ではない
- 詳細: [findings/per-ractor-gc-ractor-churn-cost](../findings/per-ractor-gc-ractor-churn-cost.md)、[scenarios/ruby-master-vs-405](../scenarios/ruby-master-vs-405.md)

## 関連する ruby/ruby のコード

| ファイル | 行 | 内容 |
|----------|---|------|
| [`gc/default/default.c`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/gc/default/default.c#L10066-L10072) | 10066-10072 | 問題の末尾探索 |
| [`gc/default/default.c`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/gc/default/default.c#L9996-L10233) | 9996-10233 | `objspace_absorb` 全体 |
| [`gc.c`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/gc.c#L4715-L4737) | 4715-4737 | `objspace_absorb_disowned_zombies`（main への吸収） |
| [`gc.c`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/gc.c#L4774-L4797) | 4774-4797 | `rb_gc_objspace_absorb_all_zombies`（VM 終了時） |

導入コミット: `85e3df9eaa`（2026-08-01、GC: per-Ractor local GC — GC engine）

## 次のステップ

1. free page の順序を変えてよいかを確かめる。dst の自前ページを優先して使う（局所性）意図で末尾に付けているのかもしれない。
   先頭に付けると、src の部分的に空いたページから先に割り当てが進む
2. 修正ビルドで `make test-all`（少なくとも `test/ruby/test_ractor.rb`、`test_gc.rb`）と `make btest` を通す
3. 再現用マイクロベンチを整える（Ractor を N 個作って join しない → orphan として main に吸収される経路）
4. 人間が内容を理解したうえで、ruby/ruby への PR を判断する（この wiki からは提出しない）
