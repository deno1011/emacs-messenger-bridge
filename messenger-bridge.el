;;; messenger-bridge.el --- Channel-agnostic message bridge for Emacs -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Denis Butic

;; Author: Denis Butic <d.e.n.o@gmx.net>
;; Version: 0.3.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: comm, tools
;; Homepage: https://github.com/deno1011/emacs-messenger-bridge
;; SPDX-License-Identifier: MIT

;; This file is NOT part of GNU Emacs.
;; Released under the MIT License; see the LICENSE file.

;;; Commentary:

;; A generic, channel-agnostic message bridge.  Messages are exchanged with an
;; external channel adapter (WhatsApp, Telegram, …) through a plain directory
;; of JSON files — no open port, robust, survives restarts, trivial to debug:
;;
;;   <bridge>/inbox/     incoming  (adapter -> Emacs): one JSON file per message
;;   <bridge>/outbox/    outgoing  (Emacs -> adapter): one JSON file per message
;;   <bridge>/sent/      outbox files the adapter has sent (audit)
;;   <bridge>/processed/ inbox files Emacs has handled (idempotency/audit)
;;
;; Atomicity convention: writers create `.<name>.tmp' then `rename' it onto the
;; final `<name>.json' so a watcher never sees a half-written file.
;;
;; Message schema (JSON object):
;;   {"id","channel","chat","text","timestamp" (ISO-8601 UTC),"meta" {…}}
;;
;; Emacs side:
;;   (messenger-bridge-start)              start watching inbox/ (file-notify)
;;   (messenger-send CHAT TEXT &optional CHANNEL META)   queue an outbound msg
;;   `messenger-on-message-functions'      abnormal hook, one arg = inbound
;;                                         message plist; EAR plugs in here.
;;
;; The bridge knows nothing about any specific messenger — adapters are
;; separate processes; EAR is a separate consumer of the hook.

;;; Code:

