---
date: 2026-11-03
tags: [finding]
---

# 4.1.0-preview1 で biryani が `[BUG] cannot create a new page after major GC` で落ちる

Ruby 4.1.0-preview1（`2d08b5f42f`）で biryani main（`7359e96`）に `h2load -n10000 -c50 -m100 -t10`（`bundle exec rake load`）をかけると、
**10 回中 2 回、プロセスが `rb_bug` で落ちた**。場所は GC のページ確保（[`heap_prepare`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L3120-L3183)）で、
OOM killer の記録はなかった。そのため、メモリが足りなかったのではなく、per-Ractor GC で**ヒープを広げる予算（`allocatable_bytes`）が 0 のまま**になったと考えられる。
上流は同じ失敗をグローバル GC の経路では手当てしているので、手当てされていない経路が残っている可能性がある。原因は未特定。

## 詳細

### 再現条件

- Lima VM（aarch64、4 CPU、4 GB）、`raw/biryani` main `7359e96`、`load/server_spec.rb`（`bundle exec rake load`）
- 1 プロセスで biryani サーバーを起動し、`h2load -n10000 -c50 -m100 -t10` を 1 回流す（同時 Ractor は最大で約 5,100 個）
- 4.1.0-preview1 で 10 回実行し、1 回目と 10 回目で落ちた。落ちた回の h2load は、それぞれ 12 件と 2,378 件が失敗した
- 同じ時間帯の `dmesg` に OOM killer の記録はない。`vm.max_map_count` は 1048576
- 4.0.5 では起きない（per-Ractor GC がない）。master `17aeb89200` は `gc/default/default.c` が preview1 と同じなので、同じく起きるはず（未確認）

### クラッシュレポート（抜粋）

```
/biryani-benchmarks/raw/biryani/lib/biryani/streams_context.rb:82: [BUG] cannot create a new page after major GC
ruby 4.1.0preview1 (2026-10-11 master 2d08b5f42f) +PRISM [aarch64-linux]

-- Ruby level backtrace information ----------------------------------------
.../server.rb:15:in 'block (2 levels) in run'
.../connection.rb:51:in 'serve'
.../connection.rb:93:in 'select_loop'
.../connection.rb:261:in 'handle_response'
.../connection.rb:339:in 'send_data'
.../streams_context.rb:82:in 'sendable_datas'

-- Threading information ---------------------------------------------------
Total ractor count: 1351

-- C level backtrace information -------------------------------------------
rb_bug                       error.c:1152
heap_prepare                 gc/default/default.c:3174
heap_next_free_page          gc/default/default.c:3361
newobj_refill                gc/default/default.c:3513
rb_gc_impl_new_obj           gc/default/default.c:3618
rb_ec_newobj_of              gc.c:1250
rb_reg_s_alloc               re.c:3582     ← /.{1,#{max_frame_size}}/m（式展開を含む正規表現リテラル、toregexp）
vm_exec_core                 insns.def:431
thread_do_start_proc         thread.c:641  ← Connection Ractor
```

Connection Ractor が、レスポンスを送るときに Regexp を 1 つ確保しようとして落ちている。確保したオブジェクト自体に特別な点はない。

### コード上の読み

[`heap_prepare`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L3120-L3183) は、空きページがないときに次の順で試す。

1. `gc_continue`（途中の incremental mark / lazy sweep を進める）→ `heap_page_allocate_and_initialize`
2. だめなら `gc_start(GPR_FLAG_NEWOBJ)`。`allocatable_bytes` が 0 なら `heap_allocatable_bytes_expand` で予算を足し、再び `heap_page_allocate_and_initialize`
3. それでもだめで、major GC が必要なら、もう一度 `gc_start` → `gc_continue` → `heap_page_allocate_and_initialize`。ここで失敗すると
   [`rb_bug("cannot create a new page after major GC")`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L3174)

[`heap_page_allocate_and_initialize`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L3052-L3084) が false を返すのは、
**再利用できる空きページがなく（`heap_page_resurrect` が NULL）、かつ `allocatable_bytes` が 0** のときだけである。
`heap_page_allocate` そのもの（mmap など）の失敗ではない。つまり、2 回 GC をしても、この objspace にはページを増やす予算が付かなかったことになる。

上流は同じ失敗をグローバル GC について認識している。グローバル GC は予算を決める `gc_marks_finish` を通らないので、GC 後も満杯の objspace は予算 0 のまま残り、次の確保でこの `rb_bug` になる。
そこで、グローバル GC の最後に、そういう objspace へ予算を与える処理が入っている（[`default.c:9873-9891`](https://github.com/ruby/ruby/blob/2d08b5f42f2cbed4a4e6ecf8d62987a4f21f98c1/gc/default/default.c#L9873-L9891)）。
今回はそれでも落ちたので、この手当てを通らない経路が残っていると考えられる。

### 仮説（未検証）

- `heap_prepare` の `gc_start` が、自分の objspace の GC を最後まで行わずに TRUE を返す経路がある（別の Ractor が始めたグローバル GC に合流した場合など）。そのため予算が付かない
- 死んだ Ractor のヒープを absorb した直後など、ページ数と予算の計算が合わなくなるタイミングがある（[findings/per-ractor-gc-ractor-churn-cost](per-ractor-gc-ractor-churn-cost.md) の absorb）
- （biryani は `GC.disable` / `GC.start` を呼ばないので、それらによる経路ではない）

### 次に確かめること

1. 落ちる直前の `GC.stat`（`scope: :local` / `:global`）と `GC.latest_gc_info` を取る。または `gc_report` を有効にしたビルドで、`heap_prepare` に入った時点の `allocatable_bytes`・`empty_pages_count`・GC の種類を出す
2. biryani を使わない最小の再現を作る（多数の Ractor を作っては捨てながら、各 Ractor でオブジェクトを確保し続ける）
3. 上流 master の先頭でも起きるかを確かめ、bugs.ruby-lang.org で既出かを確認する

## 関連ページ

- [findings/per-ractor-gc-ractor-churn-cost](per-ractor-gc-ractor-churn-cost.md) — per-Ractor GC で Ractor の使い捨てが高くつく（RSS の増加も同じ根）
- [internals/ractor-local-gc-status](../internals/ractor-local-gc-status.md)
- [internals/biryani-ractor-architecture](../internals/biryani-ractor-architecture.md)
- [questions/README](../questions/README.md) — Q10
