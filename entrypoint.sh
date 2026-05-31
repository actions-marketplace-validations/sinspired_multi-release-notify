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

# ─── Markdown / HTML convert ──────────────────────────────────────────────────
convert_markdown() {
    local mode="$1"
    local text="$2"

    MODE="$mode" TEXT="$text" python3 - <<'PY'
import os
import re
import sys

mode = os.environ.get("MODE", "")
text = os.environ.get("TEXT", "")

def is_markdown(s: str) -> bool:
    return bool(re.search(
        r"(\*\*.*?\*\*|__.*?__|#+\s|-\s|\*\s|`.*?`|\[.*?\]\(.*?\))",
        s
    ))

def escape_plain(s: str) -> str:
    return (
        s.replace("&", "&amp;")
         .replace("<", "&lt;")
         .replace(">", "&gt;")
    )

def md_to_telegram(s: str) -> str:
    md = is_markdown(s)

    # Telegram HTML 必须先转义原始文本
    s = escape_plain(s)

    if not md:
        return s.strip()

    # 标题 → <b>
    s = re.sub(r"^(#{1,6})\s+(.*)$", r"<b>\2</b>", s, flags=re.MULTILINE)

    # **bold** / __bold__
    s = re.sub(r"\*\*(.*?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"__(.*?)__",     r"<b>\1</b>", s)

    # *italic*（避免匹配 **bold**）
    s = re.sub(r"(?<!\*)\*(?!\*)(.*?)(?<!\*)\*(?!\*)", r"<i>\1</i>", s)

    # 列表
    s = re.sub(r"^\s*[-*]\s+(.*)$", r"• \1", s, flags=re.MULTILINE)

    # [text](url) → <a href="url">text</a>
    s = re.sub(r"\[([^\]]*?)\]\((.*?)\)", r'<a href="\2">\1</a>', s)

    # 代码块 ```lang\n...\n``` → <pre>...</pre>
    def codeblock(m):
        code = (
            m.group(1)
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
        )
        return f"<pre>{code}</pre>"

    s = re.sub(r"```[a-zA-Z0-9]*\n(.*?)\n```", codeblock, s, flags=re.DOTALL)

    # 清理多余空行
    s = re.sub(r"\n{3,}", "\n\n", s)

    return s.strip()

def md_to_html(s: str) -> str:
    if not is_markdown(s):
        return escape_plain(s).replace("\n", "<br>")

    try:
        import markdown
        return markdown.markdown(s, extensions=["extra", "codehilite"])
    except Exception:
        # 降级处理
        s = escape_plain(s)
        s = re.sub(r"\*\*(.*?)\*\*", r"<b>\1</b>", s)
        s = re.sub(r"__(.*?)__",     r"<b>\1</b>", s)
        s = re.sub(r"\*(.*?)\*",     r"<i>\1</i>", s)
        s = re.sub(r"`([^`]+)`",      r"<code>\1</code>", s)

        def codeblock(m):
            code = (
                m.group(1)
                .replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
            )
            return f"<pre>{code}</pre>"

        s = re.sub(r"```(.*?)```", codeblock, s, flags=re.DOTALL)
        return f"<p>{s}</p>"

if mode == "telegram":
    print(md_to_telegram(text), end="")
elif mode == "html":
    print(md_to_html(text), end="")
elif mode == "plain":
    print(escape_plain(text), end="")
else:
    print(text, end="")
PY
}

sanitize_telegram_html() {
    local text="$1"

    TEXT="$text" python3 - <<'PY'
import os
import re

text = os.environ.get("TEXT", "")

# 将未转义的 & 修复为 &amp;（已是合法实体的不重复转义）
text = re.sub(
    r"&(?!(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)",
    "&amp;",
    text
)

print(text, end="")
PY
}

build_summary_section_html() {
    local summary="$1"
    [[ -z "$summary" ]] && return 0

    local summary_html
    summary_html=$(convert_markdown "html" "$summary")

    cat <<HEREDOC
<div class="summary-callout">
  <div class="summary-callout-label">📋 Summary</div>
  <div class="summary-callout-body">${summary_html}</div>
</div>
HEREDOC
}

build_summary_section_telegram() {
    local summary="$1"
    [[ -z "$summary" ]] && return 0

    local summary_tg
    summary_tg=$(convert_markdown "telegram" "$summary")
    printf '%s\n<b></b>\n\n' "$summary_tg"
}

detect_template_kind() {
    local tpl_file="$1"

    if [[ ! -f "$tpl_file" ]]; then
        echo "text"
        return 0
    fi

    # 显式标记优先
    if grep -qiE '<!--[[:space:]]*apprise-template:[[:space:]]*telegram[[:space:]]*-->' "$tpl_file"; then
        echo "telegram_html"
        return 0
    fi

    if grep -qiE '<!--[[:space:]]*apprise-template:[[:space:]]*html[[:space:]]*-->' "$tpl_file"; then
        echo "html_doc"
        return 0
    fi

    case "${tpl_file##*.}" in
        md|markdown) echo "markdown"; return 0 ;;
        txt|text)    echo "text";     return 0 ;;
    esac

    # 依据模板内容判断
    if grep -qiE '<!doctype[[:space:]]+html|<html[[:space:]>]' "$tpl_file"; then
        echo "html_doc"
    else
        echo "telegram_html"
    fi
}

