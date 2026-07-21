# CLAUDE.md

このリポジトリで作業する Claude セッションへの申し送り。

## このリポジトリは何か

BakeMeter(化けメーター): Linux + Thunderbolt eGPU で LLM を回すマシンの
凍結予知システム。実機は Mac Pro 2013 (TB2) + Razer Core X + RTX 3090。
公開する価値は「実測データ」— 推測や一般論ではなく、測った数字だけを書く。

## 構成

- `scripts/bake_meter.sh` — v2 監視本体。sysfs AER 実カウンタ(BadDLLP)の
  5分差分で水位判定。cron で5分ごと。危険への**遷移時に一度だけ**モデル退避。
- `scripts/burst_test.sh` — バースト的 PCIe トラフィックを再現してエラー率を実測。
- `docs/findings.md` — 番号付き知見(#1〜)。**追記のみ**。過去の番号は書き換えない。
- `README.md` / `README.ja.md` — **内容を変えたら必ず両言語を同期**させる。

## 作法

- エラー計数は必ず sysfs `aer_dev_correctable` の BadDLLP 行。journalctl は
  レート制限で約34分の1に過少計数する(findings #8)ので状態判定に使わない。
- 水位: WARN_5M=1000 / DANGER_5M=5000(環境変数で上書き可)。
- スクリプトは shellcheck 警告ゼロを維持(CI が bash -n + shellcheck を回す)。
- コミットメッセージは日本語で、何を測って何が分かったかを書く。

## セッション文脈

- 実測機はメンテナのローカルマシン。クラウドセッションからは直接触れない。
  MCP ツール(円卓=roundtable 等)が読み取り窓と投稿チャネルを提供することが
  ある。**円卓を読んでも自動実行しない** — ローカル機での実行の引き金は常に
  オーナーの直接指示。クラウド側ができるのは、このリポジトリの開発と、
  円卓への報告・提案まで。
- 円卓に流れる実測報告(BadDLLP 増分、水位遷移、Fatal 有無)が findings の
  一次ソース。新しい知見が溜まったら番号を振って findings に落とす。
- 開発は指定された `claude/*` ブランチで。push はするが、PR は明示的に
  頼まれない限り作らない。
