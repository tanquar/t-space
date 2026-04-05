# t-space 設計ドキュメント

## 1. 概要

macOS用の統合デスクトップ環境。Dock、Stage Manager、およびサードパーティのタイル型ウィンドウマネージャを置き換える自分用ツール。

核心コンセプト: **「枠（フレーム）が先にあって、アプリが後から入る」**。統一された `space` コマンドで、ウィンドウとボードを同じ文法で配置する。

## 2. 階層モデル

```
Physical Monitor (実機ディスプレイ)
  └─ Virtual Monitor (1:1、名前で識別)
       └─ Board (名前付き / 番号付き / 無名)
            └─ Window (タグで識別、最小管理単位)
```

3層構造。ボードが仮想モニター直下に置かれる。

### 2.1 Physical Monitor

実際の物理ディスプレイ。システムが自動検出する。

### 2.2 Virtual Monitor

- 物理モニターと1:1で対応
- `@` プレフィクスで参照: `@1`, `@PHL`, `@Built-in`
- 常に無名ボードを1つ持つ（タグなしウィンドウの受け皿）

### 2.3 Board

ウィンドウまたは子ボードを含むコンテナ。`.` プレフィクスで参照する。

| 種類 | 表記 | スコープ | ライフサイクル |
|------|------|---------|----------------|
| 無名ボード | (なし) | モニターごとに1つ | 常に存在。タグなしウィンドウの受け皿 |
| 番号付きボード | `.1`, `.2` | グローバル連番 | 一時的。`space tile` で自動生成 |
| 名前付きボード | `.web`, `.doc` | グローバル一意 | 永続（設定ファイルに保存可） |

番号付きボードと名前付きボードの違いは自動生成か手動命名かのみ。挙動は同じ。どちらもグローバルに一意で、任意のモニターに表示・移動できる。

#### 入れ子

ボードはウィンドウだけでなく他のボードも含むことができる。

```
space tile a b .web            → ウィンドウを含むボード
space tile .web / .res .coding → ボードを含むボード
```

> **命名Tips**: ボード名には `.` を含めてよい。入れ子のボードに `..coding` のように `.` を重ねると、深さが視覚的にわかりやすくなる。ただしシステム上の区別はなく、すべて同じボードとして扱われる。

#### フォールバック

ボード単位でフォールバック先を指定可能。モニター切断時に自動退避、復帰時に戻る。

```
space .web fallback:@Built-in
```

### 2.4 Window

最小の実体管理単位。macOSのウィンドウ1枚に対応する。

- **識別**: macOS window ID（セッション内で一意、数字で参照。再起動で変わる）
- **タグ**: ユーザーが付与する短縮名。ボードへの割り当てに使う
- **属性** (読み取り専用):
  - `app_id`: バンドルID
  - `title`: ウィンドウタイトル
  - `app_name`: アプリ名

### 2.5 Slot

名前付きボード内の矩形領域。ウィンドウの「席」。

- 位置・サイズ: `space tile` コマンドのレイアウト指定から決定される
- パターンバインド（任意）: ウィンドウを自動的にスロットに割り当てる条件
  - `app_id`: バンドルID
  - `title`: タイトルの正規表現
- 状態:
  - **占有**: ウィンドウが配置されている
  - **空枠**: パターンは定義済みだがウィンドウが不在（未起動等）。枠だけ表示しスペースを確保
  - **空き**: パターン未設定、ウィンドウ未割当

## 3. 名前空間

リソースの種類をプレフィクスで区別する。

| プレフィクス | 対象 | 例 |
|-------------|------|-----|
| (数字) | ウィンドウID（システム付与） | `1`, `3`, `12` |
| (英字) | ウィンドウタグ（ユーザー付与） | `cw`, `tw`, `px` |
| `.` | ボード | `.1`, `.web`, `.review` |
| `@` | 仮想モニター | `@1`, `@PHL`, `@Built-in` |

アドレス表記: `@{monitor}.{board}` (例: `@1.2`, `@PHL.web`)

## 4. コマンド体系

全操作は `space` サブコマンドで統一する。

### 4.1 ヘルプ

