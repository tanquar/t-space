# t-space 開発進捗

## 2026-04-04

### 設計
- [x] 階層モデル確定: Virtual Monitor → Board → Window (3層)
- [x] 名前空間: 数字=wid, `.`=ボード, `@`=モニター
- [x] コマンド体系: `space ls`, `space tile`, `space show`
- [x] レイアウト文法: `-` 列区切り(低優先), `/` 行区切り(高優先), `:wN` 幅, `:hN` 高さ, `:wNhM` 複合

### 実装
- [x] Swift Package セットアップ (space CLI)
- [x] `space ls monitors` — CoreGraphics + system_profiler でモニター名・解像度・座標取得
- [x] `space ls` — Accessibility API + CGWindowList でウィンドウ一覧取得
- [x] `space ls boards` — ボード一覧表示（wid表示）
- [x] `space tile` — ウィンドウをタイル配置 + 他ウィンドウ退避（フォーカス変更なし）
- [x] `space show` — タイル配置 + 他ウィンドウ退避 + フォーカス
- [x] `space show .board` — 名前付きボードの復元
- [x] `space show <wid>` — ウィンドウ復元（ボード所属→ボード復元、画面外→中央配置）
- [x] `space show @N` — モニターのウィンドウにフォーカス
- [x] メニューバー高さをモニターごとに自動検出
- [x] system_profiler キャッシュ
- [x] 3階層レイアウト: 列(-) → 行(/) → 項目（水平並べ）
- [x] 幅高さ指定: `:w30`, `:h40`, `:w60h40`, `/70`（行高さ）
- [x] wid安定化: cgWindowId↔wid永続マッピング、ウィンドウ開閉でwidが変わらない
- [x] ボード定義にcgWindowIdを保存（widは不安定なので永続化に使わない）
- [x] リプレイ時のcgWindowId/wid衝突防止（preferCgIdフラグ）
- [x] 退避時の状態記録（位置・サイズ・ボード所属）
- [x] 退避エリア→復元時にデフォルトモニター中央配置
- [x] 退避状態の上書き防止（2回目のhideで元の位置を保持）
- [x] Chrome PWA等の管理外ウィンドウをCGWindowList補完で検出
- [x] hideAllExcept: CGWindowListで管理外ウィンドウも退避
- [x] moveWindow: size→position→size順（AeroSpace方式）
- [x] `_` で空席対応
- [x] 入れ子ボード: `tile .main = .dev .web`
- [x] `space daemon` — 常駐モード（NSApplication.shared.run）
- [x] フォーカス変更検出（AXObserver） → 退避ウィンドウの自動復元
- [x] ディスプレイ再構成検出（CGDisplayRegisterReconfigurationCallback）
- [x] スリープ復帰: 700msデバウンスで全ボード自動再配置
- [x] monitorId保持: 復元時にボードのモニター割当を上書きしない
- [ ] ボードなしウィンドウの復元時: モニター全体にリサイズ
