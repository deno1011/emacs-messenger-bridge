;;; messenger-bridge-tests.el --- Tests for messenger-bridge -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;;; Commentary:
;; ERT tests that exercise the bridge against a throwaway temp directory.

;;; Code:

(require 'ert)
(require 'messenger-bridge)

(defmacro messenger-bridge-tests--with-temp-bridge (&rest body)
  "Run BODY with `messenger-bridge-directory' bound to a fresh temp dir."
  (declare (indent 0))
  `(let ((messenger-bridge-directory (make-temp-file "mbridge" t "/"))
         (messenger-on-message-functions nil)
         ;; default guardrails off for the plain send tests
         (messenger-send-block-unknown nil)
         (messenger-send-min-interval 0)
         (messenger-send-max-per-hour 0)
         (messenger-send-allowlist nil)
         (messenger-send--history nil)
         (messenger-bridge--seen-jids (make-hash-table :test 'equal)))
     (unwind-protect
         (progn (messenger-bridge--ensure-dirs) ,@body)
       (delete-directory messenger-bridge-directory t))))

(ert-deftest messenger-bridge-test-send-writes-valid-json ()
  "`messenger-send' writes one parseable JSON file into outbox/ with the schema."
  (messenger-bridge-tests--with-temp-bridge
    (let ((id (messenger-send "me" "hallo" "mock")))
      (let ((files (directory-files (messenger-bridge--subdir "outbox") t "\\.json\\'")))
        (should (= 1 (length files)))
        (let ((msg (messenger-bridge--read-message (car files))))
          (should (equal id (plist-get msg :id)))
          (should (equal "me" (plist-get msg :chat)))
          (should (equal "hallo" (plist-get msg :text)))
          (should (equal "mock" (plist-get msg :channel)))
          (should (plist-get msg :timestamp)))))))

(ert-deftest messenger-bridge-test-default-channel ()
  "An omitted channel falls back to `messenger-default-channel'."
  (messenger-bridge-tests--with-temp-bridge
    (let ((messenger-default-channel "tg"))
      (messenger-send "x" "y")
      (let* ((f (car (directory-files (messenger-bridge--subdir "outbox") t "\\.json\\'")))
             (msg (messenger-bridge--read-message f)))
        (should (equal "tg" (plist-get msg :channel)))))))

(ert-deftest messenger-bridge-test-process-inbound-runs-hook-and-moves ()
  "Processing an inbox file runs the hook with the message and moves the file."
  (messenger-bridge-tests--with-temp-bridge
    (let (captured)
      (add-hook 'messenger-on-message-functions
                (lambda (msg) (setq captured msg)))
      ;; drop a message into inbox/ (as an adapter would)
      (let ((file (messenger-bridge--write-json "inbox"
                    (list :id "abc" :channel "mock" :chat "me"
                          :text "ping" :timestamp "2026-06-25T00:00:00Z"
                          :meta (make-hash-table :test 'equal)))))
        (messenger-bridge--process-file file)
        ;; hook saw it
        (should captured)
        (should (equal "ping" (plist-get captured :text)))
        (should (equal "me" (plist-get captured :chat)))
        ;; original moved out of inbox, into processed
        (should-not (file-exists-p file))
        (should (= 1 (length (directory-files (messenger-bridge--subdir "processed")
                                              nil "\\.json\\'"))))
        (should (= 0 (length (directory-files (messenger-bridge--subdir "inbox")
                                              nil "\\.json\\'"))))))))

(ert-deftest messenger-bridge-test-roundtrip-ids-unique ()
  "Two sends produce two distinct ids and two outbox files."
  (messenger-bridge-tests--with-temp-bridge
    (let ((a (messenger-send "me" "1"))
          (b (messenger-send "me" "2")))
      (should-not (equal a b))
      (should (= 2 (length (directory-files (messenger-bridge--subdir "outbox")
                                            nil "\\.json\\'")))))))

(ert-deftest messenger-bridge-test-guardrail-blocks-unknown ()
  "With the guardrail on, sending to an unapproved/unseen JID is refused."
  (messenger-bridge-tests--with-temp-bridge
    (let ((messenger-send-block-unknown t))
      (should-error (messenger-send "stranger@x" "hi") :type 'user-error)
      ;; allowlisting approves it
      (let ((messenger-send-allowlist '("stranger@x")))
        (should (messenger-send "stranger@x" "hi")))
      ;; a JID that messaged us (seen) is allowed without allowlisting
      (puthash "friend@x" t messenger-bridge--seen-jids)
      (should (messenger-send "friend@x" "reply")))))

(ert-deftest messenger-bridge-test-rate-limit ()
  "The min-interval rate limit refuses a too-fast second send."
  (messenger-bridge-tests--with-temp-bridge
    (let ((messenger-send-block-unknown nil)
          (messenger-send-min-interval 60))
      (should (messenger-send "me" "1"))
      (should-error (messenger-send "me" "2") :type 'user-error))))

(ert-deftest messenger-bridge-test-process-records-seen ()
  "Processing an inbound message records its chat JID as seen."
  (messenger-bridge-tests--with-temp-bridge
    (let ((file (messenger-bridge--write-json "inbox"
                  (list :id "s1" :channel "whatsapp" :chat "x@lid"
                        :text "hi" :timestamp "2026-06-25T00:00:00Z"
                        :meta (make-hash-table :test 'equal)))))
      (messenger-bridge--process-file file)
      (should (gethash "x@lid" messenger-bridge--seen-jids)))))

(provide 'messenger-bridge-tests)
;;; messenger-bridge-tests.el ends here
