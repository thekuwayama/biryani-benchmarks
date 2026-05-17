---
date: 2026-05-17
type: pr
status: 候補
---

# `default_max_cpu` を物理 CPU 数に変更する

## 問題・提案

`thread_pthread.c:1735` のハードコードされた `default_max_cpu = 8` を
実際の物理 CPU 数（`sysconf(_SC_NPROCESSORS_ONLN)` 等）に変更する。

```c
// 現在（thread_pthread.c:1735）
const int default_max_cpu = 8; // TODO: CPU num?

// 提案
#ifdef _SC_NPROCESSORS_ONLN
    const int default_max_cpu = (int)sysconf(_SC_NPROCESSORS_ONLN);
#else
    const int default_max_cpu = 8; // fallback
#endif
```

コメント `// TODO: CPU num?` が、開発者自身がこの変更を検討していることを示している。

## 根拠

### ベンチマーク（biryani, Lima VM 4コア, -c25 -m50）

| RUBY_MAX_CPU | req/s | 対デフォルト比 |
|---|---|---|
| 4（物理コア数） | 8,456 | **+3.1%** |
| 8（現在のデフォルト） | 8,205 | 基準 |
| 16 | 6,732 | -18.0% |
| 32 | 4,652 | -43.3% |

- 物理コア数（4）と一致するときにピーク
- 超えるほど急速に性能劣化

### 理論的根拠

- SNT（Shared Native Thread）は OS スレッド
- 物理コア数を超える SNT は OS スケジューラがコンテキストスイッチで処理
- コンテキストスイッチコスト > 多 SNT のメリット（I/O バウンドでも）

### コードの根拠

`Etc.nprocessors` は `sysconf(_SC_NPROCESSORS_ONLN)` を使い、
Linux/macOS/BSD でアフィニティを考慮した CPU 数を返す（`etc.c:1098`）。
同等の C コードは `thread_pthread.c` に追加可能。

詳細: [[scenarios/sweep-ruby-max-cpu]]

## 変更量

`thread_pthread.c:1735` の 1 行変更（+ `#ifdef` による条件分岐）。

## 懸念点

- **CPU バウンドワークロードでの影響**: 計算集中型では現行デフォルト 8 が良い場合も
- **I/O バウンド vs CPU バウンド**: biryani は I/O バウンドだが、すべてのアプリがそうではない
- **後方互換性**: `RUBY_MAX_CPU` 環境変数で上書き可能なので既存ユーザーへの影響は限定的
- **他プラットフォーム**: Win32 は `GetSystemInfo` で CPU 数取得（既に実装あり？）

## 次のステップ

1. CPU バウンドなベンチマークでも `cpu=4` vs `cpu=8` を比較する
2. `Etc.nprocessors` の C 相当コード（`sysconf`）が `thread_pthread.c` で使えるか確認
3. `// TODO: CPU num?` コメントのある commit 履歴を調べ、意図的な設計かを確認
   - `git log -S "TODO: CPU num"` で追う
4. ruby-dev / GitHub で「物理 CPU 数にすることを検討しているか」と問い合わせる
5. 賛同を得たら PR 作成

## 関連する ruby/ruby のコード

| ファイル | 行 | 内容 |
|----------|---|------|
| `raw/ruby-src/thread_pthread.c` | 1734-1745 | `default_max_cpu = 8` の設定箇所 |
| `raw/ruby-src/ext/etc/etc.c` | 1098-1115 | `Etc.nprocessors`（`sysconf` 利用） |
| `raw/ruby-src/thread_pthread_mn.c` | 421-423 | `max_cpu` を上限に使う補充条件 |
