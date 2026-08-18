;;;; src/docs.lisp -- feed-dapla-deploy/docs

(defpackage :feed-dapla-deploy/docs
  (:use :cl)
  (:import-from :40ants-doc :defsection))

(in-package :feed-dapla-deploy/docs)

(defsection @feed-dapla-deploy (:title "feed-dapla-deploy")
  "Roswell/Consfigurator deploy for feed.dapla.net."
  (@deploy-properties section))

(defsection @deploy-properties (:title "Consfigurator Properties")
  (feed-dapla-deploy/deploy:deploy-app function))
