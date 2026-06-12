---
date: 2026-05-24
tags: [internals]
---

# M:N スケジューラ：SNT プールの成長と縮小

`max_cpu` と `SNT_KEEP_SECONDS` の 2 パラメータがそれぞれ SNT プールの
「成長の上限」と「縮小の速度」を担い、セットで機能する設計になっている。
現在は `max_cpu` のみが設定されており（マージ済み（e98f95b4fd）で物理コア数に変更）、
縮小側の `SNT_KEEP_SECONDS = 0` が無効のまま。

## SNT の状態遷移

SNT は「共有（Shared）」「専有（Dedicated）」「アイドル（Idle）」の 3 状態を遷移する。

```mermaid
stateDiagram-v2
    [*] --> Shared : pthread_create
    Shared --> Dedicated : IO#read 開始 / dedicated_inc
    Dedicated --> Shared : IO#read 完了 / dedicated_dec
    Shared --> Idle : GRQ が空になった
    Idle --> Shared : 新 Ractor が到着
    Idle --> [*] : タイムアウト / SNT_KEEP_SECONDS 秒後

    note right of Idle
        SNT_KEEP_SECONDS = 0 の場合
        タイムアウトしない
        → 永続化（縮まらない）
    end note
```

Dedicated 状態は一時的（IO の完了まで）で、完了後は必ず Shared に戻る。
Idle → 終了 のパスが `SNT_KEEP_SECONDS` で制御される唯一の縮小経路。

## 2 パラメータの役割

```mermaid
flowchart LR
    subgraph 成長の制御
        A["IO#read 開始<br>dedicated_inc<br>snt_cnt↓"] --> B{"snt_cnt<br>< max_cpu?"}
        B -- Yes --> C["pthread_create<br>SNT 追加<br>snt_cnt↑"]
        B -- No --> D[補充なし]
    end

    subgraph 縮小の制御
        E["IO#read 完了<br>dedicated_dec<br>snt_cnt↑ 過剰"] --> F{"SNT が<br>アイドルに<br>なったか?"}
        F -- Yes --> G{"SNT_KEEP_SECONDS<br>> 0?"}
        F -- "No: 仕事あり" --> H[SNT 継続稼働]
        G -- "No: 現在の設定" --> I["永続化<br>縮まらない"]
        G -- Yes --> J["N 秒後に終了<br>snt_cnt↓"]
    end
```

| パラメータ | 制御対象 | 現在の値 |
|-----------|---------|--------|
| `max_cpu` | SNT の増える上限 | ~~8~~ → マージ済み（e98f95b4fd）で物理コア数に変更 |
| `SNT_KEEP_SECONDS` | アイドル SNT の生存時間 | **0 = 永久に消えない** |

## 時系列シナリオ：max_cpu = 2 の場合

### 共通の前提

- `max_cpu = 2`、`MINIMUM_SNT = 0`
- Ractor が 10 個、全員が定期的に `IO#read` を呼ぶ
- タイマー間隔 ≈ 10 ms

### ケース A：SNT_KEEP_SECONDS = 0（現在のデフォルト）

```mermaid
sequenceDiagram
    participant RA as Ractor A
    participant S1 as SNT-1
    participant TM as Timer Thread
    participant PL as SNT Pool

    Note over PL: snt_cnt=2（SNT-1, SNT-2 稼働中）

    RA->>S1: IO#read 開始
    S1->>PL: dedicated_inc
    Note over PL: snt_cnt=1, dnt_cnt=1

    TM->>PL: タイマー発火（10ms後）check_and_create
    Note over PL: snt_cnt(1) < max_cpu(2) → pthread_create
    PL-->>PL: SNT-3 誕生
    Note over PL: snt_cnt=2, dnt_cnt=1

    RA->>S1: IO#read 完了（～100ms後）
    S1->>PL: dedicated_dec
    Note over PL: snt_cnt=3, dnt_cnt=0<br/>max_cpu(2) を超過!

    Note over PL: GRQ に仕事あり → SNT-3 も稼働<br/>3本が max_cpu=2 を超えて活動中

    Note over TM: 〜〜 負荷が落ちる 〜〜

    TM->>PL: タイマー発火（繰り返し）check_and_create
    Note over PL: snt_cnt(3) < max_cpu(2)? → NO<br/>補充なし

    Note over PL: 1時間後も snt_cnt=3 のまま<br/>プールは永久に縮まない
```

