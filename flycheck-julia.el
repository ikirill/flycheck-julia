;;; flycheck-julia.el --- TODO  DESCRIPTION -*- lexical-binding: t -*-
;;; Commentary:
;;
;; FIXME The first invocation is really slow, about 10 seconds
;;
;; FIXME What happens when, say, Lint.jl is missing? What does it do then?
;;
;; FIXME Move FlycheckJulia.el to a string variable, then write to a
;; temp file and include, so that one doesn't have to worry about
;; include paths and the like.
;;
;;; Code:

(require 'flycheck)
(require 'tq)
(require 's)

(defvar flycheck-julia--queue nil
  "A background Julia process for linting files.")
(defvar flycheck-julia--callbacks nil
  "Callbacks here should get called if the Julia process gets
killed otherwise than by us. That way, flycheck can be
informed.")
(defvar flycheck-julia--print-hello t
  "Because it takes so long to start up the first time, about 10
  seconds, we might want to print some kind of a message to be
  clear that it *is* actually starting.")
(defvar flycheck-julia--print-hello-next-time nil)
(defvar flycheck-julia--stderrbuf nil
  "The buffer for STDERR output of the julia server.")

(defvar flycheck-julia--source-tempfile nil)
(defvar flycheck-julia--source
  "module FlycheckJulia

using JSON
using Lint

# Matches flycheck-define-error-level in flycheck.el
const Severity = Dict('E' => \"error\", 'W' => \"warning\", 'I' => \"info\")

# See Lint/src/messages.jl, this replicates Base.show for LintMessage
# a little, so that we can encode to JSON directly. Base.show is
# designed for printing to stdout
#
# FIXME Can m.message have newlines? What then?
function lintMessage(m::LintMessage)
  Dict(\"file\" => m.file,
       \"severity\" => get(Severity, string(m.code)[1], \"error\"),
       \"code\" => m.code,
       \"line\" => m.line,
       \"message\" =>
       m.scope == \"\" ? @sprintf(\"%s: %s\", m.variable, m.message) : @sprintf(\"%s: %s: %s\", m.scope, m.variable, m.message)
       )
end

function main(fname::AbstractString, tmpfname::AbstractString)
  # FIXME Does this properly handle files that aren't correctly
  # FIXME enclosed in modules? Probably not?
  result = lintfile(fname, readstring(tmpfname))
  return JSON.json([lintMessage(m) for m in result.messages])
end

function main()
  while true
    request = JSON.parse(readline())
    response = main(request[\"file\"], request[\"tempfile\"])
    println(response)
  end
end

end
"
  "Source of the julia server.

Including the julia source directly in the elisp file allows this
checker to not require LOAD_PATH to be set appropriately, because
it will load the source from a temporary file.")

(defun flycheck-julia--ensure ()
  "Create `flycheck-julia--queue' if necessary."
  (unless flycheck-julia--queue
    (setq flycheck-julia--queue (flycheck-julia--create-queue)))
  ;; (message "flycheck-julia--queue: %S" flycheck-julia--queue)
  )

(defun flycheck-julia--source-tempfile-ensure ()
  (unless flycheck-julia--source-tempfile
    (setq flycheck-julia--source-tempfile (make-temp-file "flycheck-julia"))
    (message flycheck-julia--source-tempfile)
    (with-temp-buffer
      (insert flycheck-julia--source)
      (write-region nil nil flycheck-julia--source-tempfile)))
  flycheck-julia--source-tempfile)

(defun flycheck-julia--create-queue ()
  "Create a Julia background process and set up the queue."
  (cl-assert (not flycheck-julia--queue))
  (setq flycheck-julia--print-hello-next-time flycheck-julia--print-hello)
  ;; FIXME Hide the output buffers?
  ;; FIXME Use the correct /dev/null device?
  (tq-create
   (make-process
    :name "flycheck-julia"
    ;; :buffer "*julia*-stdout"
    :buffer nil
    :command `("julia" "--quiet" "--color=no" "--history-file=no" "--eval" "include(ARGS[1]); FlycheckJulia.main()" "--" ,(flycheck-julia--source-tempfile-ensure))
    ;; :stderr "*flycheck-julia-stderr*"
    :stderr (setq flycheck-julia--stderrbuf
                  (get-buffer-create " *flycheck-julia-stderr*"))
    :noquery nil ;; FIXME or is it t?
    :sentinel
    (lambda (_p msg)
      (let ((print-escape-newlines t))
        (message "flycheck-julia process has stopped: %S\n    See buffer %S" (s-trim msg) (buffer-name flycheck-julia--stderrbuf)))
      (flycheck-julia--kill)))))

(defun flycheck-julia--kill ()
  (when flycheck-julia--queue
    (tq-close flycheck-julia--queue)
    (setq flycheck-julia--queue nil)
    (mapc (lambda (callback) (funcall callback 'suspicious "flycheck-julia--kill"))
          flycheck-julia--callbacks)
    (setq flycheck-julia--callbacks nil)))

(defun flycheck-julia--request ()
  (let* ((file (car (flycheck-substitute-argument 'source-original 'julia)))
         (tempfile (car (flycheck-substitute-argument 'source 'julia)))
         (request
          (json-encode `((file . ,file) (tempfile . ,tempfile)))))
    (concat request "\n")))

(defun flycheck-julia--parse-response (response)
  ;; FlycheckJulia.jl for the format
  (mapcar
   (lambda (r)
     (flycheck-error-new-at
      (alist-get 'line r 0)
      nil
      (intern (alist-get 'severity r "error"))
      (alist-get 'message r "<no message>")
      :checker 'julia
      :id (alist-get 'code r)
      :filename (alist-get 'file r)
      :buffer (get-file-buffer (alist-get 'file r))))
   (json-read-from-string response)))

(flycheck-define-generic-checker 'julia
  "A Julia checker based on include() and Lint within a subprocess."
  :start
  (lambda (_checker callback)
    ;; (message "Start: %S %S" _checker callback)
    (flycheck-julia--ensure)
    (let ((callback-once
           (let (already)
             (lambda (status data)
               (unless already
                 (funcall callback status data)
                 (setq already t))))))
      (push callback-once flycheck-julia--callbacks)
      (unless flycheck-julia--queue (funcall callback-once 'errored nil))
      (when flycheck-julia--print-hello-next-time
        (message "Using flycheck-julia process, this may take some time."))
      (tq-enqueue
       flycheck-julia--queue
       (flycheck-julia--request)
       "\n" nil
       (lambda (_ response)
         (when flycheck-julia--print-hello-next-time
           (setq flycheck-julia--print-hello-next-time nil)
           (message "The flycheck-julia process is ready."))
         (setq flycheck-julia--callbacks (remq callback-once flycheck-julia--callbacks))
         (funcall callback-once 'finished (flycheck-julia--parse-response response))))
      callback-once))
  :interrupt
  (lambda (_checker callback)
    ;; (message "Interrupt: %S %S" checker callback)
    (setq flycheck-julia--callbacks (remq callback flycheck-julia--callbacks))
    (flycheck-julia--kill)
    (when callback (funcall callback 'interrupted nil)))
  :modes '(ess-julia-mode julia-mode))

;; (add-to-list 'flycheck-checkers 'julia)

(provide 'flycheck-julia)
;; Local Variables:
;; byte-compile-warnings: (not cl-functions)
;; End:
;;; flycheck-julia.el ends here
