---
date: 2026-10-11
updated: 2026-10-11
tags: [finding]
---

# master では IO を Ractor にコピーで渡せない（4.0.x からの挙動変化）

Ruby master `17aeb89200` では、`Ractor.new(io)` や `port.send(io)` のように IO（`TCPServer` / `TCPSocket` など）を**コピーで**
Ractor に渡すと `Ractor::Error: can not copy TCPServer object.` になる。Ruby 4.0.5 では同じコードが動く。
`move: true` で渡す場合は両方で動く。biryani 0.0.15 は 2 か所で IO をコピーで渡しているため、**master では 1 リクエストも処理できない**。

## 詳細

### 再現

```ruby
require 'socket'
s = TCPServer.new(0)
Ractor.new(s) { |x| x.class }.value                     # 4.0.5: TCPServer / master: Ractor::Error
r = Ractor.new { Ractor.receive.class }
r.send(TCPServer.new(0), move: true); r.value           # 両方: TCPServer
```

| | 4.0.5 | master `17aeb89200` |
|---|---|---|
| `Ractor.new(io)`（コピー） | 動く | `Ractor::Error: can not copy TCPServer object.` |
| `port.send(io, move: true)` | 動く | 動く |
| `Ractor.shareable?(io)` | false | false |

### 原因

- **4.0.x**: コピーは `ractor_copy` → `copy_enter` → `ractor_obj_clone` で、shareable でないオブジェクトを `#clone` する。
  IO の `#clone` は fd を dup するので、受け取った側は別の fd を持つ IO を得る（`doc/language/ractor.md` の「All unshareable objects will be `Kernel#clone`ed」）
- **master**: per-Ractor GC で、コピーは `#clone` を呼ばない方式に変わった
  - `d549b394dc`（2026-08-01、per-Ractor GC 本体。[ruby/ruby#18194](https://github.com/ruby/ruby/pull/18194) として 2026-08-07 にマージ）: コピーが `ractor_obj_clone` から native copier（`ractor_copy_native_try`）に置き換わった。
    native copier（`ractor_native_shallow_copy`）は T_FILE に対応しておらず、Marshal にフォールバックする。IO は Marshal できないので、**この時点で IO をコピーで渡せなくなった**
  - PR #18194 の設計説明には「copy は core 型を native copier で運び、ユーザーから見える `#clone` やフックは呼ばない。それ以外は Marshal」とある。`#clone` をやめたのは意図的だが、IO のコピーが失われることへの言及はない
  - `cd2ea9df6c` / `68447b1559`（2026-08-19）でコピーもヒープ外の courier に移り、`dea2cdac07`（2026-09-04）で Marshal フォールバックも削除された。IO が運べない状態は変わっていない
  - （2026-10-11 訂正: 当初は `68447b1559` で壊れたと推定していたが、誤りだった）
- その結果、[`copy_courier_supported_p`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/ractor.c#L3188) が T_FILE を拒否し、
  [`ractor_prepare_payload`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/ractor_sync.c#L1114-L1137) が `can not copy` を投げる

NEWS にはこの挙動変化の記載がない（IO については `80e57a11ca`「`Ractor.make_shareable(io)` が `Ractor::Error`」だけ）。
IO をコピーで渡すテストもないため、意図的な変更か見落としかは分からない。
courier のコピーは Marshal と同じフック（`marshal_dump` / `_dump` / `_dump_data` / compat）を見るので、クラス側でフックを定義すれば運べるようになる。ただ IO はどれも定義しておらず、IO 向けの準備（fd を `dup` する処理など）もない。
2026-10-11 時点で、上流 master の先頭は `17aeb89200` のまま。IO のコピーに触れた PR や issue も見つからなかった。
per-Ractor GC の提案（[Feature #22227](https://redmine.ruby-lang.org/issues/22227)）でも、IO については move の話しか出てこない。

### biryani への影響

biryani 0.0.15 は次の 2 か所で IO をコピーで渡している。

- `server.rb`: `Ractor.new(socket.accept, @proc)`
- `connection.rb` の `recv_loop`: `Ractor.new(io, @port)`（`io` は `serve` 内で `io.clone` したもの）

ベンチマークでは、この 2 か所を move に差し替えるシム（`load/ractor_io_move_shim.rb`）を 4.0.5 と master の両方に読み込んで比較した（→ [scenarios/ruby-master-vs-405](../scenarios/ruby-master-vs-405.md)）。
同じ理由で、ベンチマークスクリプト側の `Ractor.new(socket)` も、TCPServer を Ractor 内で開く形に変えた。

## 関連ページ

- [contributions/ractor-io-copy-regression](../contributions/ractor-io-copy-regression.md)
- [scenarios/ruby-master-vs-405](../scenarios/ruby-master-vs-405.md)
- [internals/upstream-scheduler-changes-2026](../internals/upstream-scheduler-changes-2026.md)
- [internals/biryani-ractor-architecture](../internals/biryani-ractor-architecture.md)