### ケース B：SNT_KEEP_SECONDS = 5

```mermaid
sequenceDiagram
    participant RA as Ractor A
    participant S1 as SNT-1
    participant TM as Timer Thread
    participant PL as SNT Pool

    Note over PL: snt_cnt=2（SNT-1, SNT-2 稼働中）

    RA->>S1: IO#read 開始
    S1->>PL: dedicated_inc
    Note over PL: snt_cnt=1

    TM->>PL: check_and_create → SNT-3 誕生
    Note over PL: snt_cnt=2

    RA->>S1: IO#read 完了
    S1->>PL: dedicated_dec
    Note over PL: snt_cnt=3（過剰）

    Note over TM: 〜〜 負荷が落ちる 〜〜

    Note over PL: SNT-3 が GRQ 空で待機開始<br/>native_cond_timedwait(5秒)

    TM-->>PL: 5秒後タイムアウト → SNT-3 終了
    Note over PL: snt_cnt=2

    TM-->>PL: さらに 5 秒後 → SNT-2 終了
    Note over PL: snt_cnt=1

    TM-->>PL: さらに 5 秒後 → SNT-1 終了
    Note over PL: snt_cnt=0<br/>プールが縮小して空に
```

## biryani（常時高負荷 IO）での振る舞い

biryani では `IO#read` が wall time の 47.9% を占め、常時 dedicated_inc/dec が発生する。

```mermaid
sequenceDiagram
    participant R1 as Ractor 群
    participant TM as Timer Thread
    participant PL as SNT Pool

    Note over PL: snt_cnt=4（max_cpu=4、PR 提出後）

    R1->>PL: IO#read 多発 → dedicated_inc × 3
    Note over PL: snt_cnt=1

    TM->>PL: check_and_create（タイマー発火）
    Note over PL: snt_cnt(1) < max_cpu(4) → pthread_create<br/>thread_create_core ~10% のコスト発生

    TM->>PL: check_and_create（次のタイマー発火）
    Note over PL: snt_cnt(2) < max_cpu(4) → pthread_create

    R1->>PL: IO#read 完了 × 3 → dedicated_dec × 3
    Note over PL: snt_cnt=7（max_cpu=4 を大きく超過）

    Note over PL: GRQ に仕事あり → 7本全員稼働<br/>SNT_KEEP_SECONDS=0 なのでアイドルにならない<br/>タイムアウトせず永続化

    Note over TM: 以降、snt_cnt(7) >= max_cpu(4)<br/>check_and_create: 補充なし<br/>逆説的に「過剰 SNT がバッファ」になる
```

**逆説的な効果**: 常時高負荷では、蓄積した extra SNT が次の IO drop のバッファになり、
`pthread_create` の頻度を下げる。しかし負荷が落ちたとき（夜間・連休後）に
余剰 SNT が大量に残存してメモリとスケジューラのオーバーヘッドを占有し続ける。

## 非対称構造のまとめ

```mermaid
flowchart TD
    A["Ractor.new / IO#read"] -->|"snt_cnt 低下"| B["check_and_create<br>（max_cpu が上限）"]
    B -->|pthread_create| C["SNT 追加<br>thread_create_core ~10%"]

    D["IO#read 完了"] -->|"snt_cnt 回復・過剰"| E{SNT_KEEP_SECONDS}
    E -->|"= 0（現在）"| F["🔴 プール縮小なし<br>永続化"]
    E -->|"> 0（案）"| G["⏱ N 秒アイドルで終了<br>プール縮小"]

    style F fill:#fdd,stroke:#f00
    style G fill:#dfd,stroke:#0a0
```

`max_cpu`（上限）はマージ済み（e98f95b4fd）。`SNT_KEEP_SECONDS`（縮小）が次の候補。

## 関連ページ

- [source-reading-guide](../source-reading-guide.md) — ソースコード読み方ガイド
- [findings/snt-keep-seconds-disabled](../findings/snt-keep-seconds-disabled.md)
- [internals/ractor-overview](ractor-overview.md) — GRQ の定義・SNT の概要
- [internals/ractor-mn-snt-lifecycle](ractor-mn-snt-lifecycle.md)
- [contributions/snt-replenishment-overhead](../contributions/snt-replenishment-overhead.md)
- [contributions/default-max-cpu-cpu-count](../contributions/default-max-cpu-cpu-count.md)
