#!/usr/bin/env bash
set -euo pipefail

# ── 配置 ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
REPORTS_DIR="$SCRIPT_DIR/reports"
INDEX_JSON="$REPORTS_DIR/index.json"
TODAY=$(date +%Y-%m-%d)
REPORT_FILE="$REPORTS_DIR/${TODAY}.html"

# 加载 .env
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

if [[ -z "${GITHUB_TOKEN:-}" || -z "${GITHUB_REPO:-}" ]]; then
    echo "ERROR: GITHUB_TOKEN 和 GITHUB_REPO 必须在 .env 中设置"
    exit 1
fi

# ── 加载 nvm ──
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
nvm use 22 --silent 2>/dev/null || true

# ── 获取最新日报 ──
echo ">>> 获取今日日报内容..."

GATEWAY_TOKEN=$(node -e "
const fs = require('fs');
const p = require('path').join(process.env.HOME, '.openclaw/openclaw.json');
try {
    const raw = fs.readFileSync(p, 'utf8').replace(/\/\/.*$/gm, '').replace(/,\s*([\]}])/g, '\$1');
    const cfg = JSON.parse(raw);
    console.log(cfg.gateway?.auth?.token || '');
} catch(e) { console.log(''); }
")

CRON_JOB_ID="c3939ee4-252a-495c-93fe-6593d08bd2b0"

if [[ -n "$GATEWAY_TOKEN" ]]; then
    export OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN"
    SUMMARY=$(openclaw cron runs --id "$CRON_JOB_ID" --limit 1 --json 2>/dev/null | \
        node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const j=JSON.parse(d);console.log(j.entries?.[0]?.summary||'')}catch(e){console.log('')}})" \
        2>/dev/null || echo "")
fi

if [[ -z "${SUMMARY:-}" ]]; then
    echo ">>> 没有从 cron 获取到日报，尝试直接生成..."
    export OPENCLAW_GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"
    SUMMARY=$(openclaw agent --session-id "publish-${TODAY}" --message "请生成今日科技日报：1) 用 web_fetch 访问 https://tophub.today/n/mproPpoq6O 获取知乎热榜前10；2) 用 web_fetch 访问 https://www.producthunt.com 获取 Product Hunt 前10产品，如果失败尝试 https://decohack.com/producthunt-daily。整理成中文日报：📰 每日科技日报标题、🔥 知乎热榜TOP10（含热度）、🚀 Product Hunt精选TOP10（含简介）、💡 今日洞察。" --timeout 120 2>/dev/null || echo "日报生成失败")
fi

if [[ -z "$SUMMARY" || "$SUMMARY" == "日报生成失败" ]]; then
    echo "ERROR: 无法获取日报内容"
    exit 1
fi

echo ">>> 日报内容获取成功 (${#SUMMARY} 字符)"

# ── 生成 HTML 日报页面 ──
mkdir -p "$REPORTS_DIR"

# 把 markdown 转为简单 HTML
BODY_HTML=$(echo "$SUMMARY" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/^## \(.*\)/<h2>\1<\/h2>/g' \
    -e 's/^# \(.*\)/<h1>\1<\/h1>/g' \
    -e 's/^\*\*\(.*\)\*\*$/<p><strong>\1<\/strong><\/p>/g' \
    -e 's/$/<br>/g')

cat > "$REPORT_FILE" <<HTMLEOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>科技日报 — ${TODAY}</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, "Noto Sans SC", "PingFang SC", sans-serif;
            background: #0f172a; color: #e2e8f0;
            max-width: 800px; margin: 0 auto; padding: 24px 16px;
            line-height: 1.8;
        }
        a { color: #38bdf8; }
        h1 { font-size: 24px; margin: 24px 0 16px; }
        h2 { font-size: 20px; margin: 20px 0 12px; color: #f8fafc; border-bottom: 1px solid #1e293b; padding-bottom: 8px; }
        p, br { margin: 4px 0; }
        .back { display: inline-block; margin-bottom: 16px; color: #94a3b8; text-decoration: none; }
        .back:hover { color: #e2e8f0; }
        .meta { color: #64748b; font-size: 13px; margin-bottom: 24px; }
        footer { text-align: center; color: #475569; font-size: 12px; margin-top: 40px; padding-top: 16px; border-top: 1px solid #1e293b; }
    </style>
</head>
<body>
    <a class="back" href="../index.html">&larr; 返回日报列表</a>
    <div class="meta">生成时间：$(date '+%Y-%m-%d %H:%M') | 模型：GLM-4.7</div>
    <article>
${BODY_HTML}
    </article>
    <footer>Powered by OpenClaw &amp; GLM-4.7</footer>
</body>
</html>
HTMLEOF

echo ">>> 日报页面已生成: $REPORT_FILE"

# ── 更新 index.json ──
PREVIEW=$(echo "$SUMMARY" | head -3 | tr '\n' ' ' | cut -c1-80)

if [[ -f "$INDEX_JSON" ]]; then
    # 在数组开头插入新条目
    node -e "
const fs = require('fs');
const idx = JSON.parse(fs.readFileSync('$INDEX_JSON', 'utf8'));
const entry = { date: '$TODAY', file: '${TODAY}.html', preview: $(node -e "console.log(JSON.stringify('$PREVIEW'))") };
const filtered = idx.filter(e => e.date !== '$TODAY');
filtered.unshift(entry);
fs.writeFileSync('$INDEX_JSON', JSON.stringify(filtered, null, 2));
"
else
    cat > "$INDEX_JSON" <<JSONEOF
[
  {
    "date": "${TODAY}",
    "file": "${TODAY}.html",
    "preview": "${PREVIEW}"
  }
]
JSONEOF
fi

echo ">>> index.json 已更新"

# ── Git 提交 & 推送 ──
cd "$SCRIPT_DIR"

git add -A
git commit -m "📰 Daily report: ${TODAY}" || { echo "没有变更需要提交"; exit 0; }

PUSH_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
git remote set-url origin "$PUSH_URL"
git push origin main 2>&1 || git push origin master 2>&1

# 推送后恢复为不含 token 的 URL，防止 token 残留在 .git/config
git remote set-url origin "https://github.com/${GITHUB_REPO}.git"

echo ""
echo "=== 推送完成! ==="
echo "网页地址: https://${GITHUB_REPO%%/*}.github.io/${GITHUB_REPO##*/}/"
echo "仓库地址: https://github.com/${GITHUB_REPO}"
