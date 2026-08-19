;;;; src/deploy.lisp -- feed-dapla-deploy/deploy core package
;;;;
;;;; Consfigurator properties and DEFHOST for GoToSocial ActivityPub server (feed.dapla.net pilot) at feed.dapla.net.
;;;; Generated from service.lisp via dapla-deploy-generator; do not edit
;;;; by hand. Regenerate via `dapla-deploy-generator generate .`.
;;;
;;; dapla.net netavark VLSM allocation (10.89.2.0/26):
;;;   find     podman3   10.89.2.0/30   gw 10.89.2.1   /30  1 container
;;;   watch    podman4   10.89.2.4/29   gw 10.89.2.5   /29  2 containers
;;;   meet     podman5   10.89.2.12/29  gw 10.89.2.13  /29  3 containers
;;;   feed     podman6   10.89.2.20/30  gw 10.89.2.21  /30  1 container
;;;   save     podman7   10.89.2.24/30  gw 10.89.2.25  /30  1 container
;;;   burn     podman8   10.89.2.28/30  gw 10.89.2.29  /30  1 container
;;;   link     podman9   10.89.2.32/30  gw 10.89.2.33  /30  1 container
;;;   support  podman10  10.89.2.36/29  gw 10.89.2.37  /29  4 containers
;;; Existing: podman1=10.89.0.0/24  podman2=10.89.1.0/24

(defpackage :feed-dapla-deploy/deploy
  (:use :cl)
  (:import-from :consfigurator
                :defprop :defhost :run :mrun :stripln
                :remote-exists-p :write-remote-file :on-change
                :inapplicable-property)
  (:import-from :consfigurator.property.file
                :has-content :containing-directory-exists)
  (:import-from :consfigurator.property.systemd :lingering-enabled)
  (:import-from :consfigurator.property.service :reloaded)
  (:export :*service-user* :*haproxy-fqdn*
           :deploy-app
           :zfs-encryption-key :zfs-dataset-mounted
           :rootless-service-account :images-pulled
           :cinix-write-string
           :gotosocial-network-sections
           :gotosocial-container-sections
           :quadlets-written :quadlets-activated
           :haproxy-vhost-config :haproxy-vhost-written
           :decommissioned))

(in-package :feed-dapla-deploy/deploy)

(defparameter *service-user* "gotosocial")
(defparameter *haproxy-fqdn* "feed.dapla.net")
(defparameter *haproxy-vhost-name* "feed")

(defparameter *users-gotosocial-dataset* "storage/users/gotosocial")
(defparameter *users-gotosocial-mountpoint* "/var/lib/gotosocial"
  "Service account home.")
(defparameter *users-gotosocial-dataset-keyfile* "/etc/zfs-keys/gotosocial-users.key")

(defparameter *containers-gotosocial-dataset* "storage/containers/gotosocial")
(defparameter *containers-gotosocial-mountpoint* "/srv/gotosocial"
  "GoToSocial database and media.")
(defparameter *containers-gotosocial-dataset-keyfile* "/etc/zfs-keys/gotosocial-data.key")

(defprop zfs-encryption-key :posix (path)
  "Generate a raw 32-byte ZFS encryption key at PATH via openssl rand -out,
   once, left alone on redeploy."
  (:desc (format nil "ZFS encryption key at ~A" path))
  (:check (remote-exists-p path))
  (:apply
   (containing-directory-exists path)
   (mrun "openssl" "rand" "-out" path "32")
   (mrun "chmod" "600" path)))

(defun zfs-create-command (dataset mountpoint keyfile)
  "The zfs create command for DATASET at MOUNTPOINT, AES-256-GCM encrypted via KEYFILE."
  (if keyfile
      (format nil
       "zfs create -o mountpoint=~A -o encryption=aes-256-gcm ~
        -o keyformat=raw -o keylocation=file://~A ~A"
       mountpoint keyfile dataset)
      (format nil "zfs create -o mountpoint=~A ~A" mountpoint dataset)))

(defprop zfs-dataset-mounted :posix (dataset mountpoint &optional keyfile)
  "Ensure DATASET exists and is mounted at MOUNTPOINT."
  (:desc (format nil "ZFS dataset ~A mounted at ~A~:[~; (encrypted)~]"
                  dataset mountpoint keyfile))
  (:check
   (multiple-value-bind (out err exit)
       (run :may-fail (format nil "zfs get -H -o value mounted ~A" dataset))
     (declare (ignore err))
     (and (zerop exit) (string= "yes" (stripln out)))))
  (:apply
   (if (zerop (mrun :for-exit (format nil "zfs list -H -o name ~A" dataset)))
       (progn (when keyfile (mrun (format nil "zfs load-key ~A" dataset)))
              (mrun (format nil "zfs mount ~A" dataset)))
       (mrun (zfs-create-command dataset mountpoint keyfile)))))