(require 'json)
(require 'filenotify)
(require 'subr-x)

(defgroup messenger-bridge nil
  "Channel-agnostic file-based message bridge."
  :group 'comm
  :prefix "messenger-")

(defcustom messenger-bridge-directory
  (expand-file-name "messenger-bridge/" user-emacs-directory)
  "Root directory of the file bridge.
Holds the inbox/, outbox/, sent/ and processed/ subdirectories."
  :type 'directory)

(defcustom messenger-default-channel "mock"
  "Channel name stamped on outbound messages when none is given."
  :type 'string)

;;;; Outbound guardrails

(defcustom messenger-send-allowlist nil
  "JIDs `messenger-send' may INITIATE to without restriction.
Recipients who have messaged you (seen this session) are always allowed —
replying is consent-based.  Only initiating to a new, unseen JID is gated.
Approve one with `messenger-allow-recipient'."
  :type '(repeat string))

(defcustom messenger-send-block-unknown t
  "When non-nil, refuse `messenger-send' to a JID that is neither in
`messenger-send-allowlist' nor seen (has messaged you).  This guardrail stops
an agent from messaging arbitrary contacts.  Set nil to allow any recipient —
NOT recommended, it raises WhatsApp ban risk."
  :type 'boolean)

(defcustom messenger-send-min-interval 2
  "Minimum seconds between outbound sends (rate limit); 0 disables."
  :type 'number)

(defcustom messenger-send-max-per-hour 30
  "Maximum outbound sends per rolling hour; 0 disables."
  :type 'integer)

(defvar messenger-bridge--seen-jids (make-hash-table :test 'equal)
  "JIDs we received messages from this session (auto-allowed for replies).")

(defvar messenger-send--history nil
  "Float-time stamps of recent sends (newest first), for rate limiting.")

(defvar messenger-on-message-functions nil
  "Abnormal hook run once per inbound message.
Each function receives one argument: the message as a plist with keys
:id :channel :chat :text :timestamp :meta.  This is the integration point a
consumer (e.g. a chat agent) hooks into.")

(defcustom messenger-bridge-poll-interval 3
  "Seconds between inbox poll/self-heal ticks; 0 disables the poll.
A poll fallback makes delivery robust even when the `file-notify' watch dies
\(e.g. after heavy daemon activity): every tick processes any inbox backlog
and re-arms the watch if it became invalid."
  :type 'number)

(defvar messenger-bridge--watch nil
  "The active `file-notify' watch descriptor for inbox/, or nil.")

(defvar messenger-bridge--timer nil
  "Repeating poll/self-heal timer, or nil.")

;;;; Directory helpers

(defun messenger-bridge--subdir (name)
  "Return the absolute path of bridge subdirectory NAME."
  (expand-file-name name messenger-bridge-directory))

(defun messenger-bridge--ensure-dirs ()
  "Create the bridge subdirectories if missing."
  (dolist (d '("inbox" "outbox" "sent" "processed"))
    (make-directory (messenger-bridge--subdir d) t)))

(defun messenger-bridge--uuid ()
  "Return a fresh unique id string."
  (if (fboundp 'org-id-uuid)
      (org-id-uuid)
    (format "%04x%04x-%04x-%04x-%04x-%06x%06x"
            (random 65536) (random 65536) (random 65536)
            (random 65536) (random 65536) (random 16777216) (random 16777216))))

;;;; Reading / writing messages

(defun messenger-bridge--write-json (dir plist)
  "Atomically write message PLIST as a JSON file into bridge subdir DIR.
Return the final file path.  Writes `.<name>.tmp' then renames it so a
watcher never observes a partial file."
  (let* ((id (or (plist-get plist :id) (messenger-bridge--uuid)))
         (name (format "%s-%s.json"
                       (format-time-string "%Y%m%dT%H%M%S" nil t) id))
         (target (messenger-bridge--subdir dir))
         (final (expand-file-name name target))
         (tmp (expand-file-name (concat "." name ".tmp") target))
         ;; Force UTF-8 — otherwise emoji/umlauts in a message make
         ;; `write-region' prompt "Select coding system", which hangs a
         ;; headless/daemon call (no one to answer the minibuffer).
         (coding-system-for-write 'utf-8-unix))
    (with-temp-file tmp
      (insert (json-serialize plist :null-object nil :false-object :false)))
    (rename-file tmp final t)
    final))

(defun messenger-bridge--read-message (file)
  "Parse FILE as a message plist, or nil on error."
  (ignore-errors
    (let ((coding-system-for-read 'utf-8))
      (with-temp-buffer
        (insert-file-contents file)
        (json-parse-string (buffer-string)
                           :object-type 'plist :null-object nil :false-object nil)))))

;;;; Outbound

(defun messenger-send--recipient-allowed-p (chat)
  "Non-nil if CHAT is an approved outbound recipient.
Approved = guardrail off, allowlisted, or seen (they messaged you)."
  (or (not messenger-send-block-unknown)
      (member chat messenger-send-allowlist)
      (gethash chat messenger-bridge--seen-jids)))

(defun messenger-send--rate-check ()
  "Signal a `user-error' if the outbound rate limits are exceeded."
  (let ((now (float-time)))
    (setq messenger-send--history
          (seq-filter (lambda (ts) (< (- now ts) 3600)) messenger-send--history))
    (when (and (> messenger-send-min-interval 0)
               messenger-send--history
               (< (- now (car messenger-send--history))
                  messenger-send-min-interval))
      (user-error "messenger: rate limit — wait ~%ss between sends"
                  messenger-send-min-interval))
    (when (and (> messenger-send-max-per-hour 0)
               (>= (length messenger-send--history) messenger-send-max-per-hour))
      (user-error "messenger: hourly send cap (%d) reached"
                  messenger-send-max-per-hour))))

;;;###autoload
(defun messenger-send (chat text &optional channel meta)
  "Queue an outbound TEXT to CHAT on CHANNEL into the bridge outbox.
CHANNEL defaults to `messenger-default-channel'.  META is an optional plist of
channel-specific extras.  Return the message id.  An external adapter watching
outbox/ delivers it.

Guardrails (never prompt — safe to call from an agent): refuses when CHAT is
not an approved recipient (see `messenger-send--recipient-allowed-p' /
`messenger-allow-recipient') and enforces the rate limit."
  (unless (messenger-send--recipient-allowed-p chat)
    (user-error "messenger: %s not approved (they have not messaged you) — \
approve with M-x messenger-allow-recipient" chat))
  (messenger-send--rate-check)
  (messenger-bridge--ensure-dirs)
  (let* ((id (messenger-bridge--uuid))
         (plist (list :id id
                      :channel (or channel messenger-default-channel)
                      :chat chat
                      :text text
                      :timestamp (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)
                      :meta (or meta (make-hash-table :test 'equal)))))
    (messenger-bridge--write-json "outbox" plist)
    (push (float-time) messenger-send--history)
    id))

;;;; Inbound

(defun messenger-bridge--process-file (file)
  "Handle inbound message FILE: run the hook, then move it to processed/.
Non-JSON or unparsable files are left in place untouched."
  (when (string-suffix-p ".json" file)
    (let ((msg (messenger-bridge--read-message file)))
      (when msg
        (let ((from (plist-get msg :chat)))
          (when from (puthash from t messenger-bridge--seen-jids)))
        (run-hook-with-args 'messenger-on-message-functions msg)
        (rename-file file
                     (expand-file-name (file-name-nondirectory file)
                                       (messenger-bridge--subdir "processed"))
                     t)))))

(defun messenger-bridge--on-event (event)
  "Process a `file-notify' EVENT on the inbox directory."
  (let ((action (nth 1 event))
        (file (nth 2 event)))
    (when (and (memq action '(created changed renamed attribute-changed))
               (stringp file)
               (string-suffix-p ".json" file)
               (file-exists-p file))
      (ignore-errors (messenger-bridge--process-file file)))))

(defun messenger-bridge--scan-inbox ()
  "Process every JSON file currently in inbox/."
  (dolist (f (directory-files (messenger-bridge--subdir "inbox") t "\\.json\\'"))
    (ignore-errors (messenger-bridge--process-file f))))

(defun messenger-bridge--arm-watch ()
  "Ensure a valid `file-notify' watch on inbox/ exists."
  (when (and messenger-bridge--watch
             (not (file-notify-valid-p messenger-bridge--watch)))
    (setq messenger-bridge--watch nil))
  (unless messenger-bridge--watch
    (ignore-errors
      (setq messenger-bridge--watch
            (file-notify-add-watch (messenger-bridge--subdir "inbox")
                                   '(change) #'messenger-bridge--on-event)))))

(defun messenger-bridge--tick ()
  "Poll/self-heal: re-arm a dead watch and process any inbox backlog."
  (messenger-bridge--arm-watch)
  (messenger-bridge--scan-inbox))

;;;###autoload
(defun messenger-bridge-start ()
  "Start the bridge: process the inbox backlog, watch inbox/, and self-heal.
A repeating poll (`messenger-bridge-poll-interval') re-arms the watch if it
dies and catches any messages the watch missed, so delivery stays reliable."
  (interactive)
  (messenger-bridge--ensure-dirs)
  (messenger-bridge--scan-inbox)
  (messenger-bridge--arm-watch)
  (when (and (numberp messenger-bridge-poll-interval)
             (> messenger-bridge-poll-interval 0)
             (not messenger-bridge--timer))
    (setq messenger-bridge--timer
          (run-with-timer messenger-bridge-poll-interval
                          messenger-bridge-poll-interval
                          #'messenger-bridge--tick)))
  (message "messenger-bridge: watching %s (poll %ss)"
           (messenger-bridge--subdir "inbox") messenger-bridge-poll-interval))

;;;###autoload
(defun messenger-bridge-stop ()
  "Stop watching the inbox directory and cancel the poll timer."
  (interactive)
  (when messenger-bridge--watch
    (file-notify-rm-watch messenger-bridge--watch)
    (setq messenger-bridge--watch nil))
  (when messenger-bridge--timer
    (cancel-timer messenger-bridge--timer)
    (setq messenger-bridge--timer nil))
  (message "messenger-bridge: stopped"))

;;;; Default log handler (placeholder until a real consumer/EAR hooks in)

(defun messenger-bridge-log-handler (msg)
  "Append inbound MSG to the *messenger-bridge* buffer."
  (with-current-buffer (get-buffer-create "*messenger-bridge*")
    (goto-char (point-max))
    (insert (format "[%s] in  %s/%s: %s\n"
                    (or (plist-get msg :timestamp) "?")
                    (or (plist-get msg :channel) "?")
                    (or (plist-get msg :chat) "?")
                    (or (plist-get msg :text) "")))))

(add-hook 'messenger-on-message-functions #'messenger-bridge-log-handler)

;;;; Recipient approval + contacts (name resolution)

;;;###autoload
(defun messenger-allow-recipient (jid)
  "Approve JID as an outbound recipient (add to `messenger-send-allowlist').
This is the explicit consent step before the agent may INITIATE to someone who
has not messaged you.  Mind the WhatsApp ban risk of messaging many contacts."
  (interactive (list (read-string "Approve recipient JID: ")))
  (add-to-list 'messenger-send-allowlist jid)
  (message "messenger: %s approved for sending" jid))

;;;###autoload
(defun messenger-revoke-recipient (jid)
  "Remove JID from `messenger-send-allowlist'."
  (interactive (list (completing-read "Revoke JID: " messenger-send-allowlist)))
  (setq messenger-send-allowlist (delete jid messenger-send-allowlist))
  (message "messenger: %s revoked" jid))

;; Contacts are channel-agnostic here: each ADAPTER fetches its own channel's
;; contacts and writes them, normalized, to <bridge>/contacts/<channel>.json as
;; a JSON array of {e164, handle, name}.  This layer MERGES every channel's file
;; on the E.164 number, so one name resolves across WhatsApp, Signal, etc.

(defcustom messenger-contacts-directory
  (expand-file-name "contacts" messenger-bridge-directory)
  "Directory of per-channel contact files (<channel>.json) written by adapters."
  :type 'directory :group 'messenger)

(defcustom messenger-contacts-name-precedence '("whatsapp" "signal")
  "Channel order used to pick a contact's display name (and a default send
channel) when several channels know the same E.164 number."
  :type '(repeat string) :group 'messenger)

(defvar messenger-contacts--cache nil
  "Merged contact records (list of plists); see `messenger-contacts-import'.")

(defun messenger-contacts--read-channel (file)
  "Read one channel FILE: a JSON array of {e164,handle,name} -> list of plists."
  (let ((coding-system-for-read 'utf-8))
    (when (file-exists-p file)
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents file)
          (append (json-parse-string (buffer-string)
                                     :object-type 'plist :array-type 'list
                                     :null-object nil)
                  nil))))))

;;;###autoload
(defun messenger-contacts-import (&optional verbose)
  "Merge every per-channel file in `messenger-contacts-directory' on the E.164
number into one table, cached in `messenger-contacts--cache' and returned.
Each record is a plist (:e164 :name :channels ((CHANNEL . HANDLE) ...)).  A
contact a channel exposes without a number is kept keyed by channel+handle."
  (interactive (list t))
  (let ((by-key (make-hash-table :test 'equal)))
    (dolist (file (and (file-directory-p messenger-contacts-directory)
                       (directory-files messenger-contacts-directory
                                        t "\\.json\\'")))
      (let ((channel (file-name-base file)))
        (dolist (rec (messenger-contacts--read-channel file))
          (let* ((e164 (plist-get rec :e164))
                 (handle (plist-get rec :handle))
                 (name (plist-get rec :name))
                 (key (or e164 (format "%s:%s" channel handle))))
            (when handle
              (let ((cur (or (gethash key by-key)
                             (puthash key (list :e164 e164 :name nil
                                                :channels nil :names nil)
                                      by-key))))
                (setf (plist-get cur :channels)
                      (cons (cons channel handle)
                            (assoc-delete-all channel (plist-get cur :channels))))
                (when (stringp name)
                  (setf (plist-get cur :names)
                        (cons (cons channel name)
                              (assoc-delete-all channel (plist-get cur :names)))))
                (when (and e164 (null (plist-get cur :e164)))
                  (setf (plist-get cur :e164) e164))))))))
    (let (result)
      (maphash
       (lambda (_k cur)
         (let ((names (plist-get cur :names)))
           (setf (plist-get cur :name)
                 (or (seq-some (lambda (ch) (cdr (assoc ch names)))
                               messenger-contacts-name-precedence)
                     (cdar names)))
           (push cur result)))
       by-key)
      (setq messenger-contacts--cache result)))
  (when verbose
    (message "messenger: imported %d contacts (%d on >1 channel)"
             (length messenger-contacts--cache)
             (seq-count (lambda (c) (> (length (plist-get c :channels)) 1))
                        messenger-contacts--cache)))
  messenger-contacts--cache)

(defun messenger-contacts ()
  "Return the merged contact records, importing lazily on first use."
  (or messenger-contacts--cache (messenger-contacts-import)))

(defun messenger-resolve (name)
  "Return the merged contact record whose name matches NAME (substring, ci).
Signal an error if there is no match or more than one."
  (let* ((needle (downcase name))
         (matches (seq-filter
                   (lambda (c)
                     (let ((n (plist-get c :name)))
                       (and (stringp n) (string-search needle (downcase n)))))
                   (messenger-contacts))))
    (cond
     ((null matches) (user-error "messenger: no contact matches %S" name))
     ((cdr matches)
      (user-error "messenger: %S is ambiguous (%d matches)" name (length matches)))
     (t (car matches)))))

(defun messenger-contact-handle (record &optional channel)
  "Return (CHANNEL . HANDLE) to reach RECORD on.  Prefer CHANNEL if given and
available; otherwise the first channel by `messenger-contacts-name-precedence'."
  (let ((channels (plist-get record :channels)))
    (if channel
        (let ((h (cdr (assoc channel channels))))
          (and h (cons channel h)))
      (seq-some (lambda (ch)
                  (let ((h (cdr (assoc ch channels))))
                    (and h (cons ch h))))
                (append messenger-contacts-name-precedence
                        (mapcar #'car channels))))))

;;;###autoload
(defun messenger-send-to-name (name text &optional channel)
  "Resolve NAME via merged contacts and send TEXT on CHANNEL (or the preferred
one).  Interactive: pick name + channel, confirm, approve the recipient, send.
Programmatic callers should pre-approve the handle (see `messenger-send')."
  (interactive
   (let* ((rec (messenger-resolve (read-string "Contact name: ")))
          (chans (mapcar #'car (plist-get rec :channels)))
          (chan (if (cdr chans) (completing-read "Channel: " chans nil t)
                  (car chans)))
          (ch (messenger-contact-handle rec chan)))
     (unless ch
       (user-error "messenger: %s not reachable on %s" (plist-get rec :name) chan))
     (unless (y-or-n-p (format "Send to %s on %s (%s)? "
                               (plist-get rec :name) (car ch) (cdr ch)))
       (user-error "Cancelled"))
     (messenger-allow-recipient (cdr ch))
     (list (plist-get rec :name)
           (read-string (format "Message to %s: " (plist-get rec :name)))
           (car ch))))
  (let* ((rec (messenger-resolve name))
         (ch (messenger-contact-handle rec channel)))
    (unless ch
      (user-error "messenger: %s not reachable on %s" name (or channel "any channel")))
    (messenger-send (cdr ch) text (car ch))))

(provide 'messenger-bridge)
;;; messenger-bridge.el ends here
