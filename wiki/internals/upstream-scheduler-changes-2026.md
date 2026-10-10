---
date: 2026-10-11
tags: [internals]
---

# e98f95b4fd → 17aeb89200 の上流変更（2026-06〜10）と wiki への影響

`raw/ruby-src` を `e98f95b4fd`（2026-06-06、`default_max_cpu` PR のマージ）から master の `17aeb89200`（2026-10-10）に更新した。
その間の約 3,600 コミットのうち、この wiki の前提に関わるものを整理する。
要点は 3 つある。M:N スケジューラは `thread_sched.c` / `thread_sched_mn.c` に作り直された。
wiki で追っていた SNT プールの縮小と O(n) タイマーは、どちらも ko1 が上流で解決した。
per-Ractor GC も入った。

## 詳細

### ファイル構成の変化

`90e729c9bc`（2026-08-28）「Share one thread/ractor scheduler between POSIX and Windows」で、スケジューラ本体が `thread_pthread.c` から出て、POSIX と Windows の共通コードになった。

```
e98f95b4fd                         17aeb89200
thread.c                           thread.c
 └─ #include thread_pthread.c        └─ #include thread_sched.c        ← スケジューラ本体（共通）
      └─ #include thread_pthread_mn.c     └─ #include THREAD_IMPL_SRC   ← thread_pthread.c / thread_win32.c
                                               └─ #include thread_sched_mn.c  ← M:N（旧 thread_pthread_mn.c）
                                   thread_sched.h                      ← rb_thread_sched / rb_native_thread（共通）
```

`thread_pthread.c` に残ったのは、プラットフォーム固有の部品だけになった（mutex・cond、TLS、`pthread_create`、スタック、タイマースレッドの epoll/kqueue 部分）。

