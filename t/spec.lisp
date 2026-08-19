;;;; t/spec.lisp -- feed-dapla-deploy/spec

(defpackage :feed-dapla-deploy/spec
  (:use :cl :fiveam)
  (:import-from :feed-dapla-deploy/deploy
                :gotosocial-network-sections
                :gotosocial-container-sections
                :haproxy-vhost-config
                :cinix-write-string)
  (:export :run-spec))

(in-package :feed-dapla-deploy/spec)

(def-suite :quadlet-specifiers
  :description "Quadlet specifier correctness for feed.dapla.net.")

(in-suite :quadlet-specifiers)

(defun network-ini () (cinix-write-string (gotosocial-network-sections)))
(defun container-ini () (cinix-write-string (gotosocial-container-sections)))

(defun ini-lines (ini)
  (remove-if (lambda (l) (zerop (length l)))
             (mapcar (lambda (l) (string-trim '(#\Space #\Return) l))
                     (uiop:split-string ini :separator '(#\Newline)))))

(defun ini-has (ini sub)
  (some (lambda (l) (search sub l)) (ini-lines ini)))

(test network-bridge
  "Network unit uses netavark bridge driver, not Internal=true."
  (is (ini-has (network-ini) "Driver=bridge"))
  (is (not (ini-has (network-ini) "Internal=true"))))

(test network-vlsm
  "Network unit has correct VLSM subnet 10.89.2.20/30 and gateway 10.89.2.21."
  (let ((ini (network-ini)))
    (is (ini-has ini "Subnet=10.89.2.20/30"))
    (is (ini-has ini "Gateway=10.89.2.21"))))

(test container-home-volume-ro
  "Home profile volume uses %h specifier, read-only."
  (let* ((ini   (container-ini))
         (lines (ini-lines ini))
         (vol   (find-if (lambda (l) (and (search "Volume=" l) (search "%h" l))) lines)))
    (is (not (null vol)))
    (when vol (is (search ":ro" vol)))))

(test container-data-volume-srv
  "Writable data volume uses /srv/%U specifier."
  (is (ini-has (container-ini) "Volume=/srv/%U")))

(test container-no-publish-port
  "No PublishPort — netavark bridge handles routing."
  (is (not (ini-has (container-ini) "PublishPort"))))

(test container-cispec-labels
  "org.cispec CMDB labels present."
  (let ((ini (container-ini)))
    (is (ini-has ini "Label=org.cispec.managed-by=consfigurator"))))

(test haproxy-netavark-gateway
  "HAProxy backend uses netavark gateway 10.89.2.21:8080, not loopback."
  (let ((cfg (haproxy-vhost-config)))
    (is (search "10.89.2.21:8080" cfg))
    (is (not (search "127.0.0.1" cfg)))))

(defun run-spec ()
  (let ((results (run :quadlet-specifiers)))
    (fiveam:explain! results)
    (unless (every #'fiveam::test-passed-p results)
      (error "feed-dapla-deploy spec suite: tests failed."))))
