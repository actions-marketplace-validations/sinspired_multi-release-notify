#!/usr/bin/env bash
# =============================================================================
# Multi-Channel Notification — entrypoint.sh
# =============================================================================
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

# ─── Inputs ───────────────────────────────────────────────────────────────────
STATUS="${INPUT_STATUS:-released}"
URLS_INPUT="${INPUT_URLS:-}"

VERSION="${INPUT_VERSION:-}"
RELEASE_URL="${INPUT_RELEASE_URL:-}"
RELEASE_NOTES="${INPUT_RELEASE_NOTES:-}"

REPOSITORY="${GITHUB_REPOSITORY:-unknown/repo}"
AUTHOR="${INPUT_AUTHOR:-${GITHUB_ACTOR:-unknown}}"

ICON_URL="${INPUT_ICON_URL:-https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png}"

ACTION_PATH="${GITHUB_ACTION_PATH:-.}"
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"

# 可选摘要，显示于 Release Notes 上方
SUMMARY="${INPUT_SUMMARY:-}"

# Guard
if [[ -z "${URLS_INPUT}" \
        && -z "${INPUT_EMAIL_URL:-}" \
        && -z "${INPUT_TELEGRAM_URL:-}" \
        && -z "${INPUT_BARK_URL:-}" \
        && -z "${INPUT_NTFY_URL:-}" \
        && -z "${INPUT_SLACK_URL:-}" \
        && -z "${INPUT_DINGTALK_URL:-}" ]]; then
    echo "::error::No destination configured."
    exit 1
fi

# ─── Markdown convert ─────────────────────────────────────────────────────────
convert_markdown() {
    local target_channel="$1"
    local text="$2"

    TARGET_CHANNEL="$target_channel" TEXT="$text" python3 - <<'PY'
import os
import re
import sys

target = os.environ.get("TARGET_CHANNEL", "")
text = os.environ.get("TEXT", "")

# 检测输入是否含有 Markdown 语法
is_md = bool(re.search(
    r"(\*\*.*?\*\*|__.*?__|#+\s|-\s|\*\s|`.*?`|\[.*?\]\(.*?\))",
    text
))

if target == "Telegram":
    # 顺序不能乱：& 必须最先转义，否则后续替换会产生双重转义
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    if not is_md:
        print(text.strip(), end="")
        sys.exit(0)

    # 标题 → <b>
    text = re.sub(r"^(#{1,6})\s+(.*)$", r"<b>\2</b>", text, flags=re.MULTILINE)

    # **bold** / __bold__
    text = re.sub(r"\*\*(.*?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"__(.*?)__",     r"<b>\1</b>", text)

    # *italic*（负向环视，避免匹配 **bold**）
    text = re.sub(
        r"(?<!\*)\*(?!\*)(.*?)(?<!\*)\*(?!\*)",
        r"<i>\1</i>",
        text
    )

    # 列表符号（- 和 * 开头的行）→ 项目符号
    text = re.sub(r"^\s*[-*]\s+(.*)$", r"• \1", text, flags=re.MULTILINE)

    # [text](url) → <a href="url">text</a>
    text = re.sub(
        r"\[([^\]]*?)\]\((.*?)\)",
        r'<a href="\2">\1</a>',
        text
    )

    # 代码块 ```lang\n...\n``` → <pre>...</pre>
    text = re.sub(
        r"```[a-zA-Z0-9]*\n(.*?)\n```",
        r"<pre>\1</pre>",
        text,
        flags=re.DOTALL
    )

    # 清理多余空行（Telegram 对连续空行较敏感）
    text = re.sub(r"\n{3,}", "\n\n", text)

    print(text.strip(), end="")
    sys.exit(0)

# ── 非 Telegram 渠道 ──────────────────────────────────────────────────────────
if not is_md:
    # 纯文本：换行转 <br>
    print(text.replace("\n", "<br>"), end="")
    sys.exit(0)

try:
    import markdown
    print(markdown.markdown(text, extensions=["extra", "codehilite"]), end="")
except ImportError:
    # 降级处理：手动转换常用语法
    text = re.sub(r"\*\*(.*?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"\*(.*?)\*",     r"<i>\1</i>", text)
    text = re.sub(r"`([^`]+)`",      r"<code>\1</code>", text)
    text = re.sub(r"```([^`]+)```",  r"<pre>\1</pre>", text, flags=re.DOTALL)
    print(f"<p>{text}</p>", end="")
PY
}

# Telegram HTML 兜底清理
# 确保最终发往 Telegram 的 HTML 中没有裸露的 &（无论来源）
sanitize_telegram_html() {
    local text="$1"
    python3 -c '
import sys, re
text = sys.stdin.read()
# 将未转义的 & 修复为 &amp;（已是合法实体的不重复转义）
text = re.sub(
    r"&(?!(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)",
    "&amp;",
    text
)
print(text, end="")
' <<< "$text"
}

# Summary Section
SUMMARY_SECTION_HTML=""
SUMMARY_SECTION_MD=""
SUMMARY_SECTION_TG=""
SUMMARY_SECTION_TEXT=""

if [[ -n "${SUMMARY}" ]]; then
    SUMMARY_TG=$(convert_markdown "Telegram" "${SUMMARY}")
    SUMMARY_SECTION_TG="${SUMMARY_TG}"$'\n\n'

    SUMMARY_SECTION_HTML=$(cat <<HEREDOC
<div class="summary-callout">
  <div class="summary-callout-label">📋 Summary</div>
  <div class="summary-callout-body">${SUMMARY}</div>
</div>
HEREDOC
)

    SUMMARY_SECTION_MD="**${SUMMARY}**"$'\n\n'"---"$'\n\n'
    SUMMARY_SECTION_TEXT="${SUMMARY}"$'\n'"────────────"$'\n\n'
fi

# VERSION
if [[ -z "${VERSION}" ]]; then
    GIT_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

    if [[ -n "${GIT_TAG}" ]]; then
        VERSION="${GIT_TAG}"
    elif [[ "${GITHUB_REF:-}" =~ ^refs/tags/ ]]; then
        VERSION="${GITHUB_REF#refs/tags/}"
    elif [[ "${GITHUB_REF:-}" =~ ^refs/heads/ ]]; then
        VERSION="${GITHUB_REF#refs/heads/}"
    else
        VERSION="${GITHUB_REF:-unknown}"
    fi
fi

# Release URL
if [[ -z "${RELEASE_URL}" ]]; then
    if [[ "${VERSION}" != "unknown" \
            && "${VERSION}" != "main" \
            && "${VERSION}" != "master" ]]; then
        RELEASE_URL="${GITHUB_SERVER_URL}/${REPOSITORY}/releases/tag/${VERSION}"
    else
        RELEASE_URL="${GITHUB_SERVER_URL}/${REPOSITORY}/releases"
    fi
fi

# Status
case "${STATUS,,}" in
    success|released)
        STATUS_TEXT="Released"
        NOTIFY_TYPE="success"
        ;;
    failure|failed)
        STATUS_TEXT="Failed"
        NOTIFY_TYPE="failure"
        ;;
    cancelled)
        STATUS_TEXT="Cancelled"
        NOTIFY_TYPE="warning"
        ;;
    *)
        STATUS_TEXT="${STATUS}"
        NOTIFY_TYPE="info"
        ;;
