# Overview — Ractor パフォーマンスの総合的理解

最終更新: 2026-05-17

## 現時点の理解

### スループットと `-m` の関係（2026-05-17）

`-m` スイープ（m=1〜100、-c50 固定）の結果：

| `-m` | req/s | latency mean |
|------|-------|--------------|
| 1    | 1,140 | 43ms  |
| 5    | 4,596 | 53ms  |
| 10   | 5,198 | 94ms  |
| 25   | 5,562 | 212ms |
| **50**  | **6,183** | 354ms |
| 100  | 5,984 | 718ms |

**ピークスループットは `-m50`（6,183 req/s）**。`-m100` では逆に低下。4 コア環境で 5,100 Ractor は過剰であり、OS スケジューラのオーバーサブスクリプションが発生。

**レイテンシは `-m` に線形比例**。1送信 = 1 `pthread_cond_broadcast` = 1 futex syscall が根本原因（[[internals/ractor-port-implementation]] 参照）。

### biryani の Ractor 構造

接続ごとに 2 Ractor（Connection + recv_loop）＋ストリームごとに 1 Ractor（Stream）を生成。プールなし。`-c50 -m100` で最大 5,100 Ractor（[[internals/ractor-architecture]] 参照）。

## 未解決の疑問

- `-c`（接続数）を変化させるとどうなるか
- GC はどのようなタイミングで発生し、POST ボディ追加でどう変わるか
- Ractor プールを実装すればスレッド生成コスト（~12%）をどれだけ削減できるか

## 関連ページ

- [[log]]
