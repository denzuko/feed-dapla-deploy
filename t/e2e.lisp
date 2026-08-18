;;;; t/e2e.lisp -- feed-dapla-deploy/e2e

(defpackage :feed-dapla-deploy/e2e
  (:use :cl :fiveam)
  (:import-from :feed-dapla-deploy/deploy :*haproxy-fqdn*)
  (:export :run-e2e))

(in-package :feed-dapla-deploy/e2e)

(def-suite :feed-dapla-deploy-e2e
  :description "Smoke tests for feed.dapla.net.")

(in-suite :feed-dapla-deploy-e2e)

(test http-redirect
  "Plain HTTP requests redirect to HTTPS."
  (multiple-value-bind (body status)
      (dex:get (format nil "http://~A/" *haproxy-fqdn*)
               :force-string t :want-stream nil :redirect nil)
    (declare (ignore body))
    (is (member status '(301 302)))))

(test frontend-responds
  "The service frontend returns HTTP 200."
  (multiple-value-bind (body status)
      (dex:get (format nil "https://~A" *haproxy-fqdn*)
               :force-string t :want-stream nil)
    (declare (ignore body))
    (is (= 200 status))))

(defun run-e2e ()
  "Run the post-deploy e2e suite and signal an error if any test fails."
  (let ((results (run :feed-dapla-deploy-e2e)))
    (unless (every #'fiveam::test-passed-p results)
      (error "feed-dapla-deploy e2e suite: one or more tests failed."))))