| 関数 | e98f95b4fd | 17aeb89200 |
|------|-----------|-----------|
| `rb_ractor_sched_wakeup` | `thread_pthread.c:1428` | [`thread_sched.c:1491`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1491) |
| `rb_ractor_sched_wait` | `thread_pthread.c:1391` | [`thread_sched.c:1418`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1418) |
| `ractor_sched_enq` / `ractor_sched_deq` | `thread_pthread.c:1290` / `:1332` | [`thread_sched.c:1302`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1302) / [`:1364`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1364) |
| `native_thread_dedicated_inc` / `_dec` | `thread_pthread.c:1821` | [`thread_sched.c:1858`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1858) / [`:1884`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1884) |
| `nt_start` | `thread_pthread.c:2366` 付近 | [`thread_sched.c:1978`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1978)（SNT のループは [`nt_shared_loop`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L2062) に分離） |
| `native_thread_check_and_create_shared` | `thread_pthread_mn.c:408` | [`thread_sched_mn.c:932`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched_mn.c#L932) |
| `thread_sched_wait_events` | `thread_pthread_mn.c` | [`thread_sched_mn.c:536`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched_mn.c#L536) |
| `timer_thread_register_waiting` | `thread_pthread_mn.c:702` | [`thread_sched_mn.c:1464`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched_mn.c#L1464) |
| `native_thread_create0`（`pthread_create`） | `thread_pthread.c:2185` | [`thread_pthread.c:791`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_pthread.c#L791) |
| `default_max_cpu` | `thread_pthread.c:1802` | [`thread_sched.c:1838`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1838) + [`native_thread_default_max_cpu`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_pthread.c#L911) |

### SNT プールの縮小（wiki の Q6・contributions と重なる）

| コミット | 日付 | 内容 |
|---------|------|------|
| `43793ca21a` | 2026-08-12 | **thread: retire a shared thread the work does not need**。起こされても GRQ が空、が [`SNT_IDLE_RETIRE`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_sched.c#L1350-L1361)（3）回を超えて続いたら、その SNT は自分で終了する（最後の 1 本は残す）。dedicated から戻るときにプールが `max_cpu` に達していれば、その nt も retire する |
| `dce74ebf04` | 2026-08-13 | **thread: free a shared native thread's resources when it retires**。[`native_thread_destroy_self`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/thread_pthread.c#L507-L515) が nt / `nt_context` / altstack を解放する。解放前に `sigaltstack(SS_DISABLE)` で altstack の登録を外す |
| `1da2eea37c` | 2026-08-13 | **thread: remove the unused SNT_KEEP_SECONDS path**。期限を待ちループのたびに計算し直すので、起こされ続ける SNT はタイムアウトしない。さらに `running_cnt` を誤って減らしていた。このため有効化しても役に立たないと判断され、削除された |

`43793ca21a` のコミットメッセージにある計測（8 コア、`RUBY_MAX_CPU=16`、1 リクエストごとに LAN 上の memcached を 1 回参照）:

| 接続数 | 変更前 | 変更後 | ネイティブスレッド数 |
|--------|-------|-------|-------------------|
| 32 | 34,593 req/s | 78,109 req/s | 22 → 8 |
| 128 | 70,805 req/s | 115,424 req/s | 32 → 15 |
| 256 | 25,764 req/s | 112,875 req/s | 45 → 16 |

同じメッセージに「静的レスポンスでも 73,176 → 174,496 req/s（32 接続）」とある。
これは biryani の `-c25 -m50`（静的レスポンス）に近い条件である。

→ [contributions/snt-keep-seconds-enable](../contributions/snt-keep-seconds-enable.md) は**クローズ**（上流で実装済み）。
→ [contributions/snt-replenishment-overhead](../contributions/snt-replenishment-overhead.md) の案 A' は上流で別方式により実現済み。案 A（ヒステリシス）の要否は、`17aeb89200` で取り直したベンチマークで判断する。

### I/O 待ち・タイマー

| コミット | 日付 | 内容 |
|---------|------|------|
| `168eada435` | 2026-08-14 | タイムアウト付き待ちのリスト（O(n) のソート挿入）を、階層タイマーホイール（4 段 × 64 スロット、挿入 O(1)）に置き換えた → [timer-waiting-list-sort](timer-waiting-list-sort.md) の TODO は解決済み |
| `ce15950f56` | 2026-08-29 | M:N の I/O 待ちで fd を `EPOLLONESHOT` で登録し続ける。待ちのたびの `epoll_ctl` が ADD+DEL の 2 回から MOD の 1 回に減った。socketpair 往復で +98〜114%、1 接続 1 Ractor の HTTP サーバーで +10% |
| `3c19a7c1cd` | 2026-08-23 | I/O 待ちの管理を fd ごとに分割した |
| `e1f6ba50da` | 2026-09-10 | 割り込まれた M:N の I/O 待ちを、タイムアウトとして報告しないよう修正 |

`ce15950f56` の恩恵を受けるのは、M:N の epoll パスを使うノンブロッキング I/O だけである。
ブロッキングソケットの biryani は対象外なので、[Q7](../questions/README.md) の実験で比べる価値が上がった
（→ [nonblocking-io-mn-scheduler-path](nonblocking-io-mn-scheduler-path.md)）。

### Ractor 送受信

| コミット | 内容 |
|---------|------|
| `4133daa130` | `ractor_send_basket` が受信側のロックを持ったまま waiter を起こすようにした（`ractor_wakeup_all_locked` に分割）。以前は enqueue → unlock → 再 lock → wakeup で、同じロックを 2 回取っていた |
| `b5d839dbca` | `ractor_basket` を 80 → 48 bytes に縮小 |
| `dea2cdac07` / `742699d231` | copy の Marshal フォールバックを削除し、courier（ヒープ外シリアライズ）に一本化した |
| `d32793fe8e` / `80b867e466` | メッセージ待ちにタイムアウトを指定できるようになった（`ractor_selector__wait` が `end` 期限を受け取る）。別ポートの wakeup でタイムアウトが消える不具合も修正 |
| `acc5cd03d9` | Ractor id を 64 bit 化 |

`ractor_selector__wait` が wakeup のたびに全ポートを `st_foreach` で走査する構造は変わっていない（[`ractor_sync.c:1849`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/ractor_sync.c#L1849-L1874)）。

### per-Ractor GC

`5dd63db8ea`（2026-08-04、NEWS）によると、デフォルトの GC は **Ractor ごと**に動くようになった。
各 Ractor は自分のスレッドで自分のヒープを回収し、他の Ractor は止めない。
全 Ractor を止める GC は、明示的な `GC.start`、shareable オブジェクトの増加、**終了した Ractor のヒープの回収**のときだけ走る。

biryani はストリームごとに Ractor を使い捨てるので、最後の「終了した Ractor のヒープの回収」が頻繁に起きる可能性がある。
→ [ractor-local-gc-status](ractor-local-gc-status.md) は Ruby 4.0.2 時点の記述なので古い。新しい疑問 Q8 として切り出した。

### スケジューラ全般

| コミット | 内容 |
|---------|------|
| `ce6f200972` | `RUBY_MN_THREADS=2` を追加。main スレッドも M:N で動かす。`RUBY_MN_THREADS=-1` で非 main Ractor の M:N も無効化できる |
| `4d764e62a3` | 終了する Ractor をスケジューラ経由で待つ |
| `19db053a7d` | M:N 終了処理での `rb_thread_t` の use-after-free を修正 |

## 関連ページ

- [source-reading-guide](../source-reading-guide.md) — 新しいファイル構成に合わせて更新した
- [ractor-mn-snt-lifecycle](ractor-mn-snt-lifecycle.md)
- [mn-snt-pool-growth-shrink](mn-snt-pool-growth-shrink.md)
- [nonblocking-io-mn-scheduler-path](nonblocking-io-mn-scheduler-path.md)
- [timer-waiting-list-sort](timer-waiting-list-sort.md)
- [ractor-local-gc-status](ractor-local-gc-status.md)
- [../contributions/snt-keep-seconds-enable](../contributions/snt-keep-seconds-enable.md)
- [../contributions/snt-replenishment-overhead](../contributions/snt-replenishment-overhead.md)
- [../questions/README](../questions/README.md)
