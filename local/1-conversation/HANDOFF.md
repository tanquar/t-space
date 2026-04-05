# FrameDesktop — 引き継ぎドキュメント

## プロジェクト概要

macOS用の統合デスクトップ環境。Dock、Stage Manager、AeroSpaceの3つを置き換える自分用ツール。Swiftで実装。

## 核心コンセプト

「枠（フレーム）が先にあって、アプリが後から入る」。ウィンドウがあってレイアウトが決まるのではなく、レイアウトが先に存在し、ウィンドウがそこに格納される。

## 階層モデル

```
Physical Monitor (実機)
  └─ Virtual Monitor (1:1、名前で識別)
       ├─ Workspace (位置+サイズ、複数可)
       │    └─ Board (カルーセルで切り替え可能、複数可)
       │         └─ Slot (位置+サイズ、app-id + title-matchでバインド)
       └─ Overflow (マッチしなかったウィンドウの受け皿)
```

### 各概念の詳細

- **Physical Monitor**: 実際の物理ディスプレイ
- **Virtual Monitor**: 物理モニターと1:1。名前（"Built-in", "PHL", "LG"等）で識別
- **Workspace**: 仮想モニター内の固定区画。座標とサイズを持つ。1モニターに複数配置可能（上半分・下半分など）。Workspaceは親仮想モニターの**フォールバックチェーン**を持つ（例: `["PHL", "LG", "Built-in"]`）。モニターが外れたら次の候補に自動退避、戻ったら復帰
- **Board**: ワークスペース内の差し替え可能なレイアウト。カルーセルで切り替え。同一ワークスペース内で「仕事ボード」「会議ボード」のように用途ごとに切り替え可能
- **Slot**: ボード内の矩形領域。寸法はワークスペースに対する%指定。`app_id`と`title_match`でウィンドウをバインド可能。ピン留め（アプリ終了してもスロット残る）とトランジェント（終了で消える）がある
- **Overflow**: 仮想モニター直下。どのスロットにもマッチしなかったウィンドウが右上→左下にカスケード表示。固定ワークスペースの上にオーバーレイ表示 or 退避の2状態を持つ

### レスポンシブ動作

ワークスペースが退避先で小さくなりスロットが実用サイズ以下になった場合、自動でカルーセルまたはアコーディオン表示に切り替わる。

### アプリタブとの関係

Chrome、iTerm等のアプリ自身のタブ機能はアプリに任せる。スロットのカルーセルはタブ機能を持たないアプリ間の切り替えに使う。

## 現在のプロトタイプ

### 範囲

最小限の「スロット定義に従ってウィンドウを配置する」のみ。

- 設定ファイル（JSON）読み込み
- Accessibility APIでウィンドウ一覧取得
- モニター検出とフォールバック解決
- %指定→絶対座標変換
- app-id + title-matchでウィンドウとスロットをマッチング
- マッチしたウィンドウを所定の座標・サイズに移動

### 未実装

- ボード切り替え（カルーセル）
- Overflow
- ピン留め / トランジェント区別
- アプリ自動起動（スロット選択時に未起動アプリを起動）
- モニター接続/切断の検知と自動切り替え
- レスポンシブ（スロット縮小時のカルーセル/アコーディオン化）
- キーバインド
- 常駐（現在はワンショット実行）

### ファイル構成

```
FrameDesktop/
├── Package.swift                          # Swift Package (macOS 13+)
├── example-config.json                    # サンプル設定
└── Sources/FrameDesktop/
    ├── Main.swift                         # エントリポイント
    ├── Config.swift                       # 設定モデル + JSONロード
    ├── WindowManager.swift                # Accessibility API ラッパー
    ├── MonitorDetection.swift             # モニター検出 + フォールバック解決
    └── LayoutEngine.swift                 # %→絶対座標変換 + マッチング
```

### ビルドと実行

```bash
cd FrameDesktop
swift build
# 設定ファイルを配置
cp example-config.json ~/.framedesktop.json
# 実行（Accessibility権限が必要）
.build/debug/FrameDesktop
```

### 設定ファイル形式

```json
{
  "workspaces": [
    {
      "name": "editor",
      "placements": [
        { "virtual_monitor": "PHL", "left": "0%", "top": "0%", "width": "50%", "height": "100%" },
        { "virtual_monitor": "Built-in", "left": "0%", "top": "50%", "width": "100%", "height": "50%" }
      ],
      "boards": [
        {
          "name": "atonce",
          "slots": [
            {
              "left": "0%", "top": "0%", "width": "100%", "height": "50%",
              "app_id": "com.microsoft.VSCode",
              "title_match": "atonce-api"
            }
          ]
        }
      ]
    }
  ]
}
```

`placements`配列がフォールバックチェーン。上から順に仮想モニターを探し、最初にヒットした配置を使う。

## ユーザーの環境

- macOS、3モニター構成（Built-in, PHL, LG）
- 主要アプリ: iTerm, VS Code (複数プロジェクト), Chrome, Google Chat, MongoDB Compass, Claude, Finder
- 既存のAeroSpace設定あり（hjkl + awsdフォーカス移動、ctrl系キーバインド）
- 慣れたキーバインド体系を尊重すること

## 次のステップ案

1. まずプロトタイプをビルド・実行して動作確認
2. 常駐化（RunLoopで待機、キーバインドで再適用）
3. ボード切り替え（カルーセル）の実装
4. モニター接続/切断の監視と自動再配置
5. Overflow領域の実装
