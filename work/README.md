# work/ — WWZ x90 Offline Mod 4.1 ビルド鎖

4.1 (x90) を再生産するのに必要なものだけを残した作業ツリー。

```
work/
  tools/      ビルド・検証スクリプト
  source/     ゲームから抽出した無改造の原本（唯一の入力）
  payloads/   ビルド成果物
  package/    配布パッケージのステージング（= outputs/ と同一バイト）
```

## ビルド

Python はシステムに入っていない。Codex 同梱のランタイムを使う:

```bash
"$USERPROFILE/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe" work/tools/build_payloads.py --multiplier 90 --configs release
```

`--multiplier` は**必須**にしてある。出荷している 4.1 は x90 で、既定値を持たせると
インストーラに焼き込んだ SHA-256 と合わないペイロードが黙って出来上がるため。

出荷済み release ペイロードの SHA-256（インストーラの `ModCompressedSha256` と一致すること）:

```
FF77BF19EA1BECF3D9F6872AC460EDB40C01EA94AB928D8DC4B8311F98DC9F1A
```

Slim パッケージは `release` しか書き換えない。`--configs` を省くと debug/profile も
ビルドされる（フル版用・パッチの汎用性クロスチェック用）。

## インストーラの E2E テスト

```bash
pwsh work/tools/test_installer.ps1 -PakPath <initial.pak のコピー>
```

`-PakPath` は**必ずコピー**を渡すこと（その場で書き換える）。`-OldPayloadDir` に旧版
ペイロードを渡すと、アップグレード経路（phase B）も走る。省略時は phase B をスキップ。

## 絶対に踏んではいけない罠

**1. モジュールを伸ばしたら SSLB ヘッダも直す。**
ファイアーム定数を追記するとモジュールが 9 バイト伸びる。SSLB ヘッダの本体サイズ
(u32 @ offset 12) を書き直さないと、末尾の `__initializer` が宣言サイズの外に出て切り捨てられ、
報酬確定画面でクラッシュする。これが 3.0 のクラッシュの真因。
`build_payloads.py` の `fix_module_header()` が担当し、`verify_config()` が
「宣言サイズ == 実サイズ」をローダ視点で再パースして検証する。

**2. `source/_quarantine/` の中身を原本と間違えない。**
`initial_release.x10_patched.sslbundle` は**原本ではない**。サイズは原本と同じ
14452135 バイトだが、0x2A8AF4 の float が `1.0` → `10.0` に書き換わった x10 時代の成果物。
以前は原本と同じ `initial_release.sslbundle` という名前で `source` 相当の場所に並んでいた。
本物の原本は `source/initial_release.sslbundle`（SHA-256 `2076B157...D606B73`）。

**3. 報酬倍率は既定値では効かない。**
呼び出し側が明示スケールを渡してくる経路があるので、`ScaleAndRound*` の
「引数スケールを積む」命令を、追記した定数を積む命令に差し替えている。

**4. 配布 PS1 は ASCII のみ。**
Windows PowerShell 5.1 は BOM 無しスクリプトを ANSI コードページで読むため、
日本語リテラルを入れると構文エラーになる。ランタイムメッセージは英語で書く。

## オンライン遮断について

**現行の Slim 4.1 にオンラインを遮断する処理は無い。**
`package/WWZ_X90_Offline_Mod.ps1` の `Remove-LegacyFirewallBlock` は、4.1 以前が作った
アウトバウンド遮断ルールを**消す**だけ。代わりにインストール完了時に
「本ビルドは遮断しないのでオンラインに入るな」と警告を出す。

実際に遮断していたのはフル版の `Enable-FirewallBlock`（`New-NetFirewallRule -Direction
Outbound -Action Block -Program <exe>`）。フル版から流用して復活させないこと。
