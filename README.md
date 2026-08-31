# Multi Release Notify

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Multi--Release%20Notify-blue?logo=github)](https://github.com/marketplace/actions/multi-release-notify)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Send release and CI/CD notifications to **Slack, Telegram, Email, Bark, Ntfy, DingTalk**,
or any of the [100+ services supported by Apprise](https://github.com/caronc/apprise/wiki).

Built for GitHub Actions Marketplace users:

- Automatic release titles and release notes
- Built-in per-channel formatting
- Zero channel selection configuration
- Custom templates supported
- Generic Apprise URL fallback

---

# Features

- Automatic release titles:
  - `owner/repo updated to v1.2.0`
  - `owner/repo updated to v1.2.0 — failed`

- Automatic release notes generation:
  - previous tag → HEAD
  - clean commit subjects only

- Automatic formatting by target:
  - Email → HTML
  - Telegram → Telegram HTML
  - Slack / Ntfy / DingTalk → Markdown
  - Bark → Plain text

- Automatic URL enhancement:
  - `icon`
  - `group`
  - `tags`
  - `avatar_url`
  - `from`

- Works with any Apprise-supported service via `urls`

- Repository-local custom templates supported

- If a `*_url` exists, it is sent automatically

---

# Quick Start

## Release notification

```yaml
name: Release Notification

on:
  release:
    types: [published]

jobs:
  notify:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - uses: sinspired/multi-release-notify@v1
        with:
          email_url:     ${{ secrets.EMAIL_APPRISE_URL }}
          telegram_url:  ${{ secrets.TELEGRAM_APPRISE_URL }}
          bark_url:      ${{ secrets.BARK_APPRISE_URL }}
```

---

## CI/CD notification

```yaml
- uses: sinspired/multi-release-notify@v1
  if: always()
  with:
    status:      ${{ job.status }}
    slack_url:   ${{ secrets.SLACK_APPRISE_URL }}
```

---

## Generic Apprise URLs

```yaml
- uses: sinspired/multi-release-notify@v1
  with:
    urls: |
      discord://webhook_id/webhook_token
      gotify://hostname/token
      pushover://user_key/app_token
```

---

# Inputs

## Core

| Input | Description | Default |
|---|---|---|
| `status` | `success`, `failure`, `cancelled`, `released`, or custom string | `released` |
| `urls` | Generic Apprise URLs (comma or newline separated) | |
| `title` | Custom title | Auto-generated |
| `message` | Custom message body | Auto-generated |
| `icon_url` | Icon URL injected into supported services | GitHub logo |

---

## Release metadata

| Input | Description |
|---|---|
| `version` | Tag name, e.g. `v1.2.0` |
| `release_url` | GitHub Release URL |
| `release_notes` | Release notes / changelog |
| `author` | Publisher username |

---

## Built-in channel URLs

| Input | Example |
|---|---|
| `email_url` | `mailtos://user:pass@smtp.example.com?to=dest@example.com` |
| `telegram_url` | `tgram://bot_token/chat_id` |
| `bark_url` | `bark://device_key@api.day.app` |
| `ntfy_url` | `ntfy://topic` |
| `slack_url` | `slack://xoxb-token/#general` |
| `dingtalk_url` | `dingtalk://access_token` |

If a URL is configured, notifications are sent automatically.

---

# Custom Templates

Template paths are relative to the repository root.

| Input | Format |
|---|---|
| `email_template` | HTML |
| `telegram_template` | Telegram HTML |
| `bark_template` | Markdown |
| `ntfy_template` | Markdown |
| `slack_template` | Markdown |
| `dingtalk_template` | Markdown |

Example:

```yaml
- uses: sinspired/multi-release-notify@v1
  with:
    telegram_url:      ${{ secrets.TELEGRAM_APPRISE_URL }}
    telegram_template: .github/templates/telegram.html
```

---

# Secrets Setup

Go to:

`Settings → Secrets and variables → Actions`

Add secrets such as:

| Secret | Example |
|---|---|
| `EMAIL_APPRISE_URL` | `mailtos://user:pass@smtp.gmail.com?to=you@example.com` |
| `TELEGRAM_APPRISE_URL` | `tgram://bot_token/chat_id` |
| `BARK_APPRISE_URL` | `bark://api.day.app/device_token` |
| `NTFY_APPRISE_URL` | `ntfy://your-topic` |
| `SLACK_APPRISE_URL` | `slack://xoxb-token/#general` |
| `DINGTALK_APPRISE_URL` | `dingtalk://your_access_token` |

More URL formats:

- [Apprise Wiki](https://github.com/caronc/apprise/wiki)

---

# License

MIT License — see [LICENSE](LICENSE).