esac

# Title
if [[ -n "${INPUT_TITLE:-}" ]]; then
    TITLE="${INPUT_TITLE}"
elif [[ "${NOTIFY_TYPE}" == "failure" ]]; then
    TITLE="${REPOSITORY} updated to ${VERSION} — failed"
else
    TITLE="${REPOSITORY} updated to ${VERSION}"
fi

# Release notes
if [[ -z "${INPUT_MESSAGE:-}" ]] && [[ -z "${RELEASE_NOTES}" ]]; then
    PREV_TAG=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo "")

    if [[ -n "${PREV_TAG}" ]]; then
        RAW_LOG=$(git log --no-merges --pretty=format:"%s" "${PREV_TAG}..HEAD" 2>/dev/null || echo "")
        if [[ -n "${RAW_LOG}" ]]; then
            RELEASE_NOTES=$(echo "${RAW_LOG}" | sed 's/^/- /')
        else
            RELEASE_NOTES="No new commits since ${PREV_TAG}."
        fi
    else
        RAW_LOG=$(git log --no-merges --pretty=format:"%s" 2>/dev/null | head -20 || echo "")
        if [[ -n "${RAW_LOG}" ]]; then
            RELEASE_NOTES=$(echo "${RAW_LOG}" | sed 's/^/- /')
        fi
    fi
fi

MESSAGE="${INPUT_MESSAGE:-${RELEASE_NOTES:-No release notes provided.}}"

