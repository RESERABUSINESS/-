#!/usr/bin/env python3
"""Send the day's queued emails for the Fatoorati lead agent via the Resend API.

Usage:
    python3 agent/send_email.py outreach/2026-11-23.json            # send
    python3 agent/send_email.py outreach/2026-11-23.json --dry-run  # check only

Queue file: a JSON list of
    {"type": "outreach" | "followup1" | "followup2" | "reply",
     "lead_id": "L0001",            # required except for some replies
     "to": "name@business.com",
     "subject": "...",
     "body": "plain text, no unsubscribe line (added automatically)"}

Safety checks (an item failing any of them is skipped, never sent):
  - daily cap from agent/email_config.json (counted across all runs today)
  - never email opted_out leads, or the same lead the same step twice
  - outreach/follow-ups only for leads in a state that allows that step
  - follow-ups only once next_followup is due
  - replies containing "[يحتاج تأكيد" are held for the owner
The API key is never read here: the environment's network proxy adds it.
"""
import csv
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "agent", "email_config.json")
LEADS = os.path.join(ROOT, "data", "leads.csv")
SENT_LOG = os.path.join(ROOT, "data", "sent_log.csv")
SENT_FIELDS = ["date", "time_utc", "lead_id", "type", "to", "subject", "resend_id"]

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
ALLOWED_STATUS = {
    "outreach": {"new"},
    "followup1": {"contacted"},
    "followup2": {"contacted"},
}
REQUIRED_FOLLOWUPS = {"followup1": 0, "followup2": 1}
FOLLOWUP_GAP_DAYS = {"outreach": 3, "followup1": 5, "followup2": None}


def riyadh_today():
    return (dt.datetime.now(dt.timezone.utc).replace(tzinfo=None) + dt.timedelta(hours=3)).date()


def load_leads():
    with open(LEADS, encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        return reader.fieldnames, list(reader)


def save_leads(fields, rows):
    with open(LEADS, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)


def load_sent():
    if not os.path.exists(SENT_LOG):
        return []
    with open(SENT_LOG, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def append_sent(row):
    new = not os.path.exists(SENT_LOG)
    with open(SENT_LOG, "a", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=SENT_FIELDS)
        if new:
            w.writeheader()
        w.writerow(row)


def send(cfg, item):
    footer = cfg["unsubscribe_line"]
    payload = {
        "from": cfg["from"],
        "to": [item["to"]],
        "subject": item["subject"],
        "text": item["body"].rstrip() + "\n\n—\n" + footer,
        "reply_to": cfg["reply_to"],
        "headers": {
            "List-Unsubscribe": f"<mailto:{cfg['reply_to']}?subject=unsubscribe>"
        },
    }
    req = urllib.request.Request(
        "https://api.resend.com/emails",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            # Placeholder: the network proxy replaces it with the saved key.
            "Authorization": "Bearer re_placeholder",
            "User-Agent": "fatoorati-lead-agent/1.0",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode()).get("id", "")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if len(args) != 1:
        sys.exit(__doc__)
    with open(CONFIG, encoding="utf-8") as f:
        cfg = json.load(f)
    if "<" in cfg["from"] and "@" not in cfg["from"]:
        sys.exit("email_config.json: set 'from' first")
    if not cfg.get("enabled", False) and not dry:
        sys.exit("email_config.json: sending is disabled (enabled=false). Nothing sent.")
    with open(args[0], encoding="utf-8") as f:
        queue = json.load(f)

    fields, leads = load_leads()
    by_id = {r["id"]: r for r in leads}
    sent = load_sent()
    today = riyadh_today()
    sent_today = sum(1 for s in sent if s["date"] == today.isoformat())
    done = {(s["lead_id"], s["type"]) for s in sent}
    cap = int(cfg["daily_limit"])

    results = {"sent": 0, "skipped": []}
    for item in queue:
        kind, lid, to = item.get("type"), item.get("lead_id", ""), item.get("to", "").strip()
        lead = by_id.get(lid)

        def skip(why):
            results["skipped"].append(f"{lid or to} [{kind}]: {why}")

        if kind not in ("outreach", "followup1", "followup2", "reply"):
            skip("unknown type"); continue
        if not EMAIL_RE.match(to):
            skip("bad email"); continue
        if not item.get("subject") or not item.get("body"):
            skip("empty subject/body"); continue
        if sent_today >= cap:
            skip(f"daily cap {cap} reached"); continue
        if lead and lead["status"] == "opted_out":
            skip("opted_out"); continue
        if any(r["status"] == "opted_out" and r["contact"].strip().lower() == to.lower() for r in leads):
            skip("address opted_out"); continue
        if kind == "reply":
            if "[يحتاج تأكيد" in item["body"]:
                skip("needs owner confirmation"); continue
        else:
            if not lead:
                skip("lead not in leads.csv"); continue
            if lead["channel"] != "email" or lead["contact"].strip().lower() != to.lower():
                skip("address does not match lead's public business email"); continue
            if (lid, kind) in done:
                skip("already sent this step"); continue
            if lead["status"] not in ALLOWED_STATUS[kind]:
                skip(f"status is {lead['status']}"); continue
            if kind in REQUIRED_FOLLOWUPS:
                if int(lead.get("followups_sent") or 0) != REQUIRED_FOLLOWUPS[kind]:
                    skip("wrong follow-up step"); continue
                due = lead.get("next_followup") or ""
                if not due or due > today.isoformat():
                    skip(f"follow-up not due ({due})"); continue
            if kind == "outreach" and int(lead.get("fit_score") or 0) < int(cfg.get("min_fit_score", 6)):
                skip("fit_score too low"); continue

        if dry:
            print(f"[dry-run] would send {kind} to {to}: {item['subject']}")
            sent_today += 1
            results["sent"] += 1
            continue
        try:
            rid = send(cfg, item)
        except urllib.error.HTTPError as e:
            skip(f"API error {e.code}: {e.read().decode(errors='ignore')[:200]}")
            if e.code in (401, 403):
                break
            continue
        except Exception as e:  # network etc.
            skip(f"error: {e}"); continue

        now = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
        append_sent({"date": today.isoformat(), "time_utc": now.strftime("%H:%M:%S"),
                     "lead_id": lid, "type": kind, "to": to,
                     "subject": item["subject"], "resend_id": rid})
        done.add((lid, kind))
        sent_today += 1
        results["sent"] += 1
        if lead and kind != "reply":
            lead["last_contact"] = today.isoformat()
            if kind == "outreach":
                lead["status"] = "contacted"
                lead["followups_sent"] = "0"
            else:
                lead["followups_sent"] = str(int(lead.get("followups_sent") or 0) + 1)
            gap = FOLLOWUP_GAP_DAYS[kind]
            if gap is None:
                lead["status"] = "cold"
                lead["next_followup"] = ""
            else:
                lead["next_followup"] = (today + dt.timedelta(days=gap)).isoformat()

    if not dry:
        save_leads(fields, leads)
    print(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
