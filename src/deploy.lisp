;;;; src/deploy.lisp -- feed-dapla-deploy/deploy core package
;;;;
;;;; Consfigurator properties and DEFHOST for GoToSocial at feed.dapla.net.
;;;;
;;;; This deploy is a client pilot and a live reference implementation for
;;;; the fediserve project. GoToSocial speaks the Mastodon-compatible
;;;; ActivityPub API subset; fediserve will replace it when production-ready.
;;;; Design decisions made here (ZFS layout, HAProxy config, quadlet shape,
;;;; secret handling) are intentionally forward-compatible with fediserve's
;;;; architecture so migration is a unit-file swap, not a rearchitecture.
;;;;
;;;; GoToSocial uses a single SQLite database file by default; this deploy
;;;; keeps it on the ZFS data dataset rather than a named volume so it is
;;;; covered by the same snapshot/replication policy as the media store.

(defpackage :feed-dapla-deploy/deploy
  (:use :cl)
  (:import-from :consfigurator
                :defprop :defhost :mrun :stripln
                :remote-exists-p :write-remote-file :on-change)
  (:import-from :consfigurator.property.file
                :has-content :containing-directory-exists)
  (:import-from :consfigurator.property.systemd :lingering-enabled)
  (:import-from :consfigurator.property.service :reloaded)
  (:export :*service-user* :*home-dataset* :*home-mountpoint*
           :*data-dataset* :*data-mountpoint*
           :*home-dataset-keyfile* :*data-dataset-keyfile*
           :*haproxy-fqdn*
           :deploy-app
           :zfs-encryption-key :zfs-dataset-mounted
           :rootless-service-account
           :images-pulled :quadlets-activated
           :cinix-write-string
           :service-account-uid
           :quadlets-written
           :haproxy-vhost-written
           :gotosocial-network-sections
           :gotosocial-container-sections
           :haproxy-vhost-config))

(in-package :feed-dapla-deploy/deploy)

(defparameter *service-user* "gotosocial"
  "Rootless system account the quadlet runs under.")
(defparameter *home-dataset* "storage/users/gotosocial")
(defparameter *home-mountpoint* "/var/lib/gotosocial")
(defparameter *home-dataset-keyfile* "/etc/zfs-keys/gotosocial-users.key")
(defparameter *data-dataset* "storage/containers/gotosocial")
(defparameter *data-mountpoint* "/srv/gotosocial"
  "GoToSocial data directory: SQLite database and media store.")
(defparameter *data-dataset-keyfile* "/etc/zfs-keys/gotosocial-data.key")
(defparameter *haproxy-fqdn* "feed.dapla.net")
(defparameter *haproxy-vhost-name* "feed")

