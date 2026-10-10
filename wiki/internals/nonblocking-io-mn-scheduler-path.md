---
date: 2026-08-01
tags: [internals, question]
---

# ノンブロッキング I/O 化で M:N スケジューラの epoll パスに乗れるか（Q2 解答）

**結論**: 乗れる。biryani は現状ブロッキングソケットを使っており、`IO#read` は毎回 dedicated SNT
を取得して OS レベルでブロックする（[[ractor-mn-snt-lifecycle]] の thread_create_core ~10% の直接原因）。
ソケットを `O_NONBLOCK` にすれば、`read()` が `EAGAIN` を返すたびに Ruby 側は
epoll ベースの M:N スケジューラのイベント待ちパスに切り替わり、SNT を占有せずに待機できる。

## 詳細

### biryani の現状：ブロッキングソケット

**`raw/biryani/lib/biryani/server.rb`**（`socket.accept` で得た `IO` をそのまま使用、`O_NONBLOCK` 設定なし）:

```ruby
Ractor.new(socket.accept, @proc) do |io, proc|
  # io は blocking モードのまま IO#read / IO#write に渡される
end
```

### `IO#read` → ブロッキング呼び出しの分岐点

C 実装のエントリポイントは
[`rb_thread_io_blocking_call`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread.c#L2203-L2280)。

```c
volatile bool prev_mn_schedulable = th->mn_schedulable;
th->mn_schedulable = thread_io_mn_schedulable(th, events, NULL);
...
BLOCKING_REGION(th, {
    val = func(data1);         // ← 実際の read(2) システムコール
    saved_errno = errno;
}, ubf_select, th, FALSE);

if (events && blocking_call_retryable_p((int)val, saved_errno)) {   // EAGAIN/EWOULDBLOCK のときのみ true
    // `func` just returned EAGAIN, so the fd is known not to be ready.
    if (thread_io_wait_events(th, fd, events, NULL, true) == io_wait_ready) {
        RUBY_VM_CHECK_INTS_BLOCKING(ec);
        goto retry;
    }
    else if (th->mn_schedulable) {
        // M:N で待てなかったときは通常のブロッキング待ちにフォールバック
        rb_thread_wait_for_single_fd(th, fd, events, NULL);
        RUBY_VM_CHECK_INTS_BLOCKING(ec);
        goto retry;
    }
}
```

`17aeb89200` では `thread_io_wait_events` が `bool` ではなく `enum io_wait_result`（`io_wait_ready` / `io_wait_timed_out` / `io_wait_unhandled`）を返すようになり、
M:N 側で待てなかった場合（`io_wait_unhandled`）は `rb_thread_wait_for_single_fd` によるブロッキング待ちに落ちる。
「EAGAIN のときだけ epoll パスに入る」という分岐の本質は `e98f95b4fd` 時点から変わっていない。

[`thread_io_mn_schedulable`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread.c#L2120-L2131):

```c
static bool
thread_io_mn_schedulable(rb_thread_t *th, int events, const struct timeval *timeout)
{
#if defined(USE_MN_THREADS) && USE_MN_THREADS
    // RB_WAITFD_PRI は M:N で待てないので除外（17aeb89200 で追加された条件）
    return !th_has_dedicated_nt(th) && (events || timeout) && th->blocking &&
        !(events & ~(RB_WAITFD_IN | RB_WAITFD_OUT));
#else
    return false;
#endif
}
```

**重要な非対称性**: `thread_io_mn_schedulable` は「M:N スケジューラの epoll 待ちパスに入れるか」の
判定であって、`read()` 自体の呼び出し方（ブロッキング／ノンブロッキング）は関知しない。
実際に epoll 待ちパス（[`thread_sched_wait_events`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched_mn.c#L536)、
`epoll_ctl` で fd を登録する）に入るのは、**`func(data1)` の呼び出し（＝実際の `read(2)`）が
`EAGAIN`/`EWOULDBLOCK` を返して `blocking_call_retryable_p` が true になったときだけ**。

### ブロッキングソケットでは EAGAIN が発生しない

biryani のソケットは `O_NONBLOCK` 未設定 = ブロッキングモード。この場合 `read(2)` はデータが
届くまでカーネル内でブロックし、**決して `EAGAIN` を返さない**。したがって：

1. `BLOCKING_REGION` マクロが `blocking_region_begin` → [`thread_sched_to_waiting_common`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L983-L995) を呼ぶ
2. `thread_sched_to_waiting_common` が **`native_thread_dedicated_inc`** を呼び、この Ruby スレッドに
   専用の OS スレッド（dedicated SNT）を割り当てる
3. `read()` はその OS スレッド上でカーネルレベルでブロックする（GVL は解放済みなので他の Ruby スレッドは動ける）
4. データ到着で `read()` が復帰 → `blocking_call_retryable_p` は false（成功か通常エラー）→ retry ループに入らず epoll パスは一度も使われない
5. dedicated SNT は解放されるが、`snt_cnt` の増減サイクルが `IO#read` のたびに発生し、
   biryani の高頻度 I/O では SNT の生成・破棄（`pthread_create`）が連続する
   （[[ractor-mn-snt-lifecycle]] 参照）

### ノンブロッキングソケットにした場合の分岐

`O_NONBLOCK` を設定した場合、`read(2)` はデータがなければ即座に `EAGAIN` を返す：

1. `func(data1)` が `EAGAIN` で復帰 → `blocking_call_retryable_p` が true
2. `thread_io_wait_events` → `thread_io_mn_schedulable` が true（dedicated NT を持っていなければ）
3. [`thread_sched_wait_events`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched_mn.c#L536-L616) が
   fd を `timer_th.event_fd`（プロセス共有の `epoll_create1` インスタンス、
   [`thread_sched_mn.c:1632`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched_mn.c#L1632)）に登録する。
   `ce15950f56`（2026-08-29）以降は `EPOLLONESHOT` で登録が fd の生存期間中残り続け、2 回目以降の待ちは `EPOLL_CTL_MOD` 1 回で再アームする
   （以前は待ちのたびに ADD と DEL を 1 回ずつ発行していた）
4. この Ruby スレッドは SNT を**解放**し、共有の `timer_thread` が epoll で複数 fd をまとめて監視
5. readable になったら `timer_thread` が該当スレッドを起こし、共有 SNT プールから割り当てて `retry:` へ

この経路では `native_thread_dedicated_inc/dec` が呼ばれない。**dedicated SNT を経由しないため、
IO#read のたびの SNT 補充サイクルが構造的に発生しなくなる。**

### biryani への影響（推定・未実測）

| 項目 | ブロッキング（現状） | ノンブロッキング化した場合 |
|------|---------------------|--------------------------|
| `thread_create_core`（~10%、[[ractor-mn-snt-lifecycle]]） | IO#read のたびに SNT 補充が発生しうる | epoll 登録のみ。SNT 補充頻度が構造的に低下する見込み |
| futex 同期（~11%） | dedicated SNT の `cond_signal`/`wait` | 共有 `timer_thread` の epoll_wait に集約される見込み |
| 実装コスト | — | `socket.accept.io.nonblock = true` 相当の変更 + `read_nonblock`/`wait_readable` ループへの書き換えが必要（Ruby レベルのアプリケーションコード変更） |
| リスク | — | 短命コネクション・低同時実行数では epoll 登録・timer_thread 経由のオーバーヘッドが逆に増える可能性（未検証） |

### 17aeb89200 での前提の変化

- **ノンブロッキング側が有利になった**: `ce15950f56` の `EPOLLONESHOT` 化で、待ちのたびに発行していた `epoll_ctl` が 2 回から 1 回（MOD のみ）に減った。
  コミットメッセージによると、socketpair の往復ベンチマーク（2 Ractor/pair）で +98〜114%、1 接続 1 Ractor の HTTP サーバー（punicorn）で +10% だった。
  biryani をノンブロッキング化すれば、この最適化の恩恵をそのまま受けられる
- **ブロッキング側も変わった**: [`native_thread_dedicated_dec`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1884-L1910) は、
  プールが `max_cpu` に達していれば dedicated から戻る nt をプールに戻さずに retire させるようになった（`43793ca21a`）。
  このため「dedicated から戻った nt が過剰になる」状況はなくなったが、retire した分は後でまた
  `native_thread_check_and_create_shared` が `pthread_create` で作り直すことになる。生成と破棄の繰り返しが減ったのか、
  かえって増えたのかは実測しないと分からない（[Q7](../questions/README.md) の比較対象に含める）

## 次のステップ

- biryani 側で `IO#read_nonblock` + `IO#wait_readable` を使う実験ブランチを作り、
  `-c25 -m50` で FlameGraph を再取得して `thread_create_core` / futex の変化を実測する
  → 具体的な変更案・確認事項は [[../questions/README]] の Q7 に切り出した
- これは ruby/ruby 本体の変更ではなく **biryani（アプリケーションレベル）の書き換え**なので、
  ruby/ruby へのコントリビュートには直結しない。ただし実測結果は
  [[ractor-mn-snt-lifecycle]] や [[../contributions/snt-replenishment-overhead]] の
  「SNT 補充コストは biryani の I/O パターン次第で回避可能」という主張の裏付けデータになる

## 関連ページ

- [ractor-mn-snt-lifecycle](ractor-mn-snt-lifecycle.md) — SNT ライフサイクル全体（thread_create_core ~10% の真因）
- [ractor-overview](ractor-overview.md)
- [biryani-ractor-architecture](biryani-ractor-architecture.md) — biryani の I/O パターン
- [../findings/rperf-wall-vs-perf-cpu](../findings/rperf-wall-vs-perf-cpu.md) — IO#read 47.9% の計測
- [../contributions/snt-replenishment-overhead](../contributions/snt-replenishment-overhead.md)
- [../questions/README](../questions/README.md) — Q2