# URL decoration
decorate_url() {
    local url="$1"
    local icon="$2"

    local scheme sep encoded_icon

    scheme=$(echo "$url" | sed 's|://.*||' | tr '[:upper:]' '[:lower:]')

    if [[ "$url" == *"?"* ]]; then
        sep="&"
    else
        sep="?"
    fi

    encoded_icon=$(python3 -c \
        "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" \
        "$icon")

    case "$scheme" in
        bark*)
            [[ "$url" != *"icon="*  ]] && url="${url}${sep}icon=${encoded_icon}" && sep="&"
            [[ "$url" != *"group="* ]] && url="${url}${sep}group=GitHub_Release"
            [[ "$url" != *"format="* ]] && url="${url}${sep}format=markdown"
            ;;
        ntfy*)
            [[ "$url" != *"avatar_url="* ]] && url="${url}${sep}avatar_url=${encoded_icon}" && sep="&"
            if [[ "$url" != *"tags="* ]]; then
                url="${url}${sep}tags=GitHub_Release"
                sep="&"
            else
                url=$(echo "$url" | sed 's/\(tags=[^&]*\)/\1,GitHub_Release/')
            fi
            [[ "$url" != *"format="* ]] && url="${url}${sep}format=markdown"
            ;;
        discord)
            [[ "$url" != *"avatar="*     ]] && url="${url}${sep}avatar=yes" && sep="&"
            [[ "$url" != *"avatar_url="* ]] && url="${url}${sep}avatar_url=${encoded_icon}"
            ;;
        mailto|mailtos)
            [[ "$url" != *"from="* ]] && url="${url}${sep}from=GitHub_Actions"
            ;;
    esac

    echo "$url"
}

# Template render
render_template() {
    local tpl_file="$1"
    local fmt="$2"
    local channel_label="$3"

    local processed_msg="$MESSAGE"
    local summary_section=""

    if [[ "$fmt" == "html" ]]; then
        processed_msg=$(convert_markdown "$channel_label" "$MESSAGE")
    fi

    case "$channel_label" in
        Telegram)                 summary_section="${SUMMARY_SECTION_TG}"   ;;
        Email)                    summary_section="${SUMMARY_SECTION_HTML}" ;;
        Bark|Ntfy|Slack|DingTalk) summary_section="${SUMMARY_SECTION_MD}"  ;;
        *)
            if   [[ "$fmt" == "markdown" ]]; then summary_section="${SUMMARY_SECTION_MD}"
            elif [[ "$fmt" == "html"     ]]; then summary_section="${SUMMARY_SECTION_HTML}"
            else                                  summary_section="${SUMMARY_SECTION_TEXT}"
            fi
            ;;
    esac

    # 将 channel_label 也传入 Python，以便对 Telegram 做 HTML 转义
    TITLE="$TITLE" \
    MESSAGE="$processed_msg" \
    SUMMARY="${SUMMARY}" \
    SUMMARY_SECTION="${summary_section}" \
    STATUS="${STATUS,,}" \
    STATUS_TEXT="$STATUS_TEXT" \
    REPOSITORY="$REPOSITORY" \
    AUTHOR="$AUTHOR" \
    VERSION="$VERSION" \
    RELEASE_URL="$RELEASE_URL" \
    RELEASE_NOTES="$RELEASE_NOTES" \
    CHANNEL_LABEL="$channel_label" \
    python3 - "$tpl_file" <<'PYEOF'
import sys, os
from html import escape as h

with open(sys.argv[1], "r") as f:
    content = f.read()

# 获取当前渠道，决定是否对原始文本做 HTML 转义
channel = os.environ.get("CHANNEL_LABEL", "")
is_tg_html = (channel == "Telegram")

def safe(val, already_html=False):
    """
    对 Telegram HTML 模板中的裸文本变量做 HTML 转义；
    已经是 HTML 的变量（MESSAGE、SUMMARY_SECTION）直接透传。
    """
    if is_tg_html and not already_html:
        return h(val)   # & → &amp;  < → &lt;  > → &gt;
    return val

# (占位符, 环境变量名, 是否已经是合法HTML)
substitutions = [
    ("{TITLE}",           "TITLE",           False),  # 裸文本 → 需转义
    ("{MESSAGE}",         "MESSAGE",         True),   # 已是 Telegram HTML → 透传
    ("{SUMMARY}",         "SUMMARY",         False),
    ("{SUMMARY_SECTION}", "SUMMARY_SECTION", True),   # 已是 Telegram HTML → 透传
    ("{STATUS}",          "STATUS",          False),
    ("{STATUS_TEXT}",     "STATUS_TEXT",     False),
    ("{REPOSITORY}",      "REPOSITORY",      False),
    ("{AUTHOR}",          "AUTHOR",          False),
    ("{VERSION}",         "VERSION",         False),
    ("{RELEASE_URL}",     "RELEASE_URL",     False),  # URL 中 & 也需 → &amp;
    ("{RELEASE_NOTES}",   "RELEASE_NOTES",   False),  # 裸 Markdown → 需转义
]

