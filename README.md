# emacs-messenger-bridge

A generic, **channel-agnostic** message bridge for Emacs. It lets Emacs (and a
future chat agent such as EAR) **send and receive messages** through an
external channel adapter — WhatsApp, Telegram, Signal, … — without Emacs ever
speaking the channel's protocol itself.

Messages are exchanged with the adapter through a plain **directory of JSON
files**: no open port, robust, survives restarts, trivial to debug. The bridge
knows nothing about any specific messenger; concrete adapters are separate
processes, and the agent is a separate consumer.

```
┌──────────────┐   outbox/*.json   ┌──────────────┐   send    ┌─────────┐
│  Emacs / EAR │ ────────────────▶ │   adapter    │ ────────▶ │ channel │
│ messenger-   │                   │ (WhatsApp /  │           │ (phone) │
│  bridge.el   │ ◀──────────────── │  Telegram /  │ ◀──────── │         │
└──────────────┘   inbox/*.json    │  mock …)     │  receive  └─────────┘
     ▲  hook                       └──────────────┘
     │ messenger-on-message-functions
   EAR plugs in here
```

## Directory protocol

```
<bridge>/
├── inbox/        incoming (adapter → Emacs): one JSON file per message
├── outbox/       outgoing (Emacs → adapter): one JSON file per message
├── sent/         outbox files the adapter has delivered (audit)
└── processed/    inbox files Emacs has handled (idempotency/audit)
```

**Atomicity:** writers create `.<name>.tmp` then `rename` it onto the final
`<name>.json`, so a watcher never observes a half-written file.

## Message schema (JSON object)

```json
{
  "id": "uuid",
  "channel": "whatsapp|telegram|mock",
  "chat": "<sender/recipient id>",
  "text": "message body",
  "timestamp": "2026-06-25T18:30:00Z",
  "meta": { }
}
```

`meta` carries channel-specific extras; the agent may ignore it.

## Emacs side (`messenger-bridge.el`)

| Entry point | What it does |
|---|---|
| `M-x messenger-bridge-start` | process any inbox backlog, then watch `inbox/` (file-notify) |
| `M-x messenger-bridge-stop` | stop watching |
| `(messenger-send CHAT TEXT &optional CHANNEL META)` | queue an outbound message into `outbox/`; returns its id |
| `messenger-on-message-functions` | abnormal hook, one arg = inbound message plist `(:id :channel :chat :text :timestamp :meta)` — **EAR plugs in here** |

A default `messenger-bridge-log-handler` logs inbound messages to the
`*messenger-bridge*` buffer until a real consumer is wired in.

Config:

```elisp
(setq messenger-bridge-directory "~/.emacs.d/messenger-bridge/") ; default
(setq messenger-default-channel "mock")
(require 'messenger-bridge)
(messenger-bridge-start)
```

## Try it end-to-end (mock adapter, no real channel)

```bash
# 1) In Emacs: (require 'messenger-bridge) (messenger-bridge-start)

# 2) Simulate an inbound message from the channel:
python3 adapters/mock_adapter.py send me "Hallo Coach"
#    -> Emacs' inbox watcher fires; see the *messenger-bridge* buffer.

# 3) In Emacs, send a reply:
#    (messenger-send "me" "Antwort vom Agent")

# 4) Simulate the adapter delivering it:
python3 adapters/mock_adapter.py watch
#    <- OUT mock/me: Antwort vom Agent
```

Bridge directory override for the adapter: `MESSENGER_BRIDGE_DIR=/path`.

## Status / roadmap

- [x] Generic file-bridge protocol + schema
- [x] Emacs client: `messenger-send`, inbox watcher, `messenger-on-message-functions`
- [x] Mock adapter (round-trip test without a real channel)
- [ ] Real channel adapter (WhatsApp via Baileys / Cloud API / Matrix — TBD)
- [ ] EAR consumer wired onto `messenger-on-message-functions`

The channel choice (official Cloud API vs unofficial Baileys vs Matrix bridge)
is deferred until the EAR integration is proven over the mock adapter.

## License

MIT. See [LICENSE](LICENSE).