(defprop zfs-encryption-key :posix (path)
  "Generate a raw 32-byte ZFS encryption key at PATH via `openssl rand`,
   once, left alone on redeploy."
  (:desc (format nil "ZFS encryption key at ~A" path))
  (:check (remote-exists-p path))
  (:apply
   (containing-directory-exists path)
   (let ((key (stripln (mrun "openssl" "rand" "-hex" "32"))))
     (write-remote-file path key :mode #o600))))

(defun zfs-create-command (dataset mountpoint keyfile)
  "The `zfs create` command for DATASET at MOUNTPOINT, AES-256-GCM
   encrypted when KEYFILE is supplied."
  (if keyfile
      (format nil "zfs create -o mountpoint=~A -o encryption=aes-256-gcm -o keyformat=raw -o keylocation=file://~A ~A"
              mountpoint keyfile dataset)
      (format nil "zfs create -o mountpoint=~A ~A" mountpoint dataset)))

(defprop zfs-dataset-mounted :posix (dataset mountpoint &optional keyfile)
  "Ensure DATASET exists, mounted at MOUNTPOINT, AES-256-GCM encrypted
   when KEYFILE is supplied."
  (:desc (format nil "ZFS dataset ~A mounted at ~A~:[~; (encrypted)~]"
                  dataset mountpoint keyfile))
  (:check
   (multiple-value-bind (out err exit)
       (consfigurator:run :may-fail
         (format nil "zfs get -H -o value mounted ~A" dataset))
     (declare (ignore err))
     (and (zerop exit) (string= "yes" (stripln out)))))
  (:apply
   (if (zerop (mrun :for-exit (format nil "zfs list -H -o name ~A" dataset)))
       (progn
         (when keyfile (mrun (format nil "zfs load-key ~A" dataset)))
         (mrun (format nil "zfs mount ~A" dataset)))
       (mrun (zfs-create-command dataset mountpoint keyfile)))))

(defprop rootless-service-account :posix (username home)
  "Ensure system account USERNAME exists with home HOME, without creating
   the directory (ZFS-backed, provisioned by ZFS-DATASET-MOUNTED)."
  (:desc (format nil "System account ~A at ~A" username home))
  (:check (zerop (mrun :for-exit "id" username)))
  (:apply (mrun "useradd" "--system" "--no-create-home"
                "--home-dir" home username)))

(defprop images-pulled :posix (user &rest images)
  "Pull IMAGES into USER's rootless Podman image store via `machinectl shell`."
  (:desc (format nil "Podman images pulled for ~A" user))
  (:check
   (every (lambda (image)
            (zerop (mrun :for-exit
                    (format nil "machinectl shell ~A@ -- podman image exists ~A"
                            user image))))
          images))
  (:apply
   (dolist (image images)
     (mrun (format nil "machinectl shell ~A@ -- podman pull ~A" user image)))))

(defun cinix-write-string (sections)
  "Serialize an alist of (section-name . ((key . value) ...)) into
   INI/systemd unit-file text."
  (with-output-to-string (s)
    (dolist (section sections)
      (format s "[~A]~%" (car section))
      (dolist (kv (cdr section))
        (format s "~A=~A~%" (car kv) (cdr kv)))
      (format s "~%"))))

(defun service-account-uid (username)
  "Read USERNAME's UID from the local passwd database via getent, at
   property apply time after ROOTLESS-SERVICE-ACCOUNT has run. The UID
   is used as the loopback PublishPort, per dapla.net convention."
  (parse-integer
   (third
    (uiop:split-string
     (string-trim '(#\Newline #\Space)
       (with-output-to-string (s)
         (uiop:run-program (list "getent" "passwd" username) :output s)))
     :separator '(#\:)))))

(defun gotosocial-network-sections ()
  "Cinix AST for gotosocial.network: internal-only network."
  '(("Network" . (("NetworkName" . "gotosocial")
                  ("Internal"    . "true")))))

(defun gotosocial-container-sections (data-mountpoint)
  "Cinix AST for gotosocial.container. The data mountpoint holds both the
   SQLite database and the media store, on a single ZFS dataset so snapshot
   and replication policy covers both together. The loopback port is the
   service account UID, per dapla.net convention.

   fediserve migration note: the GTS_HOST, GTS_PROTOCOL, and
   GTS_ACCOUNT_DOMAIN parameters map directly to fediserve's domain
   configuration; the data mountpoint layout (db + media) maps to
   fediserve's bknr.datastore path and cache.dapla.net media service
   respectively."
  (let ((port (service-account-uid *service-user*)))
    `(("Unit" . (("Description" . "GoToSocial ActivityPub server (feed.dapla.net pilot)")
                 ("After"       . "network-online.target")
                 ("Wants"       . "network-online.target")))
      ("Container" . (("Image"         . "oci.dapla.net/superseriousbusiness/gotosocial:latest")
                      ("ContainerName" . "gotosocial")
                      ("AutoUpdate"    . "registry")
                      ("PublishPort"   . ,(format nil "127.0.0.1:~A:8080" port))
                      ("Volume"        . ,(format nil "~A:/gotosocial/storage:Z"
                                                  data-mountpoint))
                      ("Environment"   . "GTS_HOST=feed.dapla.net")
                      ("Environment"   . "GTS_PROTOCOL=https")
                      ("Environment"   . "GTS_PORT=8080")
                      ("Environment"   . "GTS_DB_TYPE=sqlite")
                      ("Environment"   . ,(format nil "GTS_DB_SQLITE_ADDRESS=~A/gotosocial.db"
                                                  data-mountpoint))
                      ("Environment"   . "GTS_STORAGE_BACKEND=local")
                      ("Environment"   . ,(format nil "GTS_STORAGE_LOCAL_BASE_PATH=~A/media"
                                                  data-mountpoint))
                      ("Environment"   . "GTS_LETSENCRYPT_ENABLED=false")
                      ("Network"       . "gotosocial.network")
                      ("Label"         . "io.containers.autoupdate=registry")))
      ("Service" . (("Restart"         . "on-failure")
                    ("TimeoutStartSec" . "60")
                    ("TimeoutStopSec"  . "30")))
      ("Install" . (("WantedBy" . "default.target"))))))

(defun haproxy-vhost-config ()
  "HAProxy vhost text for feed.dapla.net. ActivityPub requires correct
   Content-Type handling for application/activity+json; the backend pass-
   through preserves the Accept header. Backend port is the service account
   UID, per dapla.net convention."
  (let ((port (service-account-uid *service-user*)))
    (format nil
"frontend ~A_http
  bind *:80
  acl host_~A hdr(host) -i ~A
  redirect scheme https code 301 if host_~A

frontend ~A_https
  bind *:443 ssl crt /etc/haproxy/certs/~A.pem alpn h2,http/1.1
  acl host_~A hdr(host) -i ~A
  http-response set-header Strict-Transport-Security \"max-age=63072000; includeSubDomains; preload\"
  http-response set-header X-Content-Type-Options nosniff
  http-response set-header X-Frame-Options SAMEORIGIN
  http-response set-header Referrer-Policy strict-origin-when-cross-origin
  http-response set-header Permissions-Policy \"interest-cohort=()\"
  use_backend ~A_be if host_~A

backend ~A_be
  balance roundrobin
  option httpchk GET /healthz
  http-check expect status 200
  timeout connect 5s
  timeout server  60s
  server gotosocial 127.0.0.1:~A check inter 10s rise 2 fall 3
"
            *haproxy-vhost-name* *haproxy-vhost-name* *haproxy-fqdn* *haproxy-vhost-name*
            *haproxy-vhost-name* *haproxy-fqdn*
            *haproxy-vhost-name* *haproxy-fqdn*
            *haproxy-vhost-name* *haproxy-vhost-name*
            *haproxy-vhost-name*
            port)))

(defprop quadlets-activated :posix (user)
  "Reload USER's user-scope systemd daemon and restart gotosocial."
  (:desc (format nil "Quadlets activated for ~A" user))
  (:apply
   (mrun (format nil "machinectl shell ~A@ -- systemctl --user daemon-reload" user))
   (mrun (format nil "machinectl shell ~A@ -- systemctl --user restart gotosocial"
                 user))))


(defprop quadlets-written :posix (user home data-mountpoint)
  "Write all gotosocial quadlet unit files into USER's systemd container
   directory. The service account UID is read at apply time via getent,
   after ROOTLESS-SERVICE-ACCOUNT has run, so PublishPort is always correct."
  (:desc (format nil "Gotosocial quadlet units written for ~A" user))
  (:apply
   (let ((quadlet-dir (format nil "~A/.config/containers/systemd" home)))
     (consfigurator.property.file:containing-directory-exists
      (format nil "~A/gotosocial.network" quadlet-dir))
     (write-remote-file
      (format nil "~A/gotosocial.network" quadlet-dir)
      (cinix-write-string (gotosocial-network-sections)))
     (write-remote-file
      (format nil "~A/gotosocial.container" quadlet-dir)
      (cinix-write-string (gotosocial-container-sections data-mountpoint))))))


(defprop haproxy-vhost-written :posix ()
  "Write the HAProxy vhost config for this service. Called after
   ROOTLESS-SERVICE-ACCOUNT has run so service-account-uid resolves
   correctly, then reloads HAProxy if the content changed."
  (:desc (format nil "HAProxy vhost written for ~A" *haproxy-fqdn*))
  (:apply
   (let* ((cfg-path (format nil "/etc/haproxy/conf.d/~A.cfg" *haproxy-vhost-name*))
          (new-content (haproxy-vhost-config))
          (current (when (probe-file cfg-path)
                     (uiop:read-file-string cfg-path))))
     (unless (equal new-content current)
       (write-remote-file cfg-path new-content)
       (consfigurator.property.service:reloaded "haproxy")))))

(defhost gotosocial-host (:deploy (:local))
  "The GoToSocial host: two AES-256-GCM ZFS datasets (home + data/media),
   rootless service account, linger, pulled image, one quadlet unit, and
   HAProxy vhost. Intentionally forward-compatible with fediserve migration."
  (zfs-encryption-key *home-dataset-keyfile*)
  (zfs-encryption-key *data-dataset-keyfile*)
  (zfs-dataset-mounted *home-dataset* *home-mountpoint* *home-dataset-keyfile*)
  (zfs-dataset-mounted *data-dataset* *data-mountpoint* *data-dataset-keyfile*)
  (rootless-service-account *service-user* *home-mountpoint*)
  (lingering-enabled *service-user*)
  (images-pulled *service-user*
                  "oci.dapla.net/superseriousbusiness/gotosocial:latest")
  (quadlets-written *service-user* *home-mountpoint* *data-mountpoint*)
  (quadlets-activated *service-user*)
  (haproxy-vhost-written))

(defun deploy-app ()
  "Provision the GoToSocial stack via GOTOSOCIAL-HOST (Consfigurator,
   :local connection). Aborts loudly if any property is skipped."
  (format t "~&--> Provisioning via Consfigurator (GOTOSOCIAL-HOST)...~%")
  (let ((provisioning-failed nil))
    (handler-bind ((consfigurator::skipped-properties
                     (lambda (c) (declare (ignore c))
                       (setf provisioning-failed t))))
      (gotosocial-host))
    (when provisioning-failed
      (error "GOTOSOCIAL-HOST provisioning reported failed properties ~
              (see the per-property report above). Refusing to proceed.")))
  (format t "~&--> GoToSocial provisioned. Visit https://~A~%" *haproxy-fqdn*))
