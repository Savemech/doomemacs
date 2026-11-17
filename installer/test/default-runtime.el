;;; default-runtime.el --- Isolated Windows bundle operations -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
;; Same language environment as lisp/doom-emacs.el, without private config.
(set-language-environment "UTF-8")
(setq make-backup-files nil create-lockfiles nil)
(defvar doom-test-failures nil)
(defvar doom-test-root (file-name-as-directory (getenv "DOOM_BUNDLE_ROOT")))
(load (expand-file-name "bridge/runtime.el" doom-test-root) nil t)
(defvar doom-test-directory
  (expand-file-name (concat "files with space " (string #x444) "/") (getenv "DOOM_DEFAULT_TEST")))
(make-directory doom-test-directory t)
(setq default-directory doom-test-directory)
(defun doom-test-check (label function)
  (condition-case err
      (progn (funcall function) (princ (format "PASS: %s\n" label)))
    (error (push label doom-test-failures)
           (princ (format "FAIL: %s: %s\n" label (error-message-string err))))))
(defun doom-test-run (program &rest arguments)
  (with-temp-buffer
    (let ((code (apply #'process-file program nil (current-buffer) nil arguments)))
      (unless (eq code 0) (error "%s exited %s: %s" program code (buffer-string)))
      (buffer-string))))
(defun doom-test-write (file text)
  (let ((coding-system-for-write 'utf-8-unix)) (write-region text nil file nil 'silent)))
(defun doom-test-read (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(doom-test-check "default tools resolve inside the bundle, including Bash"
 (lambda ()
   (dolist (program '("git" "sh" "bash" "diff" "diff3" "patch" "grep" "find" "ls"
                      "sed" "awk" "xargs" "gzip" "gunzip" "bzip2" "bunzip2" "unzip" "zipinfo" "less"
                      "ssh" "ssh-agent" "ssh-add" "ssh-keygen" "scp" "sftp"
                      "zstd" "unzstd" "xz" "unxz" "7za" "7z" "shellcheck" "pandoc" "rg" "fd" "etags"))
     (let ((file (executable-find program)))
       (unless (and file (string-prefix-p (file-name-as-directory (file-truename doom-test-root)) (file-truename file) t))
         (error "%s resolves outside the bundle: %s" program file))))))

(doom-test-check "native Bash, text utilities and pipes"
 (lambda ()
   (unless (string-match-p "native-bash"
             (doom-test-run "bash" "--noprofile" "--norc" "-c"
                            "test -n \"$BASH_VERSION\" && printf 'native-bash\\n' | grep native | sed s/native/native/ | awk '{print $0}'"))
     (error "Bash/text pipeline failed"))))

(auto-compression-mode 1)
(dolist (extension '("gz" "bz2" "xz" "zst"))
  (doom-test-check (concat "Emacs compressed save/read ." extension " in a Unicode directory")
   (lambda ()
     (let* ((file (expand-file-name (concat "history.el." extension) doom-test-directory))
            (text (concat "persistent undo " (string #x444) "\n")))
       (doom-test-write file text)
       (unless (equal text (doom-test-read file)) (error "Compressed content changed"))))))

(doom-test-check "file search and content search"
 (lambda ()
   (doom-test-write "search.txt" "needle-123\n")
   (unless (string-match-p "needle-123" (doom-test-run "rg" "--fixed-strings" "needle-123" "search.txt")) (error "ripgrep failed"))
   (unless (string-match-p "search.txt" (doom-test-run "fd" "--color=never" "search" ".")) (error "fd failed"))))

(doom-test-check "diff and patch apply actual changes"
 (lambda ()
   (doom-test-write "edit.txt" "before\n")
   (doom-test-write "after.txt" "after\n")
   (with-temp-buffer
     (unless (eq 1 (process-file "diff" nil t nil "-u" "--label" "edit.txt" "edit.txt" "--label" "edit.txt" "after.txt"))
       (error "diff did not report changes"))
     (doom-test-write "change.patch" (buffer-string)))
   (doom-test-run "patch" "--batch" "-p0" "--input=change.patch")
   (unless (equal (doom-test-read "edit.txt") "after\n") (error "Patch did not apply"))))

(doom-test-check "Git init, commit and Emacs VC state"
 (lambda ()
   (let ((default-directory (expand-file-name "repository/" doom-test-directory)))
     (make-directory default-directory t)
     (doom-test-run "git" "init" "-q" "-b" "main")
     (doom-test-write "versioned.txt" "original\n")
     (doom-test-run "git" "add" "versioned.txt")
     (doom-test-run "git" "-c" "user.name=Fixture" "-c" "user.email=fixture@example.invalid" "-c" "commit.gpgsign=false" "commit" "-qm" "fixture")
     (require 'vc-git)
     (unless (eq 'up-to-date (vc-git-state (expand-file-name "versioned.txt"))) (error "Clean VC state is incorrect"))
     (doom-test-write "versioned.txt" "modified\n")
     (unless (eq 'edited (vc-git-state (expand-file-name "versioned.txt"))) (error "Edited VC state is incorrect")))))

(doom-test-check "SSH key generation without network or real user keys"
 (lambda ()
   (doom-test-run "ssh" "-V")
   (doom-test-run "ssh-keygen" "-q" "-t" "ed25519" "-N" "" "-f" "fixture-key")
   (unless (file-exists-p "fixture-key.pub") (error "Public key missing"))))

(doom-test-check "ShellCheck returns useful shell diagnostics"
 (lambda ()
   (doom-test-write "lint.sh" "#!/bin/sh\necho $word\n")
   (with-temp-buffer
     (unless (and (eq 1 (process-file "shellcheck" nil t nil "--format=json" "lint.sh"))
                  (string-match-p "2086" (buffer-string))) (error "Shell diagnostics missing: %s" (buffer-string))))))

;; Load the actual module's Markdown compiler function, without loading a private
;; config or initializing an unrelated package manager in the test process.
(doom-test-check "Doom Markdown compiler produces HTML"
 (lambda ()
   (with-temp-buffer
     (insert-file-contents (expand-file-name "doom/sources/doom+/modules/lang/markdown/autoload.el" doom-test-root))
     (goto-char (point-min))
     (let (form found)
       (while (and (not found) (< (point) (point-max)))
         (setq form (read (current-buffer)))
         (when (and (eq (car-safe form) 'defun) (eq (cadr form) '+markdown-compile-pandoc))
           (eval form t) (setq found t)))
       (unless found (error "Default Markdown handler moved; review upstream"))))
   (let ((output (generate-new-buffer " *markdown-output*")))
     (unwind-protect
         (with-temp-buffer
           (insert "# Fixture\n\nhello\n")
           (unless (eq 0 (+markdown-compile-pandoc (point-min) (point-max) output)) (error "Pandoc failed"))
           (unless (with-current-buffer output (string-match-p "<h1" (buffer-string))) (error "HTML missing")))
       (kill-buffer output)))))

(doom-test-check "ZIP and 7z members extract through Emacs Archive mode"
 (lambda ()
   (require 'arc-mode)
   (doom-test-write "member.txt" "archive-content\n")
   (dolist (type '("zip" "7z"))
     (let ((archive (expand-file-name (concat "archive." type))))
       (doom-test-run "7za" "a" (concat "-t" type) archive "member.txt")
       (with-temp-buffer
         (if (equal type "zip") (archive-zip-extract archive "member.txt") (archive-7z-extract archive "member.txt"))
         (unless (equal (buffer-string) "archive-content\n") (error "%s member extraction failed" type)))))))

(doom-test-check "native tar archives open in Emacs Tar mode"
 (lambda ()
   (doom-test-run (expand-file-name "System32/tar.exe" (getenv "SystemRoot")) "-cf" "archive.tar" "member.txt")
   (let ((buffer (find-file-noselect "archive.tar")))
     (unwind-protect (with-current-buffer buffer
                      (unless (derived-mode-p 'tar-mode) (error "Not a Tar mode buffer")))
       (kill-buffer buffer)))))

(doom-test-check "Dired lists a Unicode directory"
 (lambda ()
   (require 'dired)
   (let ((buffer (dired-noselect doom-test-directory)))
     (unwind-protect (with-current-buffer buffer
                      (unless (string-match-p "search.txt" (buffer-string)) (error "Dired listing incomplete")))
       (kill-buffer buffer)))))

(require 'dired-aux)
(dolist (extension '("gz" "bz2" "xz" "zst"))
  (doom-test-check (concat "Dired compress/uncompress ." extension)
   (lambda ()
     (let* ((file (expand-file-name (concat "dired-" extension ".txt")))
            (dired-compress-file-default-suffix (concat "." extension)))
       (doom-test-write file "dired-content\n")
       (dired-compress-file file)
       (unless (file-exists-p (concat file "." extension)) (error "Dired did not compress"))
       (dired-compress-file (concat file "." extension))
       (unless (equal (doom-test-read file) "dired-content\n") (error "Dired content changed"))))))

(doom-test-check "Dired ZIP creation uses the bundled 7-Zip"
 (lambda ()
   (let ((archive (expand-file-name "dired-created.zip"))
         (files (list (expand-file-name "member.txt"))))
     (cl-letf (((symbol-function 'dired-get-marked-files) (lambda (&rest _) files))
               ((symbol-function 'read-file-name) (lambda (&rest _) archive))
               ((symbol-function 'dired-post-do-command) #'ignore))
       (dired-do-compress-to))
     (unless (file-exists-p archive) (error "Dired ZIP missing"))
     (with-temp-buffer (archive-zip-extract archive "member.txt")
                       (unless (equal (buffer-string) "archive-content\n") (error "Dired ZIP content changed"))))))

(doom-test-check "bundled Emacs Info manual opens"
 (lambda () (require 'info) (Info-find-node "emacs" "Top")))

(doom-test-check "Org exports HTML without an external TeX installation"
 (lambda ()
   (require 'ox-html)
   (with-temp-buffer
     (insert "* Fixture\nhello\n") (org-mode)
     (unless (string-match-p "hello" (org-export-as 'html nil nil t)) (error "Org export failed")))))

(let* ((packages (getenv "DOOM_TEST_PACKAGES"))
       (undo (and packages (expand-file-name "repos/undo-fu-session/undo-fu-session.el" packages))))
  (if (not (and undo (file-exists-p undo)))
      (princ "SKIP: persistent undo package check needs -PackageRoot of a synced Doom straight directory\n")
    (doom-test-check "actual undo-fu-session saves and recovers zstd history"
     (lambda ()
       (load undo nil t)
       (setq undo-fu-session-directory (expand-file-name "undo/" doom-test-directory)
             undo-fu-session-compression 'zst undo-fu-session-ignore-temp-files nil)
       (let ((file (expand-file-name "undo-example.txt" doom-test-directory)) buffer)
         (doom-test-write file "before\n")
         (setq buffer (find-file-noselect file))
         (with-current-buffer buffer
           (undo-fu-session-mode 1)
           (buffer-enable-undo) (undo-boundary) (goto-char (point-max)) (insert "after\n")
           (undo-boundary) (save-buffer) (undo-fu-session-save))
         (kill-buffer buffer)
         (unless (directory-files undo-fu-session-directory nil "\\.zst\\'") (error "No saved zstd history"))
         (setq buffer (find-file-noselect file))
         (unwind-protect
             (with-current-buffer buffer
               (undo-fu-session-mode 1)
               (undo-fu-session-recover)
               (unless (consp buffer-undo-list) (error "Undo history did not recover"))
               (undo-only 1)
               (unless (equal (buffer-string) "before\n") (error "Recovered undo did not restore previous content"))
               (set-buffer-modified-p nil))
           (kill-buffer buffer)))))))

(when doom-test-failures
  (error "%d default runtime checks failed: %s" (length doom-test-failures) (reverse doom-test-failures)))
(princ "PASS: default runtime operation checks complete\n")