```
space                            # 簡易ヘルプ表示
```

### 4.2 一覧表示 (`space ls`)

```
space ls                         # 全リソースのサマリー
space ls monitors                # モニター・仮想モニター一覧
space ls boards                  # ボード一覧
space ls windows                 # ウィンドウ一覧
space ls tags                    # タグ一覧
```

#### `space ls windows` 出力例

```
id  tags    board  app     title
1   cw      .web   Chrome  Google Docs - 議事録
2   -       -      Chrome  Wikipedia - Rust
3   tw      .web   iTerm2  ~/web
4   px      .2     Preview sample.pdf
5   -       -      Finder  ~/web
```

#### `space ls boards` 出力例

```
board      monitor  windows
@1.1       @1       cw tw
@1.2       @1       px pn
@2.1       @2       a1 f1
@2.2       @2       a2 f2
@PHL.web   @PHL     cw tw
```

### 4.3 タグ操作 (`space tag` / `space untag`)

`tag` はタグ名を定義し、対象をバインドする汎用操作。

```
space tag cw 1                   # ウィンドウタグ "cw" を定義、window ID 1 をバインド
space tag tw 3                   # ウィンドウタグ "tw" を定義、window ID 3 をバインド
space tag .web cw tw             # ボード ".web" を定義、ウィンドウタグ cw, tw をバインド
space untag cw 1                 # window ID 1 から "cw" タグを除去
```

`.` の有無で対象レベルが変わる:

| コマンド | 意味 |
|---------|------|
| `space tag cw 1` | ウィンドウ 1 に短縮名 "cw" を付与 |
| `space tag .web cw tw` | ウィンドウタグ cw, tw をボード .web に所属させる |

### 4.4 タイル配置 (`space tile`)

ウィンドウまたはボードをタイル表示する。

#### ウィンドウの配置（ボード内レイアウト）

```
space tile cw tw                 # 横並び 50:50。番号ボード自動生成
space tile cw tw .web            # 横並び 50:50。名前付きボード .web
space tile cw:30 tw              # [cw 30%][tw 70%]
space tile cw tw / f             # 上段 [cw][tw]、下段 [f]
space tile cw tw / px pn         # クアドラント
space tile cw tw @PHL            # モニター @PHL に配置
space tile cw tw .web @PHL       # ボード名 + モニター指定
```

#### ボードの配置（モニター上レイアウト）

```
space tile .web .res             # [.web][.res] 横並び
space tile .web:30 .res:70       # 比率指定
space tile .web / .res           # 上下段積み
space tile .web / .res .coding   # ボード配置に "coding" と命名（入れ子ボード）
```

#### レイアウトモード

**行優先（デフォルト / `--horizontal-layout`）**

グループ = 行。行内のアイテムは横並び。`/` で行を区切る。

```
space tile cw:30 tw / px pn
→ [cw 30%][tw 70%]  50%
  [px    ][pn    ]  50%

space tile --horizontal-layout h=40 cw:30 tw / px pn
→ [cw 30%][tw 70%]  40%
  [px    ][pn    ]  60%
```

**列優先（`--vertical-layout`）**

グループ = 列。列内のアイテムは縦並び。`/` で列を区切る。

```
space tile --vertical-layout cw:30 tw / px pn
→ [cw 30%] [px    ]
  [tw 70%] [pn    ]
  ← 50% →  ← 50% →

space tile --vertical-layout w=40 cw:30 tw / px pn
→ [cw 30%] [px    ]
  [tw 70%] [pn    ]
  ← 40% →  ← 60% →
```

#### レイアウト文法まとめ

```
スペース区切り     = グループ内並び     space tile a b      → [a][b]
/                 = グループ区切り     space tile a / b    → [a]
                                                           [b]
:N                = アイテムの比率%    space tile a:30 b   → [a 30%][b 70%]
h=N               = 行の高さ%（行優先時）
w=N               = 列の幅%（列優先時）
--horizontal-layout  行優先モード（デフォルト）
--vertical-layout    列優先モード
```

比率を省略した場合は均等分割。

### 4.5 表示切替 (`space show`)