(defprop rootless-service-account :posix (username home)
  "Ensure system account USERNAME exists with home HOME, without creating the directory."
  (:desc (format nil "System account ~A at ~A" username home))
  (:check (zerop (mrun :for-exit "id" username)))
  (:apply (mrun "useradd" "--system" "--no-create-home" "--home-dir" home username)))

(defprop images-pulled :posix (user &rest images)
  "Pull IMAGES into USER's rootless Podman image store via machinectl shell."
  (:desc (format nil "Podman images pulled for ~A" user))
  (:check (every (lambda (i)
                   (zerop (mrun :for-exit
                           (format nil "machinectl shell ~A@ /usr/bin/podman image exists ~A"
                                   user i))))
                 images))
  (:apply (dolist (i images)
            (mrun (format nil "machinectl shell ~A@ /usr/bin/podman pull ~A" user i)))))

(defun cinix-write-string (sections)
  "Serialize an alist of (section-name . ((key . value) ...)) into INI unit-file text."
  (with-output-to-string (s)
    (dolist (section sections)
      (format s "[~A]~%" (car section))
      (dolist (kv (cdr section))
        (format s "~A=~A~%" (car kv) (cdr kv)))
      (format s "~%"))))

(defun gotosocial-network-sections ()
  "Cinix AST for feed.network: netavark bridge on podman6 (10.89.2.20/30)."
  '(("Network" . (("NetworkName" . "feed")
                   ("Driver"      . "bridge")
                   ("Subnet"      . "10.89.2.20/30")
                   ("Gateway"     . "10.89.2.21")))))

