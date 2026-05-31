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

# ── 可选摘要，显示于 Release Notes 上方 ──────────────────────────────────
SUMMARY="${INPUT_SUMMARY:-}"

# ─── Guard ────────────────────────────────────────────────────────────────────
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

python3 -c '
import sys, re

target = sys.argv[1]
text = sys.stdin.read()

is_md = bool(re.search(
    r"(\*\*.*?\*\*|__.*?__|#+\s|-\s|\*\s|`.*?`|\[.*?\]\(.*?\))",
    text
))

if target == "Telegram":
    if not is_md:
        print(text, end="")
        sys.exit(0)

    text = re.sub(r"^(#{1,6})\s+(.*)$", r"<b>\2</b>", text, flags=re.MULTILINE)

    text = re.sub(r"\*\*(.*?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"__(.*?)__", r"<b>\1</b>", text)

    text = re.sub(
        r"(?<!\*)\*(?!\*)(.*?)(?<!\*)\*(?!\*)",
        r"<i>\1</i>",
        text
    )

    text = re.sub(r"^\s*-\s+(.*)$", r"• \1", text, flags=re.MULTILINE)
    text = re.sub(r"^\s*\*\s+(.*)$", r"• \1", text, flags=re.MULTILINE)

    text = re.sub(
        r"\[(.*?)\]\((.*?)\)",
        r"<a href=\"\2\">\1</a>",
        text
    )

    text = re.sub(
        r"```[a-zA-Z0-9]*\n(.*?)\n```",
        r"\1",
        text,
        flags=re.DOTALL
    )

    print(text, end="")
    sys.exit(0)

if not is_md:
    print(text.replace("\n", "<br>"), end="")
    sys.exit(0)

try:
    import markdown
    print(markdown.markdown(text, extensions=["extra", "codehilite"]), end="")
except ImportError:
    text = re.sub(r"\*\*(.*?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"\*(.*?)\*", r"<i>\1</i>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"```([^`]+)```", r"<pre>\1</pre>", text, flags=re.DOTALL)
    print(f"<p>{text}</p>", end="")
' "$target_channel" <<< "$text"
}

# ─── Summary Section（按渠道格式预渲染，为空时各变量均为空字符串）────────────────
SUMMARY_SECTION_HTML=""
SUMMARY_SECTION_MD=""
SUMMARY_SECTION_TG=""
SUMMARY_SECTION_TEXT=""

if [[ -n "${SUMMARY}" ]]; then
    
# Email HTML 格式：callout 样式（轻量左边框，与 notes-card 形成层级对比）
  SUMMARY_SECTION_HTML=$(cat <<HEREDOC
<div class="summary-callout">
  <div class="summary-callout-label">📋 Summary</div>
  <div class="summary-callout-body">${SUMMARY}</div>
</div>
HEREDOC
)

# Telegram HTML：加粗摘要 + 空行分隔
if [[ -n "${SUMMARY}" ]]; then
    SUMMARY_TG=$(convert_markdown "Telegram" "${SUMMARY}")
    SUMMARY_SECTION_TG="${SUMMARY_TG}"$'\n\n'

    # 其他渠道保持不变
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

# Markdown（Ntfy / Slack / DingTalk）：加粗 + 分割线
SUMMARY_SECTION_MD="**${SUMMARY}**"$'\n\n'"---"$'\n\n'

# 纯文本（Bark）：分隔线
SUMMARY_SECTION_TEXT="${SUMMARY}"$'\n'"────────────"$'\n\n'

fi

# ─── VERSION ──────────────────────────────────────────────────────────────────
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

# ─── Release URL ──────────────────────────────────────────────────────────────
if [[ -z "${RELEASE_URL}" ]]; then
if [[ "${VERSION}" != "unknown" \
        && "${VERSION}" != "main" \
    && "${VERSION}" != "master" ]]; then
    RELEASE_URL="${GITHUB_SERVER_URL}/${REPOSITORY}/releases/tag/${VERSION}"
else
    RELEASE_URL="${GITHUB_SERVER_URL}/${REPOSITORY}/releases"
fi
fi

# ─── Status ───────────────────────────────────────────────────────────────────
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

# ─── Title ────────────────────────────────────────────────────────────────────
if [[ -n "${INPUT_TITLE:-}" ]]; then
TITLE="${INPUT_TITLE}"
elif [[ "${NOTIFY_TYPE}" == "failure" ]]; then
TITLE="${REPOSITORY} updated to ${VERSION} — failed"
else
TITLE="${REPOSITORY} updated to ${VERSION}"
fi

# ─── Release notes ────────────────────────────────────────────────────────────
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

# ─── URL decoration ───────────────────────────────────────────────────────────
decorate_url() {
local url="$1"
local icon="$2"

local scheme
local sep
local encoded_icon

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

# ─── Template render ──────────────────────────────────────────────────────────
render_template() {
  local tpl_file="$1"
  local fmt="$2"
  local channel_label="$3"

  local processed_msg="$MESSAGE"
  local summary_section=""

  # HTML 格式需将 Markdown 转换为 HTML
  if [[ "$fmt" == "html" ]]; then
    processed_msg=$(convert_markdown "$channel_label" "$MESSAGE")
  fi

  # 根据渠道选择对应格式的 summary 块
  case "$channel_label" in
    Telegram)            summary_section="${SUMMARY_SECTION_TG}"   ;;
    Email)               summary_section="${SUMMARY_SECTION_HTML}"  ;;
    Bark)                summary_section="${SUMMARY_SECTION_MD}"   ;; 
    Ntfy|Slack|DingTalk) summary_section="${SUMMARY_SECTION_MD}"   ;;
    *)
      # 通用 URL 回退：按 fmt 推断格式
      if   [[ "$fmt" == "markdown" ]]; then summary_section="${SUMMARY_SECTION_MD}"
      elif [[ "$fmt" == "html"     ]]; then summary_section="${SUMMARY_SECTION_HTML}"
      else                                  summary_section="${SUMMARY_SECTION_TEXT}"
      fi
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
  python3 - "$tpl_file" <<'PYEOF'
