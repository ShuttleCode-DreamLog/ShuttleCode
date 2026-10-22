#!/usr/bin/env python3
"""Seed the local backend with invented sample dreams so Home shows a bubble cluster and Patterns has findings.

Usage: python3 scripts/seed-local.py [--user <uuid>] [--base https://127.0.0.1:8443] [--cafile backend/.local/server.crt]
Without --user it seeds the journal of the user with the most dreams in backend/.local/data/dreamlog.db (the simulator's).
"""
import argparse, json, sqlite3, ssl, sys, time, urllib.request, uuid
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SAMPLES = [
    ("Floating garden", "happy", 1, "I walked into a floating garden above the clouds. A friend I had not seen in years was waiting there. We planted flowers together and I felt calm and happy."),
    ("Silver moon chase", "afraid", 3, "I was running through a forest under a bright moon. A dragon followed me, but when I stopped it turned into a small bird. I felt relieved."),
    ("Late for the exam", "anxious", 5, "I arrived late to an exam hall and could not find my seat. Everyone was already writing. I felt anxious and small."),
    ("Ocean swim", "calm", 7, "I swam in a warm, clear ocean beside slow turtles. The water held me and I felt completely at peace."),
    ("Old house, new rooms", "confused", 9, "My childhood house had new rooms I had never seen. Each door opened to a different season. I felt curious and a little sad."),
    ("Flying over the city", "excited", 11, "I lifted off the roof and flew over the city at sunrise. Friends waved from balconies. I felt free and happy."),
    ("Lost phone in the rain", "anxious", 13, "I lost my phone in a crowded market in the rain and could not call anyone. I kept searching and felt worried."),
    ("Dinner with grandmother", "happy", 15, "I had dinner with my grandmother in a garden full of lanterns. We laughed about old stories. I woke up happy and missing her."),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--user")
    parser.add_argument("--base", default="https://127.0.0.1:8443")
    parser.add_argument("--cafile", default=str(ROOT / "backend/.local/server.crt"))
    args = parser.parse_args()
    user = args.user or sqlite3.connect(ROOT / "backend/.local/data/dreamlog.db").execute(
        "SELECT user_id FROM dreams GROUP BY user_id ORDER BY count(*) DESC LIMIT 1").fetchone()[0]
    context = ssl.create_default_context(cafile=args.cafile)

    def call(method, path, body=None):
        request = urllib.request.Request(args.base + path, method=method, data=json.dumps(body).encode() if body else None,
                                         headers={"Authorization": f"Bearer {user}", "Content-Type": "application/json"})
        with urllib.request.urlopen(request, context=context, timeout=30) as response:
            return json.loads(response.read())

    print("user", user)
    ids = []
    for title, mood, days_ago, text in SAMPLES:
        dream_id = str(uuid.uuid4())
        call("PUT", f"/v1/dreams/{dream_id}", {"base_revision": 0, "text": text, "title": title, "mood": mood, "source": "text",
                                               "dream_date": (date.today() - timedelta(days=days_ago)).isoformat()})
        ids.append((title, dream_id))
    # The worker summarizes each dream in the background; wait for the tags so the cluster is there when the app reloads.
    for _ in range(36):
        time.sleep(5)
        organized = {title: call("GET", f"/v1/dreams/{dream_id}")["dream"].get("organization") for title, dream_id in ids}
        if all(organized.values()):
            break
    for title, organization in organized.items():
        tags = [f"{tag['category']}:{tag['text']}" for tag in organization["tags"]] if organization else ["(not organized yet)"]
        print(f"{title}: {', '.join(tags)}")
    return 0 if all(organized.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
