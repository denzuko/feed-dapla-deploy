;;;; src/docs.lisp -- feed-dapla-deploy/docs

(defpackage :feed-dapla-deploy/docs
  (:use :cl)
  (:import-from :40ants-doc :defsection))

(in-package :feed-dapla-deploy/docs)

(defsection @feed-dapla-deploy (:title "feed-dapla-deploy")
  "Roswell/Consfigurator deploy for feed.dapla.net."
  (@deploy-properties section))


(defsection @network-allocation (:title "Network Allocation")
  "The feed.dapla.net service runs on netavark bridge network
   podman6 (10.89.2.20/30), gateway 10.89.2.21.

   Full dapla.net VLSM allocation (10.89.2.0/26):

   | Service | Network  | Subnet         | Gateway     | /  | Containers |
   |---------|----------|----------------|-------------|-----|-----------|
   | find    | podman3  | 10.89.2.0/30   | 10.89.2.1   | 30 | 1         |
   | watch   | podman4  | 10.89.2.4/29   | 10.89.2.5   | 29 | 2         |
   | meet    | podman5  | 10.89.2.12/29  | 10.89.2.13  | 29 | 3         |
   | feed    | podman6  | 10.89.2.20/30  | 10.89.2.21  | 30 | 1         |
   | save    | podman7  | 10.89.2.24/30  | 10.89.2.25  | 30 | 1         |
   | burn    | podman8  | 10.89.2.28/30  | 10.89.2.29  | 30 | 1         |
   | link    | podman9  | 10.89.2.32/30  | 10.89.2.33  | 30 | 1         |
   | support | podman10 | 10.89.2.36/29  | 10.89.2.37  | 29 | 4         |

   Existing host networks: podman1=10.89.0.0/24, podman2=10.89.1.0/24.
   HAProxy backend -> gateway IP:internal port. No loopback, no port arithmetic.")

(defsection @deploy-properties (:title "Consfigurator Properties")
  (feed-dapla-deploy/deploy:deploy-app function))