(defun gotosocial-container-sections ()
  "Cinix AST for feed.container. HAProxy backend: 10.89.2.21:8080."
  `(("Unit" . (("Description" . "GoToSocial ActivityPub server (feed.dapla.net pilot)")))
    ("Container" . (("Image"         . "oci.dapla.net/superseriousbusiness/gotosocial:latest")
                    ("ContainerName" . "gotosocial")
                    ("AutoUpdate"    . "registry")
                      ("Environment" . "GTS_HOST=feed.dapla.net")
                      ("Environment" . "GTS_PROTOCOL=https")
                      ("Environment" . "GTS_PORT=8080")
                      ("Environment" . "GTS_DB_TYPE=sqlite")
                      ("Environment" . "GTS_DB_SQLITE_ADDRESS=/gotosocial/storage/gotosocial.db")
                      ("Environment" . "GTS_STORAGE_BACKEND=local")
                      ("Environment" . "GTS_STORAGE_LOCAL_BASE_PATH=/gotosocial/storage/media")
                      ("Environment" . "GTS_LETSENCRYPT_ENABLED=false")
                    ("Volume" . "%h:/var/lib/gotosocial:ro")
                    ("Volume" . "/srv/%U:/gotosocial/storage:Z")
                    ("Network"       . "feed.network")
                    ("Label"         . "io.containers.autoupdate=registry")
                    ("Label"         . "org.cispec.application=feed-dapla-deploy")
                    ("Label"         . "org.cispec.managed-by=consfigurator")
                    ("Label"         . "org.cispec.fqdn=feed.dapla.net")
                    ("Label"         . "org.cispec.service-account=gotosocial")))
    ("Service" . (("Restart"         . "on-failure")
                  ("TimeoutStartSec" . "120")
                  ("TimeoutStopSec"  . "30")))
    ("Install" . (("WantedBy" . "default.target")))))

(defun haproxy-vhost-config ()
  "HAProxy vhost configuration for feed.dapla.net.
   Backend: 10.89.2.21:8080 (netavark bridge podman6, subnet 10.89.2.20/30)."
  (format nil
"frontend feed_http
  bind *:80
  acl host_feed hdr(host) -i feed.dapla.net
  redirect scheme https code 301 if host_feed

frontend feed_https
  bind *:443 ssl crt /etc/haproxy/certs/feed.dapla.net.pem alpn h2,http/1.1
  acl host_feed hdr(host) -i feed.dapla.net
  http-response set-header Strict-Transport-Security \"max-age=63072000; includeSubDomains; preload\"
  http-response set-header X-Content-Type-Options nosniff
  http-response set-header X-Frame-Options SAMEORIGIN
  http-response set-header Referrer-Policy strict-origin-when-cross-origin
  http-response set-header Permissions-Policy \"interest-cohort=()\"
  use_backend feed_be if host_feed

backend feed_be
  balance roundrobin
  option httpchk GET /healthz
  http-check expect status 200
  timeout connect 5s
  timeout server  60s
  server gotosocial 10.89.2.21:8080 check inter 10s rise 2 fall 3
"))

(defprop quadlets-written :posix (user home)
  "Write all feed quadlet unit files into USER's systemd container directory."
  (:desc (format nil "GoToSocial ActivityPub server (feed.dapla.net pilot) quadlet units written for ~A" user))
  (:apply
   (let ((quadlet-dir (format nil "~A/.config/containers/systemd" home)))
     (containing-directory-exists (format nil "~A/feed.network" quadlet-dir))
     (write-remote-file (format nil "~A/feed.network" quadlet-dir)
                        (cinix-write-string (gotosocial-network-sections)))
     (write-remote-file (format nil "~A/feed.container" quadlet-dir)
                        (cinix-write-string (gotosocial-container-sections))))))

(defprop quadlets-activated :posix (user)
  "Reload USER's user-scope systemd daemon and restart feed services."
  (:desc (format nil "Quadlets activated for ~A" user))
  (:apply
   (mrun (format nil "machinectl shell ~A@ /usr/bin/systemctl --user daemon-reload" user))
   (mrun (format nil "machinectl shell ~A@ /usr/bin/systemctl --user restart gotosocial" user))))

(defprop haproxy-vhost-written :posix ()
  "Write the HAProxy vhost config for feed.dapla.net. Reloads HAProxy when content changes."
  (:desc (format nil "HAProxy vhost written for ~A" *haproxy-fqdn*))
  (:check nil)
  (:apply
   (let* ((cfg-path (format nil "/etc/haproxy/conf.d/~A.cfg" *haproxy-vhost-name*))
          (new-content (haproxy-vhost-config))
          (current (when (probe-file cfg-path) (uiop:read-file-string cfg-path))))
     (unless (equal new-content current)
       (containing-directory-exists cfg-path)
       (write-remote-file cfg-path new-content)
       (reloaded "haproxy")))))

(defhost feed-host (:deploy (:local))
  "The GoToSocial ActivityPub server (feed.dapla.net pilot) host."
  (zfs-encryption-key *users-gotosocial-dataset-keyfile*)
  (zfs-encryption-key *containers-gotosocial-dataset-keyfile*)
  (zfs-dataset-mounted *users-gotosocial-dataset* *users-gotosocial-mountpoint* *users-gotosocial-dataset-keyfile*)
  (zfs-dataset-mounted *containers-gotosocial-dataset* *containers-gotosocial-mountpoint* *containers-gotosocial-dataset-keyfile*)
  (rootless-service-account *service-user* *users-gotosocial-mountpoint*)
  (lingering-enabled *service-user*)
  (images-pulled *service-user*
                 "oci.dapla.net/superseriousbusiness/gotosocial:latest")
  (quadlets-written *service-user* *users-gotosocial-mountpoint* *containers-gotosocial-mountpoint*)
  (quadlets-activated *service-user*)
  (haproxy-vhost-written))

(defprop decommissioned :posix (user)
  "Tear down the feed-dapla-deploy stack in least-destructive-first order.
   Steps: stop containers, remove HAProxy vhost, terminate session,
   disable linger, userdel, zfs destroy (irreversible), rm key files."
  (:desc (format nil "feed-dapla-deploy decommissioned for ~A" user))
  (:apply
   (mrun (format nil "machinectl shell ~A@ /usr/bin/systemctl --user stop --all" user))
   (mrun "rm" "-f" (format nil "/etc/haproxy/conf.d/~A.cfg" *haproxy-vhost-name*))
   (mrun "systemctl" "reload" "haproxy")
   (mrun "loginctl" "terminate-user" user)
   (mrun "loginctl" "disable-linger" user)
   (mrun "userdel" user)
   (mrun "zfs" "destroy" "-r" "storage/users/gotosocial")
   (mrun "zfs" "destroy" "-r" "storage/containers/gotosocial")
   (mrun "rm" "-f" "/etc/zfs-keys/gotosocial-users.key")
   (mrun "rm" "-f" "/etc/zfs-keys/gotosocial-data.key")))

(defun deploy-app ()
  "Provision GoToSocial ActivityPub server (feed.dapla.net pilot) via FEED-HOST (Consfigurator, :local connection).
   Aborts loudly if any property is skipped."
  (format t "~&--> Provisioning via Consfigurator (FEED-HOST)...~%")
  (let ((provisioning-failed nil))
    (handler-bind ((consfigurator::skipped-properties
                     (lambda (c) (declare (ignore c))
                       (setf provisioning-failed t))))
      (feed-host))
    (when provisioning-failed
      (error "FEED-HOST provisioning reported failed properties. Refusing to proceed.")))
  (format t "~&--> GoToSocial ActivityPub server (feed.dapla.net pilot) provisioned. Visit https://~A~%" *haproxy-fqdn*))