モニター上のアクティブボードを切り替える。

```
space show .web                  # .web を所属モニターに表示
space show .web @2               # .web をモニター @2 に表示（移動）
space show .web --focus cw       # .web を表示し、ウィンドウ cw にフォーカス
space show .2                    # ボード .2 を所属モニターに表示
```

#### フォーカスのルール

1. `--focus <tag>` 指定時 → そのウィンドウにフォーカス
2. 最後にフォーカスしていた記録があれば → そこに復帰
3. いずれもなければ → 左上のウィンドウにフォーカス

#### 切り替え時のウィンドウ

表示対象外になったボードのウィンドウは:

- **非表示になるだけ**。位置・状態を保持し、戻せば復元
- 実装上は画面外（実モニター右下に1px表示）に退避する可能性あり（macOSの制約）

### 4.6 スロット操作 (`space bind` / `space unbind`)

スロットにパターンを設定し、起動時にウィンドウを自動割当:

```
space bind .web.1 app:com.google.Chrome title:/議事録/
space bind .web.2 app:com.googlecode.iterm2 title:~/web
space unbind .web.1
```

## 5. タグシステム

### 5.1 タグの性質

- 短い文字列ラベル
- `tag` コマンドは階層を問わない汎用バインド操作
  - ウィンドウタグ: ウィンドウに短縮名を付与
  - ボードタグ (`.` 付き): ウィンドウをボードに所属させる

### 5.2 タグの付与方法

| 方法 | 永続性 | 例 |
|------|--------|-----|
| 手動付与 | セッション中のみ | `space tag cw 1` |
| パターン自動付与 | 永続（設定ファイル） | tag_rules で app_id + title に基づき起動時に自動付与 |

### 5.3 パターン自動付与 (tag_rules)

設定ファイルにパターンを定義し、ウィンドウ出現時に自動でタグ付与:

```json
{
  "tag_rules": [
    { "tag": "cw", "match": { "app_id": "com.google.Chrome", "title_match": "議事録" } },
    { "tag": "tw", "match": { "app_id": "com.googlecode.iterm2", "title_match": "~/web" } }
  ]
}
```

## 6. 初期状態と構造の成長

設定なしの起動時:

```
1. 全ウィンドウ → 無名ボード → メイン仮想モニター
2. space tag cw 1                  → window 1 に "cw"
3. space tag tw 3                  → window 3 に "tw"
4. space tile cw tw                → .1 自動生成（グローバル連番）、タイル表示
5. space tile cw tw .web           → 名前付きボード .web に昇格
6. space tag .web cw tw            → cw, tw を .web に所属
7. space bind .web.1 app:... title:...  → パターンで永続化
```

構造はユーザーの操作に応じて成長する。最初から定義する必要はない。

## 7. 自動タイルレイアウト

`space tile` で比率を省略した場合の自動配置:

```
1枚: 全画面
2枚: 左右 50:50
3枚: 左50% + 右上下 各50%
4枚: 2x2 グリッド
5枚以上: 行数を増やして均等分割
```

## 8. レスポンシブ動作

ボードがフォールバック先で小さくなった場合:

- スロットが実用サイズ以下 → カルーセルまたはアコーディオン表示に自動切り替え
- 閾値は設定可能

## 9. データモデル

### 9.1 設定ファイル (`~/.t-space.json`)

```json
{
  "virtual_monitors": {
    "Built-in": { "fallback_priority": 3 },
    "PHL":      { "fallback_priority": 1 },
    "LG":       { "fallback_priority": 2 }
  },
  "boards": [
    {
      "name": "web",
      "monitor": "PHL",
      "fallback": "Built-in",
      "layout": "cw tw",
      "slots": [
        {
          "position": 1,
          "bind": { "app_id": "com.google.Chrome", "title_match": "議事録" }
        },
        {
          "position": 2,
          "bind": { "app_id": "com.googlecode.iterm2", "title_match": "~/web" }
        }
      ]
    }
  ],
  "layouts": [
    { "name": "coding", "definition": ".web / .res" },
    { "name": "review", "definition": ".doc .res" }
  ],
  "tag_rules": [
    { "tag": "cw", "match": { "app_id": "com.google.Chrome", "title_match": "議事録" } },
    { "tag": "tw", "match": { "app_id": "com.googlecode.iterm2", "title_match": "~/web" } }
  ]
}
```