import sys, os

with open(sys.argv[1], "r") as f:
    content = f.read()

for placeholder, env_key in {
    "{TITLE}":           "TITLE",
    "{MESSAGE}":         "MESSAGE",
    "{SUMMARY}":         "SUMMARY",
    "{SUMMARY_SECTION}": "SUMMARY_SECTION",
    "{STATUS}":          "STATUS",
    "{STATUS_TEXT}":     "STATUS_TEXT",
    "{REPOSITORY}":      "REPOSITORY",
    "{AUTHOR}":          "AUTHOR",
    "{VERSION}":         "VERSION",
    "{RELEASE_URL}":     "RELEASE_URL",
    "{RELEASE_NOTES}":   "RELEASE_NOTES",
}.items():
    content = content.replace(
        placeholder,
        os.environ.get(env_key, "")
    )

print(content, end="")
PYEOF
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

  local body
  local url

  body=$(render_template "$tpl_file" "$fmt" "$label")
  url=$(decorate_url "$raw_url" "$ICON_URL")

  echo "📤 [${label}] Sending..."

  if apprise \
      --title "${TITLE}" \
      --body "${body}" \
      --input-format "${fmt}" \
      --notification-type "${NOTIFY_TYPE}" \
      "${url}"; then
    echo "✅ [${label}] Sent."
  else
    echo "::error::[${label}] Failed."
    return 1
  fi
}

# ─── Send built-in channels ───────────────────────────────────────────────────
TDIR="${ACTION_PATH}/templates"

send_channel "Email" \
  "${INPUT_EMAIL_URL:-}" \
  "${INPUT_EMAIL_TEMPLATE:-}" \
  "html" \
  "${TDIR}/email.html"

send_channel "Telegram" \
  "${INPUT_TELEGRAM_URL:-}" \
  "${INPUT_TELEGRAM_TEMPLATE:-}" \
  "html" \
  "${TDIR}/telegram.html"

send_channel "Bark" \
  "${INPUT_BARK_URL:-}" \
  "${INPUT_BARK_TEMPLATE:-}" \
  "markdown" \
  "${TDIR}/bark.md"

send_channel "Ntfy" \
  "${INPUT_NTFY_URL:-}" \
  "${INPUT_NTFY_TEMPLATE:-}" \
  "markdown" \
  "${TDIR}/ntfy.md"

send_channel "Slack" \
  "${INPUT_SLACK_URL:-}" \
  "${INPUT_SLACK_TEMPLATE:-}" \
  "markdown" \
  "${TDIR}/slack.md"

send_channel "DingTalk" \
  "${INPUT_DINGTALK_URL:-}" \
  "${INPUT_DINGTALK_TEMPLATE:-}" \
  "markdown" \
  "${TDIR}/dingtalk.md"

# ─── Generic URLs ─────────────────────────────────────────────────────────────
if [[ -n "${URLS_INPUT}" ]]; then
  echo "─── Generic URLs ────────────────────────────────────────────────"

  while IFS= read -r raw_url; do
    raw_url=$(echo "$raw_url" | tr -d ' ,')
    [[ -z "$raw_url" ]] && continue

    local_scheme="${raw_url%%://*}"
    url=$(decorate_url "$raw_url" "$ICON_URL")

    fmt="text"
    case "${local_scheme,,}" in
      ntfy*|slack*|dingtalk*|mattermost*|matrix*|rocket*|discord*|telegram)
        fmt="markdown" ;;
      email|mailto|mailtos)
        fmt="html" ;;
      bark*)
        fmt="markdown" ;;
    esac

    # ── 根据格式选择对应的 summary 块，与具名渠道保持一致 ──────────────────────
    if [[ "$fmt" == "html" ]]; then
      formatted_message=$(convert_markdown "Email" "$MESSAGE")
      generic_body="${SUMMARY_SECTION_HTML}${formatted_message}<br><br><a href=\"${RELEASE_URL}\">${RELEASE_URL}</a>"

    elif [[ "$fmt" == "markdown" ]]; then
      generic_body="${SUMMARY_SECTION_MD}${MESSAGE}"$'\n\n'"${RELEASE_URL}"

    else
      # text（Bark 等）
      generic_body="${SUMMARY_SECTION_TEXT}${MESSAGE}"$'\n\n'"${RELEASE_URL}"
    fi

    echo "📤 [generic:${local_scheme}] Sending..."

    if apprise \
        --title "${TITLE}" \
        --body "${generic_body}" \
        --input-format "${fmt}" \
        --notification-type "${NOTIFY_TYPE}" \
        "${url}"; then
      echo "✅ [generic:${local_scheme}] Sent."
    else
      echo "::error::[generic:${local_scheme}] Failed."
    fi

  done < <(echo "${URLS_INPUT}" | tr ',' '\n')
fi

echo "──────────────────────────────────────────────────────────────────"
echo "✅ All notifications processed."