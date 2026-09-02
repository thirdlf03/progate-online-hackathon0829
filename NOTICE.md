# ライセンスと権利表示

このリポジトリは場所によってライセンスが違う。**まずこの表を見ること。**

| パス | ライセンス | 備考 |
| --- | --- | --- |
| リポジトリ全体(下記の例外を除く) | MIT([`LICENSE`](LICENSE)) | |
| `bridge/` | GPL-3.0-or-later([`bridge/LICENSE`](bridge/LICENSE)) | GPL-3.0 の [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) を同一プロセスで import する派生物のため |
| `desktop/Sources/MihariCore/Resources/voice/` | MIT の対象外 | VOICEVOX と冥鳴ひまりの利用規約に従う(下記「同封音声について」) |
| `desktop/Sources/MihariCore/Resources/pets/` | MIT の対象外 | AI 生成画像。CC0 1.0(権利主張しない。下記「ペット画像について」) |

## 同封音声について

`desktop/Sources/MihariCore/Resources/voice/` の音声(`.m4a`)は、すべて
[VOICEVOX](https://voicevox.hiroshiba.jp/) の音声ライブラリ**冥鳴ひまり**で合成したもの。

クレジット表記は次の文字列をそのまま使うこと。

```
VOICEVOX:冥鳴ひまり
```

利用にあたっては、以下の 2 つの規約に従うこと。

- [VOICEVOX ソフトウェア利用規約](https://voicevox.hiroshiba.jp/term/)
- [冥鳴ひまり利用規約](https://www.meimeihimari.com/terms-of-use)

**この音声を取り出して再利用・再配布する場合も、上記クレジットの表記と両規約の遵守が必要。**
これは VOICEVOX 利用規約の「作成された音声の利用を他者に許諾する際は、当該他者に対し
本許諾内容の 2 及び 3 の遵守を義務付けてください」に基づく義務付けである。

## ペット画像について

`desktop/Sources/MihariCore/Resources/pets/mauve/` のスプライトシートとカットイン画像は、
OpenAI Codex(hatch-pet スキル + 内蔵の画像生成)で開発者が生成した AI 生成画像。

これらについて著作権を主張せず、
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/deed.ja) で提供する。

ペットの形式(8×9 のスプライトシート、`pet.json`)は OpenAI Codex のカスタムペット仕様と互換。

## 配布物に bridge を同梱する場合

`bridge/` とその依存(GPL-3.0 を含む)をバイナリなどに同梱して配布する場合は、GPL-3.0 の条件
(ライセンス文の同梱・対応するソースコードの提供)に従うこと。ソースは本リポジトリで公開されている。
