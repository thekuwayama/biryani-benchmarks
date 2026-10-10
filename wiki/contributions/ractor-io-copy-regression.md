---
date: 2026-10-11
type: issue
status: 候補
---

# master で IO を Ractor にコピーで渡せなくなった（4.0.x では動く）

## 問題・提案

Ruby 4.0.x では `Ractor.new(io)` / `port.send(io)`（コピー）で IO を Ractor に渡せた（`#clone` で fd が dup される）。
master `17aeb89200` では `Ractor::Error: can not copy TCPServer object.` になる。
NEWS に記載がなく、テストもないため、per-Ractor GC に伴うコピー経路の作り直し（courier 化）で生じた**意図しない挙動変化**の可能性がある。

issue として確認したいこと:

1. 意図的な変更か。意図的なら NEWS（Compatibility issues）に載せ、「IO は `move: true` で渡す」と案内すべきではないか
2. 意図しない変更なら、IO のコピー（fd の dup）を courier で扱えるようにする

## 根拠（ベンチマーク・プロファイラ結果へのリンク）

- 再現コードと原因: [findings/ractor-io-copy-regression](../findings/ractor-io-copy-regression.md)
- 実害の例: biryani 0.0.15（`server.rb` の `Ractor.new(socket.accept, @proc)`、`connection.rb` の `Ractor.new(io, @port)`）が master で 1 リクエストも処理できない

## 関連する ruby/ruby のコード

| ファイル | 行 | 内容 |
|----------|---|------|
| [`ractor.c`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/ractor.c#L3188) | 3188 | `copy_courier_supported_p`: hook のない T_FILE は `default:` で false |
| [`ractor_sync.c`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/ractor_sync.c#L1114-L1137) | 1114-1137 | `ractor_prepare_payload`: courier に載らなければ `can not copy` |
| `ractor.c`（`e98f95b4fd`） | — | 旧実装の `copy_enter` → `ractor_obj_clone`（IO は `#clone` で fd を dup） |

関連コミット: `d549b394dc`（2026-08-01、per-Ractor GC 本体。コピーが `#clone` から native copier + Marshal に変わり、ここで IO が運べなくなった）、`cd2ea9df6c` / `68447b1559`（courier 化）、`dea2cdac07`（Marshal フォールバック削除）

## 次のステップ

1. 変化を起こしたコミットをビルドして確かめる（コード上は `d549b394dc` で壊れている。その直前と直後で `Ractor.new(io)` を試す）
2. bugs.ruby-lang.org と [Feature #22227](https://redmine.ruby-lang.org/issues/22227) で既出かを確認する（2026-10-11 時点では、#22227 の議論に IO のコピーへの言及はなかった）
3. 意図的な変更なら、biryani 側で IO を move で渡すよう直す（biryani はユーザーのリポジトリ）
