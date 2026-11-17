;;; runtime.el --- Native Windows bundle defaults -*- lexical-binding: t; -*-

;; Dired's stock ZIP creation command needs Info-ZIP, whereas the Windows
;; bundle uses standalone 7-Zip. Preserve explicitly customized commands.
(when (eq system-type 'windows-nt)
  (with-eval-after-load 'dired-aux
    (let ((rule (assoc "\\.zip\\'" dired-compress-files-alist)))
      (when (and (equal (cdr rule) "zip %o -r --filesync %i")
                 (executable-find "7z"))
        (setq dired-compress-files-alist (copy-tree dired-compress-files-alist))
        (setcdr (assoc "\\.zip\\'" dired-compress-files-alist) "7z a -tzip %o %i")))))

;;; runtime.el ends here
