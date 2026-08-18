(:repo-name    'feed-dapla-deploy'
 :system-name  'feed-dapla-deploy'
 :fqdn         'feed.dapla.net'
 :vhost-name   'feed'
 :service-user 'gotosocial'
 :description  'GoToSocial ActivityPub server (feed.dapla.net pilot)'
 :image        'oci.dapla.net/superseriousbusiness/gotosocial:latest'
 :internal-port 8080
 :health-path  '/healthz'
 :extra-envs ('GTS_HOST=feed.dapla.net'
               'GTS_PROTOCOL=https'
               'GTS_PORT=8080'
               'GTS_DB_TYPE=sqlite'
               'GTS_LETSENCRYPT_ENABLED=false')
 :datasets
 (  (:name 'users/gotosocial'
   :mountpoint '/var/lib/gotosocial'
   :purpose 'Service account home directory')
  (:name 'containers/gotosocial'
   :mountpoint '/srv/gotosocial'
   :purpose 'GoToSocial database and media store'))
)
