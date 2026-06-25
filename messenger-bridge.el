;;; messenger-bridge.el --- Channel-agnostic message bridge for Emacs -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Denis Butic

;; Author: Denis Butic <d.e.n.o@gmx.net>
;; Version: 0.1.0
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

(defvar messenger-on-message-functions nil
  "Abnormal hook run once per inbound message.
Each function receives one argument: the message as a plist with keys
:id :channel :chat :text :timestamp :meta.  This is the integration point a
consumer (e.g. a chat agent) hooks into.")

(defvar messenger-bridge--watch nil
  "The active `file-notify' watch descriptor for inbox/, or nil.")

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
         (tmp (expand-file-name (concat "." name ".tmp") target)))
    (with-temp-file tmp
      (insert (json-serialize plist :null-object nil :false-object :false)))
    (rename-file tmp final t)
    final))

(defun messenger-bridge--read-message (file)
  "Parse FILE as a message plist, or nil on error."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents file)
      (json-parse-string (buffer-string)
                         :object-type 'plist :null-object nil :false-object nil))))

;;;; Outbound

;;;###autoload
(defun messenger-send (chat text &optional channel meta)
  "Queue an outbound TEXT to CHAT on CHANNEL into the bridge outbox.
CHANNEL defaults to `messenger-default-channel'.  META is an optional plist of
channel-specific extras.  Return the message id.  An external adapter watching
outbox/ delivers it."
  (messenger-bridge--ensure-dirs)
  (let* ((id (messenger-bridge--uuid))
         (plist (list :id id
                      :channel (or channel messenger-default-channel)
                      :chat chat
                      :text text
                      :timestamp (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)
                      :meta (or meta (make-hash-table :test 'equal)))))
    (messenger-bridge--write-json "outbox" plist)
    id))

;;;; Inbound

(defun messenger-bridge--process-file (file)
  "Handle inbound message FILE: run the hook, then move it to processed/.
Non-JSON or unparsable files are left in place untouched."
  (when (string-suffix-p ".json" file)
    (let ((msg (messenger-bridge--read-message file)))
      (when msg
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

;;;###autoload
(defun messenger-bridge-start ()
  "Start the bridge: process any inbox backlog, then watch inbox/."
  (interactive)
  (messenger-bridge--ensure-dirs)
  (dolist (f (directory-files (messenger-bridge--subdir "inbox") t "\\.json\\'"))
    (ignore-errors (messenger-bridge--process-file f)))
  (unless messenger-bridge--watch
    (setq messenger-bridge--watch
          (file-notify-add-watch (messenger-bridge--subdir "inbox")
                                 '(change) #'messenger-bridge--on-event)))
  (message "messenger-bridge: watching %s" (messenger-bridge--subdir "inbox")))

;;;###autoload
(defun messenger-bridge-stop ()
  "Stop watching the inbox directory."
  (interactive)
  (when messenger-bridge--watch
    (file-notify-rm-watch messenger-bridge--watch)
    (setq messenger-bridge--watch nil))
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

(provide 'messenger-bridge)
;;; messenger-bridge.el ends here
