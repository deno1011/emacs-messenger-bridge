#!/usr/bin/env python3
"""Mock channel adapter for emacs-messenger-bridge.

Lets you exercise the whole Emacs<->bridge round trip without any real
messenger.  It speaks the same file protocol a real adapter (WhatsApp,
Telegram, …) would:

  send   write an inbound message into <bridge>/inbox/   (simulates a
         message arriving from the channel -> Emacs picks it up)
  watch  poll <bridge>/outbox/, print outgoing messages, move them to sent/
         (simulates the adapter delivering Emacs' replies to the channel)

Bridge directory: $MESSENGER_BRIDGE_DIR or ~/.emacs.d/messenger-bridge

Usage:
  mock_adapter.py send [CHAT] [TEXT...]
  mock_adapter.py watch [INTERVAL_SECONDS]
"""
import sys
import os
import json
import time
import uuid
import glob
import shutil

BRIDGE = os.environ.get(
    "MESSENGER_BRIDGE_DIR",
    os.path.expanduser("~/.emacs.d/messenger-bridge"),
)


def ensure():
    for d in ("inbox", "outbox", "sent", "processed"):
        os.makedirs(os.path.join(BRIDGE, d), exist_ok=True)


def send(chat, text, channel="mock"):
    ensure()
    mid = str(uuid.uuid4())
    msg = {
        "id": mid,
        "channel": channel,
        "chat": chat,
        "text": text,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "meta": {},
    }
    name = "{}-{}.json".format(time.strftime("%Y%m%dT%H%M%S", time.gmtime()), mid)
    inbox = os.path.join(BRIDGE, "inbox")
    tmp = os.path.join(inbox, "." + name + ".tmp")
    final = os.path.join(inbox, name)
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(msg, fh, ensure_ascii=False)
    os.rename(tmp, final)          # atomic: Emacs only ever sees the final file
    print("-> inbox: {}".format(name))


def watch(interval=1.0):
    ensure()
    outbox = os.path.join(BRIDGE, "outbox")
    sent = os.path.join(BRIDGE, "sent")
    print("watching {} (Ctrl-C to stop)".format(outbox))
    try:
        while True:
            for f in sorted(glob.glob(os.path.join(outbox, "*.json"))):
                try:
                    with open(f, encoding="utf-8") as fh:
                        msg = json.load(fh)
                    print("<- OUT {}/{}: {}".format(
                        msg.get("channel"), msg.get("chat"), msg.get("text")))
                    shutil.move(f, os.path.join(sent, os.path.basename(f)))
                except Exception as exc:  # noqa: BLE001
                    print("err reading {}: {}".format(f, exc), file=sys.stderr)
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\nstopped")


def main(argv):
    if len(argv) >= 2 and argv[1] == "send":
        chat = argv[2] if len(argv) > 2 else "me"
        text = " ".join(argv[3:]) if len(argv) > 3 else "hello from mock"
        send(chat, text)
    elif len(argv) >= 2 and argv[1] == "watch":
        watch(float(argv[2]) if len(argv) > 2 else 1.0)
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
