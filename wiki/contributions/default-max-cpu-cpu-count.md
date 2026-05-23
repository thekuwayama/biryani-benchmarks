---
date: 2026-05-17
updated: 2026-05-23
type: pr
status: 調査完了・実装待ち
---

# `default_max_cpu` を物理 CPU 数に変更する

## 問題・提案

`thread_pthread.c:1735` のハードコードされた `default_max_cpu = 8` を
実際の物理 CPU 数（`sysconf(_SC_NPROCESSORS_ONLN)` 等）に変更する。

```c
// 現在（thread_pthread.c:1735）
const int default_max_cpu = 8; // TODO: CPU num?

// 提案（etc.c:1014 のパターンに倣う）
#if defined(HAVE_SYSCONF) && defined(_SC_NPROCESSORS_ONLN)
    const int default_max_cpu = (int)sysconf(_SC_NPROCESSORS_ONLN);
#else
    const int default_max_cpu = 8; // fallback for platforms without sysconf
#endif
```

コメント `// TODO: CPU num?` は **ko1（Koichi Sasada）が M:N スケジューラ初回実装時に自分で書いた**
（commit `be1bbd5b7`、2023-04-10）。2 年以上放置されており、PR を出す根拠として強い。

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

### コードの根拠（2026-05-23 調査済み）

**`sysconf` は既に同ファイル群で使用済み**:
- `thread_pthread_mn.c:135`: `sysconf(_SC_PAGESIZE)` をガードなしで使用
- `thread_pthread.c` は POSIX 専用（Win32 は `thread_win32.c`）なので `_WIN32` fallback 不要

**guard パターンの先例**（`ext/etc/etc.c:1014`）:
```c
#if (defined(HAVE_SYSCONF) && defined(_SC_NPROCESSORS_ONLN)) || defined(_WIN32)
```
thread_pthread.c では Win32 分岐は不要なので `HAVE_SYSCONF && _SC_NPROCESSORS_ONLN` で十分。

**TODO コメントの履歴**（`git log -S "TODO: CPU num"` で確認）:
- 導入: ko1（Koichi Sasada）, commit `be1bbd5b7`, 2023-04-10（M:N 初回実装）
- 2 回目の変更（2023-12-31、Shia）: `RUBY_MAX_CPU` 環境変数の適用バグ修正のみ。TODO は手つかず
- 以降 2 年以上放置

詳細: [scenarios/sweep-ruby-max-cpu](../scenarios/sweep-ruby-max-cpu.md)

## 変更量

`thread_pthread.c:1735` の 1 行変更 → `#if` による 3 行に展開。

## 懸念点

- **CPU バウンドワークロードでの影響**: 計算集中型では現行デフォルト 8 が良い場合も（未測定）
- **I/O バウンド vs CPU バウンド**: biryani は I/O バウンドだが、すべてのアプリがそうではない
- **後方互換性**: `RUBY_MAX_CPU` 環境変数で上書き可能なので既存ユーザーへの影響は限定的
- **コンテナ環境**: `sysconf(_SC_NPROCESSORS_ONLN)` は cgroups / CPU affinity を考慮し、割り当て済み CPU 数を返す。コンテナ親和的

## 次のステップ

1. CPU バウンドなベンチマークでも `cpu=物理コア数` vs `cpu=8` を比較する（PR の根拠強化）
2. ruby/ruby に PR を提出する
   - タイトル候補: `Use nprocessors as default_max_cpu for M:N scheduler`
   - 対象ブランチ: `master`
   - レビュアー: ko1（TODO を書いた本人）

## 関連する ruby/ruby のコード

| ファイル | 行 | 内容 |
|----------|---|------|
| `raw/ruby-src/thread_pthread.c` | 1734-1745 | `default_max_cpu = 8` の設定箇所・変更対象 |
| `raw/ruby-src/thread_pthread_mn.c` | 130-139 | `sysconf(_SC_PAGESIZE)` の使用例（ガードなし） |
| `raw/ruby-src/ext/etc/etc.c` | 1014-1121 | `_SC_NPROCESSORS_ONLN` の guard パターン先例 |
| `raw/ruby-src/thread_pthread_mn.c` | 421-423 | `max_cpu` を上限に使う補充条件 |

## git 履歴

| commit | 日付 | 著者 | 内容 |
|--------|------|------|------|
| `be1bbd5b7` | 2023-04-10 | ko1 | M:N 初回実装、`TODO: CPU num?` を追加 |
| `9368782d5` | 2023-12-31 | Shia | `RUBY_MAX_CPU` 適用バグ修正、TODO は手つかず |
