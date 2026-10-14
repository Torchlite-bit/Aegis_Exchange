"""
Posts this version's changelog to the addon's post in the Aegis Discord's changelogs forum. Run by
.github/workflows/release.yml in the run on a new version's tag, after the packager, with the
notes it wrote (RELEASE_NOTES.md). The same file serves every Aegis addon; the workflow names the
addon.

    python .github/discord_changelog.py RELEASE_NOTES.md

Environment (the workflow sets these):
  DISCORD_WEBHOOK_URL   repository secret: the changelogs forum's webhook. Without it, nothing is posted.
  DISCORD_THREAD_ID     repository variable: this addon's post in that forum
  DISCORD_PING_ROLE_ID  optional repository variable: a role to mention; nobody is pinged otherwise
  ADDON_TITLE           the addon's name, e.g. "Aegis: Courier"
  ADDON_COLOUR          the post's colour, as hex
  GITHUB_REF_NAME, GITHUB_SERVER_URL, GITHUB_REPOSITORY   set by GitHub Actions

The webhook address is a password for that channel: it is never printed.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

DESCRIPTION_MAX = 4000            # Discord allows 4096 in an embed's description
WEBHOOK = re.compile(r"https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/(?:v\d+/)?webhooks/\d+/[\w-]+")


def message(title, tag, notes, url, colour, role_id=None):
    text = notes.strip() or "{} {}".format(title, tag)
    if len(text) > DESCRIPTION_MAX:
        more = "\n\n… [Read the rest]({})".format(url)
        text = text[:DESCRIPTION_MAX - len(more)].rstrip() + more
    body = {
        "username": title,
        "embeds": [{"title": "{} {}".format(title, tag), "url": url, "description": text, "color": colour}],
        # Nobody is mentioned unless a role is named: an "@everyone" in a changelog stays text.
        "allowed_mentions": {"parse": []},
    }
    if role_id:
        body["content"] = "<@&{}>".format(role_id)
        body["allowed_mentions"] = {"parse": [], "roles": [role_id]}
    return body


def post(webhook, body, thread_id, repository):
    target = webhook + "?wait=true" + ("&thread_id=" + thread_id if thread_id else "")
    req = urllib.request.Request(target, data=json.dumps(body).encode("utf-8"), headers={
        "Content-Type": "application/json", "User-Agent": "DiscordBot ({}, 1.0)".format(repository)})
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.loads(response.read().decode("utf-8") or "{}").get("id")
    except urllib.error.HTTPError as error:
        answer = error.read().decode("utf-8", "replace")[:500]
        if error.code == 400 and not thread_id and "thread" in answer.lower():
            sys.exit("This webhook belongs to a forum: set the DISCORD_THREAD_ID variable to this addon's post.")
        sys.exit("Discord answered {}: {}".format(error.code, answer))
    except urllib.error.URLError as error:
        sys.exit("Discord couldn't be reached: {}".format(error.reason))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    webhook = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if not webhook:
        print("Discord post skipped: no DISCORD_WEBHOOK_URL secret. (Settings, Secrets and variables, Actions.)")
        return 0
    if not WEBHOOK.fullmatch(webhook):
        sys.exit("DISCORD_WEBHOOK_URL doesn't look like a Discord webhook address (it isn't shown here).")
    thread_id = os.environ.get("DISCORD_THREAD_ID", "").strip() or None
    role_id = os.environ.get("DISCORD_PING_ROLE_ID", "").strip() or None
    for name, value in (("DISCORD_THREAD_ID", thread_id), ("DISCORD_PING_ROLE_ID", role_id)):
        if value and not value.isdigit():
            sys.exit("{} should be a number (Discord: right-click, Copy ID).".format(name))
    title = os.environ.get("ADDON_TITLE", "").strip() or os.environ.get("GITHUB_REPOSITORY", "Aegis addon")
    colour = int((os.environ.get("ADDON_COLOUR", "") or "9E1B1B").lstrip("#"), 16)
    tag = os.environ.get("GITHUB_REF_NAME", "").strip()
    repository = "{}/{}".format(os.environ.get("GITHUB_SERVER_URL", "https://github.com"), os.environ.get("GITHUB_REPOSITORY", ""))
    url = "{}/releases/tag/{}".format(repository, tag)
    notes_file = argv[0] if argv else "RELEASE_NOTES.md"
    with open(notes_file, encoding="utf-8") as handle:
        notes = handle.read()
    message_id = post(webhook, message(title, tag, notes, url, colour, role_id), thread_id, repository)
    print("Posted {} {} to Discord: message {}.".format(title, tag, message_id))
    return 0


if __name__ == "__main__":
    sys.exit(main())
