---
name: t-space project overview
description: macOS統合デスクトップ環境、spaceコマンドでウィンドウ管理。tile/show/daemon構成。
type: project
---

t-spaceはmacOS用のタイル型ウィンドウマネージャ（Swift CLI）。

**コマンド体系:**
- `space ls` — ウィンドウ/ボード/モニター一覧
- `space tile` — ウィンドウ配置+他を退避（フォーカス変更なし）
- `space show` — ウィンドウ配置+他を退避+フォーカス
- `space daemon` — 常駐モード（フォーカス監視+ディスプレイ再構成対応）

**レイアウト文法:**
- `-` 列区切り（低優先）, `/` 行区切り（高優先）
- `:wN` 幅, `:hN` 高さ, `:wNhM` 複合, `/N` 行高さ

**ID体系:**
- wid: 1ベース連番（ユーザー入力用、永続化）
- cgWindowId: CGWindowID（ボード定義の永続化用）

**Why:** 3モニター環境でのワークスペース切替を高速化するため。
**How to apply:** tileは配置のみ、showはフォーカス管理込み。daemonがスリープ復帰時に自動復元。
