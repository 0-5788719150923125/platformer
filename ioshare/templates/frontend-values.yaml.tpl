imagePullSecrets:
  - name: ecr-credentials
service:
  type: LoadBalancer
nginxConfig: |
  events {
    worker_connections 50000;
  }
  http {
    include mime.types;
    default_type application/octet-stream;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_requests 5;
    keepalive_timeout 15;
    types_hash_max_size 2048;
    variables_hash_max_size 1024;
    absolute_redirect off;

    proxy_cache_bypass 1;
    proxy_no_cache 1;
    proxy_buffering off;
    proxy_request_buffering off;

    proxy_connect_timeout 300s;
    proxy_send_timeout 300s;
    proxy_read_timeout 300s;
    send_timeout 300s;

    access_log /dev/stdout;
    error_log /dev/stderr info;

    gzip on;
    gzip_static on;
    gzip_http_version 1.0;
    gzip_comp_level 5;
    gzip_proxied any;
    gzip_types text/plain text/css application/x-javascript text/xml application/xml application/xml+rss text/javascript application/json application/dicom;

    server {
      listen 80;
      http2 on;
      root /usr/local/openresty/nginx/html;

      charset utf-8;

      resolver local=on ipv6=off;
      set $services_endpoint http://services.${tenant_namespace}.svc.cluster.local:8020;
      set $websocket_endpoint http://services.${tenant_namespace}.svc.cluster.local:8021;
      set $storage_endpoint http://storage.${tenant_namespace}.svc.cluster.local:10080;

      # Main location - handles SSI for HTML files
      location / {
        allow all;
        autoindex off;
        ssi on;
        ssi_silent_errors off;
        add_header X-UA-Compatible chrome=1;
        add_header X-DicomGrid-HostName $hostname;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header Referrer-Policy "strict-origin-when-cross-origin";

        # URL rewrites for share links and shortcuts
        rewrite ^/share/(.*)$ /share.html?share_code=$1;
        rewrite ^/link/(.*)$ /link.html?uuid=$1;
        rewrite ^/l/(.*)$ /link.html?type=pal&id=$1 redirect;
        rewrite ^/progress/(.*)$ /progress.html?uuid=$1;
        rewrite ^/locker$ /share.html?locker=1;
        rewrite ^/login.html$ /;

        if ($request_filename ~* ^.+.html$) {
          break;
        }

        # Add .html to URI if file exists
        if (-e $request_filename.html) {
          rewrite ^/(.*)$ /$1.html last;
          break;
        }

        if ($request_filename ~* \.(?:ico|css|js|gif|jpe?g|png)$) {
          add_header Cache-Control max-age=3600,must-revalidate;
        }
        if ($request_filename ~* \.(?:woff|woff2|eot|otf|ttf)$) {
          add_header Cache-Control max-age=3600,must-revalidate;
        }
      }

      # Static resources with cache control
      location /static/resources {
        autoindex off;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header Referrer-Policy "strict-origin-when-cross-origin";
        add_header Cache-Control "max-age=3600,must-revalidate";

        if ($request_filename ~ \.\d+\.) {
          add_header Cache-Control "max-age=2592000";
          expires 30d;
        }
      }

      # Viewer location
      location /viewer {
        set $no_cache 1;
        allow all;
        autoindex off;
        add_header X-UA-Compatible chrome=1;
        add_header X-DicomGrid-HostName $hostname;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header Referrer-Policy "strict-origin-when-cross-origin";
        alias /usr/local/openresty/nginx/html/webviewer;
        ssi on;
        ssi_silent_errors off;
        ssi_types application/json;

        if ($request_filename ~* \.(?:woff|woff2|eot|otf|ttf|cur)$) {
          add_header Cache-Control max-age=3600,must-revalidate;
          set $no_cache '';
        }
        if ($request_uri ~ ^/viewer(/settings)?/resources/.+\.\d+\..+$) {
          expires 30d;
          set $no_cache '';
        }
        if ($no_cache) {
          add_header Pragma "no-cache";
          expires 0;
          add_header Cache-Control no-cache,must-revalidate,max_age=0,no-store;
        }
      }

      # ProViewer location
      location /proviewer {
        allow all;
        autoindex on;
        add_header X-UA-Compatible chrome=1;
        add_header X-DicomGrid-HostName $hostname;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        add_header Referrer-Policy "strict-origin-when-cross-origin";
        alias /usr/local/openresty/nginx/html/web-viewer;
        ssi on;
        ssi_silent_errors off;
        ssi_types application/json;

        if ($request_filename ~* \.(?:woff|woff2|eot|otf|ttf|cur|css|js)$) {
          add_header Cache-Control max-age=31536000,must-revalidate;
          set $no_cache '';
        }
        if ($no_cache) {
          add_header Pragma "no-cache";
          expires 0;
          add_header Cache-Control no-cache,must-revalidate,max_age=0,no-store;
        }
      }

      # API v3 proxy to services
      location /api/v3/ {
        rewrite ^/api/v3/(.*) /$1 break;
        add_header X-DicomGrid-HostName $hostname;
        add_header Access-Control-Allow-Origin "*";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header Referrer-Policy "strict-origin-when-cross-origin";
        proxy_buffering on;
        proxy_request_buffering on;
        proxy_set_header X-Forwarded-For $http_x_forwarded_for;
        proxy_set_header Host $host;
        proxy_set_header Referer $http_referer;
        proxy_pass $services_endpoint;
        proxy_redirect $services_endpoint/ http://$host/;
        allow all;
        client_max_body_size 1024m;
      }

      # WebSocket support
      location /api/v3/channel/websocket {
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection upgrade;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_pass $websocket_endpoint/channel/websocket;
        allow all;
      }

      # Storage API proxy
      location /api/v3/storage/storage_api.html {
        rewrite ^/api/v3/storage/(.*) /api/v2/$1 break;
        proxy_pass $storage_endpoint;
        proxy_redirect $storage_endpoint http://$host/;
        proxy_set_header X-Forwarded-For $remote_addr;
      }

      # Health check endpoint
      location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
      }
    }
  }
