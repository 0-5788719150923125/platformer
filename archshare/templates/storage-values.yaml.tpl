secretName: storage-secrets
imagePullSecrets:
  - name: ecr-credentials
flyway:
  enabled: true
  FLYWAY_OPTS: >-
    -DflywayOnly=true
    -Dspring.flyway.baselineOnMigrate=true
    -Dspring.flyway.baselineVersion=1
    -Djava.awt.headless=true
    -Dlog4j2.contextSelector=org.apache.logging.log4j.core.async.AsyncLoggerContextSelector
    -Dlogging.config=/etc/grid/config/log4j2.xml
    -XX:+UseG1GC
    -XX:-OmitStackTraceInFastThrow
pgbouncer:
  enabled: false
baseDeploymentProperties: |
  cache:
    type: redis
  redis:
    storage:
      host: ${redis_storage_endpoint}
      port: 6379
  server:
    compression:
      enabled: false
  services:
    url: http://services.${tenant_namespace}.svc.cluster.local:8020
  transcoding:
    cache: false
    cpp:
      enabled: false
    master:
      host: transcoding.${tenant_namespace}.svc.cluster.local
      port: 4000
  jobrunr:
    postgres:
      jdbc: $${STUDY_DATABASE_JDBC}
    dashboard:
      enabled: true
storageSystemDeploymentProperties: |
  s3:
    maxConnections: 1000
    maxAsyncConnections: 1000
    region: ${aws_region}
    bucket: $${S3_BUCKET}
  storage:
    download:
      optimize: true
    hybrid: true
    system:
      type: s3PureDicom
studyDatabaseDeploymentProperties: |
  study:
    database:
      type: postgresProtobuf