for placeholder, env_key, already_html in substitutions:
    val = os.environ.get(env_key, "")
    content = content.replace(placeholder, safe(val, already_html))

print(content, end="")
PYEOF
}

# Run apprise
run_apprise() {
    local label="$1"
    local body="$2"
    local fmt="$3"
    local url="$4"
    local fatal="${5:-true}"

    echo "📤 [${label}] Sending..."

    if apprise \
        -vv \
        --title "${TITLE}" \
        --body "${body}" \
        --input-format "${fmt}" \
        --notification-type "${NOTIFY_TYPE}" \
        "${url}"; then
        echo "✅ [${label}] Sent."
    else
        echo "::error::[${label}] Failed."
        [[ "$fatal" == "true" ]] && return 1
    fi
}

# ─── Send channel ─────────────────────────────────────────────────────────────
send_channel() {
    local label="$1"
    local raw_url="$2"
    local user_tpl="$3"
    local fmt="$4"
    local builtin_tpl="$5"

    [[ -z "$raw_url" ]] && return 0

    local tpl_file

    if [[ -n "$user_tpl" && -f "${GITHUB_WORKSPACE:-/github/workspace}/${user_tpl}" ]]; then
        tpl_file="${GITHUB_WORKSPACE:-/github/workspace}/${user_tpl}"
        echo "📄 [${label}] Using custom template: ${user_tpl}"
    else
        tpl_file="$builtin_tpl"
    fi

    local body url

    body=$(render_template "$tpl_file" "$fmt" "$label")

    # Telegram HTML 兜底：修复任何未转义的 & 防止 Telegram API 解析报错
    if [[ "$label" == "Telegram" && "$fmt" == "html" ]]; then
        body=$(sanitize_telegram_html "$body")
    fi

    url=$(decorate_url "$raw_url" "$ICON_URL")

    run_apprise "${label}" "${body}" "${fmt}" "${url}" "true"
}

# Send built-in channels
TDIR="${ACTION_PATH}/templates"

send_channel "Email"    "${INPUT_EMAIL_URL:-}"    "${INPUT_EMAIL_TEMPLATE:-}"    "html"     "${TDIR}/email.html"
send_channel "Telegram" "${INPUT_TELEGRAM_URL:-}" "${INPUT_TELEGRAM_TEMPLATE:-}" "html"     "${TDIR}/telegram.html"
send_channel "Bark"     "${INPUT_BARK_URL:-}"     "${INPUT_BARK_TEMPLATE:-}"     "markdown" "${TDIR}/bark.md"
send_channel "Ntfy"     "${INPUT_NTFY_URL:-}"     "${INPUT_NTFY_TEMPLATE:-}"     "markdown" "${TDIR}/ntfy.md"
send_channel "Slack"    "${INPUT_SLACK_URL:-}"    "${INPUT_SLACK_TEMPLATE:-}"    "markdown" "${TDIR}/slack.md"
send_channel "DingTalk" "${INPUT_DINGTALK_URL:-}" "${INPUT_DINGTALK_TEMPLATE:-}" "markdown" "${TDIR}/dingtalk.md"

# Generic URLs
if [[ -n "${URLS_INPUT}" ]]; then
    echo "─── Generic URLs ────────────────────────────────────────────────"

    while IFS= read -r raw_url; do
        raw_url=$(echo "$raw_url" | tr -d ' ,')
        [[ -z "$raw_url" ]] && continue

        local_scheme="${raw_url%%://*}"
        url=$(decorate_url "$raw_url" "$ICON_URL")

        fmt="text"
        case "${local_scheme,,}" in
            ntfy*|slack*|dingtalk*|mattermost*|matrix*|rocket*|discord*|telegram|bark*)
                fmt="markdown" ;;
            email|mailto|mailtos)
                fmt="html" ;;
        esac

        if [[ "$fmt" == "html" ]]; then
            formatted_message=$(convert_markdown "Email" "$MESSAGE")
            generic_body="${SUMMARY_SECTION_HTML}${formatted_message}<br><br><a href=\"${RELEASE_URL}\">${RELEASE_URL}</a>"
        elif [[ "$fmt" == "markdown" ]]; then
            generic_body="${SUMMARY_SECTION_MD}${MESSAGE}"$'\n\n'"${RELEASE_URL}"
        else
            generic_body="${SUMMARY_SECTION_TEXT}${MESSAGE}"$'\n\n'"${RELEASE_URL}"
        fi

        run_apprise "generic:${local_scheme}" "${generic_body}" "${fmt}" "${url}" "false"

    done < <(echo "${URLS_INPUT}" | tr ',' '\n')
fi

echo "──────────────────────────────────────────────────────────────────"
echo "✅ All notifications processed."