# Summary Section
SUMMARY_SECTION_HTML=""
SUMMARY_SECTION_MD=""
SUMMARY_SECTION_TG=""
SUMMARY_SECTION_TEXT=""

if [[ -n "${SUMMARY}" ]]; then
    SUMMARY_SECTION_HTML=$(build_summary_section_html "${SUMMARY}")
    SUMMARY_SECTION_TG=$(build_summary_section_telegram "${SUMMARY}")
    SUMMARY_SECTION_MD="${SUMMARY}"$'\n\n'"---"$'\n\n'
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
else
    case "${NOTIFY_TYPE}" in
        success)
            TITLE="🚀 ${REPOSITORY} updated to ${VERSION}"
            ;;
        failure)
            TITLE="❌ ${REPOSITORY} updated to ${VERSION} — failed"
            ;;
        warning)
            TITLE="⚠️ ${REPOSITORY} updated to ${VERSION} — cancelled"
            ;;
        *)
            TITLE="📢 ${REPOSITORY} updated to ${VERSION}"
            ;;
    esac
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

    local template_kind
    template_kind=$(detect_template_kind "$tpl_file")

    local processed_msg=""
    local summary_section=""

    case "$template_kind" in
        html_doc)
            processed_msg=$(convert_markdown "html" "$MESSAGE")
            summary_section="${SUMMARY_SECTION_HTML}"
            ;;
        telegram_html)
            # Telegram 的 Release Notes 放进 <pre>，这里只保留纯文本并做 HTML 兜底转义
            processed_msg=$(convert_markdown "plain" "$MESSAGE")
            summary_section="${SUMMARY_SECTION_TG}"
            ;;
        markdown)
            processed_msg="$MESSAGE"
            summary_section="${SUMMARY_SECTION_MD}"
            ;;
        *)
            processed_msg="$MESSAGE"
            summary_section="${SUMMARY_SECTION_TEXT}"
            ;;
    esac

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
    TEMPLATE_KIND="$template_kind" \
    python3 - "$tpl_file" <<'PYEOF'
import sys
import os
from html import escape as h

with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()

kind = os.environ.get("TEMPLATE_KIND", "")

def safe(val, already_html=False):
    # HTML 模板中的裸文本变量需要转义；已经是 HTML 的变量直接透传
    if kind in ("html_doc", "telegram_html") and not already_html:
        return h(val, quote=False)
    return val

substitutions = [
    ("{TITLE}",           "TITLE",           False),
    ("{MESSAGE}",         "MESSAGE",         True),
    ("{SUMMARY}",         "SUMMARY",         False),
    ("{SUMMARY_SECTION}",  "SUMMARY_SECTION", True),
    ("{STATUS}",          "STATUS",          False),
    ("{STATUS_TEXT}",     "STATUS_TEXT",     False),
    ("{REPOSITORY}",      "REPOSITORY",      False),
    ("{AUTHOR}",          "AUTHOR",          False),
    ("{VERSION}",         "VERSION",         False),
    ("{RELEASE_URL}",     "RELEASE_URL",     False),
    ("{RELEASE_NOTES}",   "RELEASE_NOTES",   False),
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
    body=$(render_template "$tpl_file" "$fmt")

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

    while IFS= read -r raw_url || [[ -n "$raw_url" ]]; do
        raw_url=$(echo "$raw_url" | tr -d ' ,')
        [[ -z "$raw_url" ]] && continue

        local_scheme="${raw_url%%://*}"
        url=$(decorate_url "$raw_url" "$ICON_URL")

        fmt="text"
        case "${local_scheme,,}" in
            ntfy*|slack*|dingtalk*|mattermost*|matrix*|rocket*|discord*|telegram|bark*)
                fmt="markdown"
                ;;
            email|mailto|mailtos)
                fmt="html"
                ;;
        esac

        if [[ "$fmt" == "html" ]]; then
            formatted_message=$(convert_markdown "html" "$MESSAGE")
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