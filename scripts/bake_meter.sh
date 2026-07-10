#!/bin/bash
# 化けメーター v2: PCIe(Thunderbolt)エラーの未病検知
# 2026-07-10 王命「システムを作るんだ」で設置 / 同日夜 Codex監査#1,#3,#5是正でv2化(後継ネオ)
#   #1 journalctl計数は"callbacks suppressed"で過少(実測34倍差)→ sysfs実カウンタ(BadDLLP)の差分へ
#   #3 危険中に5分毎の退避連発→ 「危険への遷移時に一度だけ」へ
#   #5 警報がホームのみでV4不可視→ data/open-webui/system/bake_state.json にも毎回書く(コンテナ可視)
# 5分ごとにcronで実行。直近間隔の実エラー差分で水位判定。
# 水位(5分差分・★暫定=較正データ収集中。実測: アイドル0件/分、再起動直後バースト約1万件):
#   WARN_5M=1000 ⚠注意 / DANGER_5M=5000 🚨危険(全モデル退避+退避結果を再確認)
LOG=~/freeze_test/bake_meter.csv
ALERT=~/BAKE_ALERT.txt
STATE=~/freeze_test/bake_meter_state
JSTATE=~/local-ai-stack/data/open-webui/system/bake_state.json
AERDEV=/sys/bus/pci/devices/0000:18:01.0/aer_dev_correctable
WARN_5M=1000
DANGER_5M=5000

TS=$(date "+%Y-%m-%d %H:%M")
EPOCH=$(date +%s)
mkdir -p ~/freeze_test

# 参考: 旧journalctl計数(過少と判明済み・較正の突き合わせ用に併記)
NJ=$(journalctl -k --since "1 hour ago" --no-pager 2>/dev/null | grep -c "AER: Correctable error message received")

if [ -r "$AERDEV" ]; then
  CUR=$(awk '/^BadDLLP/{print $2}' "$AERDEV")
  SRC=sysfs
else
  CUR=-1
  SRC=journalctl_fallback
fi

PREV_CNT=""
PREV_LEVEL=平常
if [ -f "$STATE" ]; then
  PREV_CNT=$(awk -F, 'NR==1{print $1}' "$STATE")
  PREV_LEVEL=$(awk -F, 'NR==1{print $2}' "$STATE")
fi

if [ "$SRC" = "sysfs" ]; then
  if [ -z "$PREV_CNT" ]; then
    # 初回: ベースライン記録のみ(累積値を差分と誤認して空騒ぎしない)
    DELTA=0
    SRC=sysfs_first_run
  elif [ "$CUR" -ge "$PREV_CNT" ] 2>/dev/null; then
    DELTA=$((CUR - PREV_CNT))
  else
    # カウンタが戻った=再起動でリセット。起動後の累積を今区間の値とする
    DELTA=$CUR
  fi
  LEVEL=平常
  [ "$DELTA" -ge "$WARN_5M" ] && LEVEL=注意
  [ "$DELTA" -ge "$DANGER_5M" ] && LEVEL=危険
else
  # フォールバック: sysfsが読めない時のみ旧方式(過少と知りつつ、無計測よりまし。sourceに正直に残す)
  DELTA=$NJ
  LEVEL=平常
  [ "$NJ" -ge 50 ] && LEVEL=注意
  [ "$NJ" -ge 200 ] && LEVEL=危険
fi

# CSV: 時刻,5分差分,水位,累積実カウンタ,journal1h参考値,計測源
echo "$TS,$DELTA,$LEVEL,$CUR,$NJ,$SRC" >> "$LOG"
printf '%s,%s\n' "$CUR" "$LEVEL" > "$STATE"

# コンテナ可視の状態ファイル(V4入口の危険ゲート用)。原子的に置き換え。
mkdir -p "$(dirname "$JSTATE")"
printf '{"level":"%s","delta_5m":%s,"baddllp_total":%s,"journal_1h":%s,"source":"%s","ts":"%s","epoch":%s}\n' \
  "$LEVEL" "$DELTA" "$CUR" "$NJ" "$SRC" "$TS" "$EPOCH" > "$JSTATE.tmp" && mv "$JSTATE.tmp" "$JSTATE"

if [ "$LEVEL" = "危険" ] && [ "$PREV_LEVEL" != "危険" ]; then
  # 流れを止める: 危険への遷移時に一度だけ全モデルを降ろす(データは無傷)
  for M in $(curl -s http://localhost:11434/api/ps | python3 -c "import json,sys; print(\" \".join(m[\"name\"] for m in json.load(sys.stdin).get(\"models\",[])))" 2>/dev/null); do
    curl -s http://localhost:11434/api/generate -d "{\"model\":\"$M\",\"keep_alive\":0}" >/dev/null
  done
  sleep 3
  # 退避結果を再確認(言いっぱなしにしない)
  REMAIN=$(curl -s http://localhost:11434/api/ps | python3 -c "import json,sys; print(len(json.load(sys.stdin).get(\"models\",[])))" 2>/dev/null)
  if [ "$REMAIN" = "0" ]; then NOTE="退避完了を再確認済み"; else NOTE="⚠退避後もモデル${REMAIN:-?}件が残存(要確認)"; fi
  echo "[$TS] 🚨化け${DELTA}件/5分(実カウンタ): 危険水位。全モデルを退避(${NOTE})。しばらく重い仕事を控えてください。凍結の前兆の可能性があります。" >> "$ALERT"
elif [ "$LEVEL" = "注意" ] && [ ! -f "$ALERT" ]; then
  echo "[$TS] ⚠化け${DELTA}件/5分(実カウンタ): 注意水位。様子見中。" >> "$ALERT"
fi

# 平常が続いたら警報を自動解除
if [ "$LEVEL" = "平常" ] && [ -f "$ALERT" ]; then
  RECENT_BAD=$(tail -12 "$LOG" | grep -c -E "注意|危険")
  [ "$RECENT_BAD" -le 1 ] && rm -f "$ALERT"
fi