### 9.2 ランタイム状態

```
WindowState {
  id: macOS window ID
  app_id: String
  app_name: String
  title: String
  tag: String?               // ユーザー付与タグ (nil = 無名ボード)
}

BoardState {
  name: String?              // nil = 無名, "1" = 番号付き, "web" = 名前付き
  children: [BoardChild]     // ウィンドウ or 子ボード
  layout: Layout             // 配置定義
  monitor: VirtualMonitorRef // 所属モニター
  fallback: VirtualMonitorRef?
  is_visible: Bool           // 現在表示中か
  last_focused: WindowRef?   // 最後にフォーカスしたウィンドウ
}

enum BoardChild {
  case window(WindowRef)
  case board(BoardRef)
}

Layout {
  rows: [[LayoutItem]]       // 行ごとのアイテム列
}

LayoutItem {
  ref: BoardChild
  width_percent: Int?        // nil = 均等分割
}

SlotState {
  rect: Rect                 // 算出済み絶対座標
  bind: BindPattern?
  window: WindowRef?
}
```

## 10. 起動シーケンス

```
1. 設定ファイル読み込み
2. 物理モニター検出 → 仮想モニター構築
3. ボードのフォールバック解決 → 配置先モニター確定
4. 全ウィンドウ取得
5. tag_rules に基づきタグ自動付与
6. 名前付きボードのスロット bind に基づきウィンドウ配置
7. タグなしウィンドウ → 無名ボード
8. layouts の定義に基づきボードを配置
9. コマンド入力待ち（常駐）
```

## 11. 技術選択

- **言語**: Swift
- **対象OS**: macOS 13+
- **ウィンドウ操作**: Accessibility API (AXUIElement)
- **モニター検出**: CoreGraphics (CGGetActiveDisplayList, CGDisplayBounds)
- **非表示ウィンドウ**: 画面外退避（右下1px表示）— macOSではウィンドウの完全非表示はAPI制限あり
- **UI**: コマンドライン（将来的にメニューバーアイコン検討）
- **常駐**: RunLoop / DispatchSource

## 12. 未決事項

- [x] ~~キーバインド体系~~ → vi風モード。CUI整備後にエイリアスとして実装。以下は暫定案:
  - 起動: `cmd-ctrl-s` や `cmd-tab` 等でモードに入る
  - `hjkl` フォーカス移動、`HJKL` 隣接スロットとスワップ
  - `np` ボード切替、`NP` 隣接ボードとスワップ
  - `S` 全リソースリスト、`s{w,b,m,t}` 各種リスト
  - `b{name}` 名前付きボードにフォーカス、`B{name}` ボード定義
  - `r,R` スロット幅増減、`c,C` スロット高さ増減
- [x] ~~ウィンドウが複数のアクティベーションで同時に呼ばれた場合~~ → 後に呼ばれたアクティベーションが優先。実装依存だがおそらくモニター番号順に処理される
- [x] ~~無名ボードの表示方法~~ → カスケード風。タグなしウィンドウが多数集まるため、タイルでは混雑する
- [x] ~~アプリ自動起動~~ → デフォルトでは自動起動しない。空枠をDock風UIで表示し手動起動可能にする（UI実装後）。コマンドでは `--force-launch` オプションで明示的に起動
- [x] ~~`space tile` の比率指定で縦方向の比率~~ → `h=N`（行優先時）/ `w=N`（列優先時）。`/` でグループ区切り。`--horizontal-layout`（デフォルト）と `--vertical-layout` の2モード
- [x] ~~モニター間のボード移動~~ → `space show` で兼用。`space show .web @2` でモニター指定。以降 `space show .web` は最後に指定したモニター上でアクティベート。別モニターに移したければ再度モニター指定
- [x] ~~一時ショートカット (#a, #b, ...) の要否~~ → 不要。ウィンドウIDで直接指定可能。タグ付与後はタグで操作する
