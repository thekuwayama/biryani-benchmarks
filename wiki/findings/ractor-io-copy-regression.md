---
date: 2026-10-11
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
- **master**: per-Ractor GC に合わせて、コピーもヒープ外の courier にシリアライズする方式に変わった
  - `cd2ea9df6c`（2026-08-19）: courier で運べない型（MatchData、IO、他の T_DATA、特異クラス）は、従来のヒープ上スナップショット経路に残した
  - `68447b1559`（2026-08-19）: そのスナップショット経路を廃止した。courier で運べないものは Marshal で運ぶことになったが、IO は Marshal できない
  - `dea2cdac07`（2026-09-04）: Marshal へのフォールバックも削除された
- その結果、[`copy_courier_supported_p`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/ractor.c#L3188) が T_FILE を拒否し、
  [`ractor_prepare_payload`](https://github.com/ruby/ruby/blob/17aeb89200f13a392c645102800b68b9d16b926b/ractor_sync.c#L1114-L1137) が `can not copy` を投げる

NEWS にはこの挙動変化の記載がない（IO については `80e57a11ca`「`Ractor.make_shareable(io)` が `Ractor::Error`」だけ）。
IO をコピーで渡すテストもないため、意図的な変更か見落としかは分からない。
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
