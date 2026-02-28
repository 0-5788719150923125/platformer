# Observability Module
# Manages LGTM stack (Loki, Grafana, Tempo, Mimir) infrastructure
# Emits requests via dependency inversion: compute_class_requests, bucket_requests,
# helm_application_requests, alloy_application_requests
#
# Strategy:
# 1. Parse config for enabled components (loki, grafana, tempo, mimir)
# 2. Emit an EKS compute class request (merged into effective_compute_config by root)
# 3. Emit S3 bucket requests for Loki chunk/ruler storage
# 4. Grant Loki S3 access via EKS Pod Identity
# 5. Emit Helm application requests for Loki + Grafana
# 6. Emit Alloy (Ansible) application requests for EC2 log collection agents

locals {
  # ── Config Parsing ──────────────────────────────────────────────────────
  components = lookup(var.config, "components", {})
  agent      = lookup(var.config, "agent", {})
  compute    = lookup(var.config, "compute", {})

  # Component enable flags
  loki_enabled    = lookup(local.components, "loki", null) != null
  grafana_enabled = try(local.components.grafana.enabled, false)
  tempo_enabled   = try(local.components.tempo.enabled, false)
  mimir_enabled   = try(local.components.mimir.enabled, false)

  # Loki settings
  loki_mode           = try(local.components.loki.mode, "SimpleScalable")
  loki_retention_days = try(local.components.loki.retention_days, 30)

  # Agent settings
  agent_log_paths      = try(local.agent.log_paths, ["/var/log/messages", "/var/log/secure"])
  agent_targeting      = lookup(local.agent, "targeting", {})
  agent_targeting_mode = lookup(local.agent_targeting, "mode", "managed")

  # EKS cluster class name for the observability stack
  obs_cluster_name = "observability"

  # Mimir settings
  mimir_mode               = try(local.components.mimir.mode, "SingleBinary")
  mimir_retention_days     = try(local.components.mimir.retention_days, 30)
  mimir_blocks_bucket_name = "mimir-blocks-${var.namespace}"
  mimir_blocks_bucket_arn  = "arn:aws:s3:::${local.mimir_blocks_bucket_name}"

  # Tempo settings
  tempo_retention_days     = try(local.components.tempo.retention_days, 30)
  tempo_traces_bucket_name = "tempo-traces-${var.namespace}"
  tempo_traces_bucket_arn  = "arn:aws:s3:::${local.tempo_traces_bucket_name}"

  # Static NodePorts for Terraform-managed NLBs (must be in 30000-32767 range)
  loki_gateway_node_port = 30080
  grafana_node_port      = 30081
  mimir_node_port        = 30082

  # ── NLB Requests ─────────────────────────────────────────────────────
  # Emitted to compute module for Terraform-managed load balancers
  lb_requests = concat(
    local.loki_enabled ? [{
      name              = "loki-gateway"
      cluster_class     = local.obs_cluster_name
      port              = 80
      node_port         = local.loki_gateway_node_port
      protocol          = "TCP"
      health_check_path = "/ready"
      internal          = false
    }] : [],
    local.grafana_enabled ? [{
      name              = "grafana"
      cluster_class     = local.obs_cluster_name
      port              = 80
      node_port         = local.grafana_node_port
      protocol          = "TCP"
      health_check_path = "/api/health"
      internal          = false
    }] : [],
    local.mimir_enabled ? [{
      name              = "mimir"
      cluster_class     = local.obs_cluster_name
      port              = 80
      node_port         = local.mimir_node_port
      protocol          = "TCP"
      health_check_path = "/ready"
      internal          = true
    }] : []
  )

  # ── EKS Compute Class Request ──────────────────────────────────────────
  # Emitted into effective_compute_config via root main.tf merge
  compute_class_requests = local.compute != null && length(keys(local.compute)) > 0 ? {
    (local.obs_cluster_name) = local.compute
  } : {}

  # ── S3 Bucket Requests ─────────────────────────────────────────────────
  bucket_requests = concat(
    local.loki_enabled ? [
      {
        purpose            = "loki-chunks"
        description        = "Loki log chunk storage for observability stack"
        versioning_enabled = false
        lifecycle_days     = local.loki_retention_days
        force_destroy      = true
      },
      {
        purpose            = "loki-ruler"
        description        = "Loki ruler storage for recording/alerting rules"
        versioning_enabled = false
        lifecycle_days     = 90
        force_destroy      = true
      }
    ] : [],
    local.mimir_enabled ? [
      {
        purpose            = "mimir-blocks"
        description        = "Mimir TSDB block storage for metrics"
        versioning_enabled = false
        lifecycle_days     = local.mimir_retention_days
        force_destroy      = true
      }
    ] : [],
    local.tempo_enabled ? [
      {
        purpose            = "tempo-traces"
        description        = "Tempo trace storage for distributed tracing"
        versioning_enabled = false
        lifecycle_days     = local.tempo_retention_days
        force_destroy      = true
      }
    ] : []
  )

  # ── Deterministic Bucket Names ────────────────────────────────────────
  # Storage module names buckets as "${purpose}-${namespace}"
  # Construct names deterministically to avoid circular dependency with storage module
  loki_chunks_bucket_name = "loki-chunks-${var.namespace}"
  loki_ruler_bucket_name  = "loki-ruler-${var.namespace}"
  loki_chunks_bucket_arn  = "arn:aws:s3:::${local.loki_chunks_bucket_name}"
  loki_ruler_bucket_arn   = "arn:aws:s3:::${local.loki_ruler_bucket_name}"

  # Whether the observability EKS cluster is defined in config (plan-time safe)
  eks_defined = try(local.compute.type, "") == "eks"

  # ── Helm Application Requests ──────────────────────────────────────────
  loki_helm_request = local.loki_enabled ? [{
    class        = local.obs_cluster_name
    tenant       = null
    type         = "helm"
    chart        = "loki"
    repository   = "https://grafana.github.io/helm-charts"
    version      = "6.53.0"
    namespace    = "observability"
    release_name = "loki"
    wait         = true
    timeout      = 600
    values = yamlencode({
      deploymentMode = local.loki_mode == "SimpleScalable" ? "SimpleScalable" : (
        local.loki_mode == "SingleBinary" ? "SingleBinary" : "Distributed"
      )
      loki = {
        auth_enabled = false
        # SingleBinary with 1 replica needs replication_factor=1 to accept writes
        commonConfig = {
          replication_factor = local.loki_mode == "SingleBinary" ? 1 : 3
        }
        storage = {
          type = "s3"
          bucketNames = {
            chunks = local.loki_chunks_bucket_name
            ruler  = local.loki_ruler_bucket_name
          }
          s3 = {
            region = var.aws_region
          }
        }
        schemaConfig = {
          configs = [{
            from         = "2024-01-01"
            store        = "tsdb"
            object_store = "s3"
            schema       = "v13"
            index = {
              prefix = "index_"
              period = "24h"
            }
          }]
        }
      }
      # S3 access is granted via EKS Pod Identity (bound to loki service account)

      # Expose Loki gateway as NodePort  -  Terraform-managed NLB handles external access
      gateway = {
        service = {
          type     = "NodePort"
          nodePort = local.loki_gateway_node_port
        }
      }

      # Disable optional caches -- not needed for SingleBinary or small-scale testing
      chunksCache = {
        enabled = false
      }
      resultsCache = {
        enabled = false
      }

      # SingleBinary: run everything in one pod
      singleBinary = {
        replicas = local.loki_mode == "SingleBinary" ? 1 : 0
        persistence = {
          enabled      = true
          storageClass = "gp2"
          size         = "1Gi"
        }
      }

      # SimpleScalable components
      read = {
        replicas = local.loki_mode == "SingleBinary" ? 0 : 3
      }
      write = {
        replicas = local.loki_mode == "SingleBinary" ? 0 : 3
        persistence = {
          enabled      = true
          storageClass = "gp2"
          size         = "1Gi"
        }
      }
      backend = {
        replicas = local.loki_mode == "SingleBinary" ? 0 : 3
        persistence = {
          enabled      = true
          storageClass = "gp2"
          size         = "1Gi"
        }
      }
    })

    # Unused fields (required by application_requests interface)
    script           = null
    params           = null
    target_tag_key   = null
    target_tag_value = null
    targeting_mode   = "compute"
    targets          = null
    playbook         = null
    playbook_file    = null
  }] : []

  # ── Mimir Helm Request ────────────────────────────────────────────────
  mimir_helm_request = local.mimir_enabled ? [{
    class        = local.obs_cluster_name
    tenant       = null
    type         = "helm"
    chart        = "mimir-distributed"
    repository   = "https://grafana.github.io/helm-charts"
    version      = "6.0.5"
    namespace    = "observability"
    release_name = "mimir"
    wait         = true
    timeout      = 600
    values = yamlencode({
      mimir = {
        structuredConfig = {
          common = {
            storage = {
              backend = "s3"
              s3 = {
                region      = var.aws_region
                bucket_name = local.mimir_blocks_bucket_name
                endpoint    = "s3.dualstack.${var.aws_region}.amazonaws.com"
              }
            }
          }
          blocks_storage = {
            storage_prefix = "blocks"
            s3 = {
              bucket_name = local.mimir_blocks_bucket_name
            }
          }
          limits = {
            compactor_blocks_retention_period = "${local.mimir_retention_days * 24}h"
          }
          # Disable Kafka-based ingest (use classic push path)
          ingest_storage = {
            enabled = false
          }
          ingester = {
            push_grpc_method_enabled = true
          }
        }
      }
      # Disable optional sub-charts and caches
      minio          = { enabled = false }
      kafka          = { enabled = false }
      chunks-cache   = { enabled = false }
      index-cache    = { enabled = false }
      metadata-cache = { enabled = false }
      results-cache  = { enabled = false }
      # Disable components not needed for small-scale deployment
      alertmanager       = { enabled = false }
      overrides_exporter = { enabled = false }
      ruler              = { enabled = false }
      # Set gp2 storage class on all stateful components
      ingester = {
        persistentVolume = {
          enabled      = true
          storageClass = "gp2"
          size         = "1Gi"
        }
      }
      store_gateway = {
        persistentVolume = {
          enabled      = true
          storageClass = "gp2"
          size         = "1Gi"
        }
      }
      compactor = {
        persistentVolume = {
          enabled      = true
          storageClass = "gp2"
          size         = "1Gi"
        }
      }
      # Expose gateway as NodePort for cross-cluster access
      gateway = {
        service = {
          type     = "NodePort"
          nodePort = local.mimir_node_port
        }
      }
    })

    # Unused fields (required by application_requests interface)
    script           = null
    params           = null
    target_tag_key   = null
    target_tag_value = null
    targeting_mode   = "compute"
    targets          = null
    playbook         = null
    playbook_file    = null
  }] : []

  # ── Tempo Helm Request ───────────────────────────────────────────────
  tempo_helm_request = local.tempo_enabled ? [{
    class        = local.obs_cluster_name
    tenant       = null
    type         = "helm"
    chart        = "tempo"
    repository   = "https://grafana-community.github.io/helm-charts"
    version      = "1.26.4"
    namespace    = "observability"
    release_name = "tempo"
    wait         = true
    timeout      = 300
    values = yamlencode({
      tempo = {
        retention = "${local.tempo_retention_days * 24}h"
        metricsGenerator = {
          enabled        = true
          remoteWriteUrl = "http://mimir-gateway.observability.svc.cluster.local:80/api/v1/push"
        }
        storage = {
          trace = {
            backend = "s3"
            s3 = {
              bucket   = local.tempo_traces_bucket_name
              endpoint = "s3.dualstack.${var.aws_region}.amazonaws.com"
              insecure = false
            }
            wal = {
              path = "/var/tempo/wal"
            }
          }
        }
      }
      persistence = {
        enabled          = true
        storageClassName = "gp2"
        size             = "1Gi"
      }
    })

    # Unused fields (required by application_requests interface)
    script           = null
    params           = null
    target_tag_key   = null
    target_tag_value = null
    targeting_mode   = "compute"
    targets          = null
    playbook         = null
    playbook_file    = null
  }] : []

  # ── kube-state-metrics + node-exporter Helm Requests ─────────────────
  # Auto-enabled when mimir is enabled (metrics pipeline needs exporters)
  kube_state_metrics_helm_request = local.mimir_enabled ? [{
    class        = local.obs_cluster_name
    tenant       = null
    type         = "helm"
    chart        = "kube-state-metrics"
    repository   = "https://prometheus-community.github.io/helm-charts"
    version      = "7.1.0"
    namespace    = "observability"
    release_name = "kube-state-metrics"
    wait         = true
    timeout      = 300
    values       = yamlencode({})

    # Unused fields (required by application_requests interface)
    script           = null
    params           = null
    target_tag_key   = null
    target_tag_value = null
    targeting_mode   = "compute"
    targets          = null
    playbook         = null
    playbook_file    = null
  }] : []

  prometheus_node_exporter_helm_request = local.mimir_enabled ? [{
    class        = local.obs_cluster_name
    tenant       = null
    type         = "helm"
    chart        = "prometheus-node-exporter"
    repository   = "https://prometheus-community.github.io/helm-charts"
    version      = "4.51.1"
    namespace    = "observability"
    release_name = "prometheus-node-exporter"
    wait         = true
    timeout      = 300
    values       = yamlencode({})

    # Unused fields (required by application_requests interface)
    script           = null
    params           = null
    target_tag_key   = null
    target_tag_value = null
    targeting_mode   = "compute"
    targets          = null
    playbook         = null
    playbook_file    = null
  }] : []

  # Helm templates for non-observability cluster fan-out
  kube_state_metrics_helm_template = local.mimir_enabled ? {
    tenant       = null
    type         = "helm"
    chart        = "kube-state-metrics"
    repository   = "https://prometheus-community.github.io/helm-charts"
    version      = "7.1.0"
    namespace    = "observability"
    release_name = "kube-state-metrics"
    wait         = true
    timeout      = 300
    values       = yamlencode({})

    # Unused fields (required by application_requests interface)
    script           = null
    params           = null
    target_tag_key   = null
    target_tag_value = null
    targeting_mode   = "compute"
    targets          = null
    playbook         = null
    playbook_file    = null
  } : null

  prometheus_node_exporter_helm_template = local.mimir_enabled ? {
    tenant       = null
    type         = "helm"
    chart        = "prometheus-node-exporter"
    repository   = "https://prometheus-community.github.io/helm-charts"
    version      = "4.51.1"
    namespace    = "observability"
    release_name = "prometheus-node-exporter"
    wait         = true
    timeout      = 300
    values       = yamlencode({})

    # Unused fields (required by application_requests interface)
    script           = null
    params           = null
    target_tag_key   = null
    target_tag_value = null
    targeting_mode   = "compute"
    targets          = null
    playbook         = null
    playbook_file    = null
  } : null

  # ── Dashboard Provisioning ─────────────────────────────────────────────
  # Auto-discover all .json dashboard files for Grafana provisioning
  dashboard_files = local.grafana_enabled ? {
    for f in fileset("${path.module}/dashboards", "*.json") :
    trimsuffix(f, ".json") => file("${path.module}/dashboards/${f}")
  } : {}

  grafana_helm_request = local.grafana_enabled ? [{
    class        = local.obs_cluster_name
    tenant       = null
    type         = "helm"
    chart        = "grafana"
    repository   = "https://grafana-community.github.io/helm-charts"
    version      = "11.1.7"
    namespace    = "observability"
    release_name = "grafana"
    wait         = true
    timeout      = 300
    values = yamlencode({
      "grafana.ini" = {
        "auth.anonymous" = {
          enabled  = true
          org_role = "Admin"
        }
        auth = {
          disable_login_form = true
        }
      }
      datasources = {
        "datasources.yaml" = {
          apiVersion = 1
          datasources = concat(
            [{
              name      = "Loki"
              type      = "loki"
              uid       = "loki"
              url       = "http://loki-gateway.observability.svc.cluster.local"
              access    = "proxy"
              isDefault = true
            }],
            local.mimir_enabled ? [{
              name      = "Mimir"
              type      = "prometheus"
              uid       = "mimir"
              url       = "http://mimir-gateway.observability.svc.cluster.local:80/prometheus"
              access    = "proxy"
              isDefault = false
            }] : [],
            local.tempo_enabled ? [{
              name      = "Tempo"
              type      = "tempo"
              uid       = "tempo"
              url       = "http://tempo.observability.svc.cluster.local:3200"
              access    = "proxy"
              isDefault = false
              jsonData = {
                tracesToLogsV2 = {
                  datasourceUid = "loki"
                }
              }
            }] : []
          )
        }
      }
      dashboardProviders = {
        "dashboardproviders.yaml" = {
          apiVersion = 1
          providers = [{
            name            = "default"
            orgId           = 1
            folder          = "Observability"
            type            = "file"
            disableDeletion = false
            editable        = true
            options = {
              path = "/var/lib/grafana/dashboards/default"
            }
          }]
        }
      }
      dashboards = {
        default = {
          for name, json in local.dashboard_files : name => {
            json = json
          }
        }
      }
      service = {
        type     = "NodePort"
        nodePort = local.grafana_node_port
      }
    })

    # Unused fields
    script           = null
    params           = null
    target_tag_key   = null
    target_tag_value = null
    targeting_mode   = "compute"
    targets          = null
    playbook         = null
    playbook_file    = null
  }] : []

  # ── Alloy Kubernetes DaemonSet (Helm) ─────────────────────────────────
  # River config for Alloy running as a K8s DaemonSet  -  discovers pods via
  # the Kubernetes API, tails container logs, and forwards to Loki.
  # Placeholders LOKI_PUSH_ENDPOINT, MIMIR_REMOTE_WRITE_ENDPOINT, and CLUSTER_NAME
  # are replaced at plan time.

  alloy_k8s_logs_config = <<-RIVER
    // ── Pod Discovery ──────────────────────────────────────────────────
    discovery.kubernetes "pods" {
      role = "pod"
    }

    discovery.relabel "pods" {
      targets = discovery.kubernetes.pods.targets

      rule {
        source_labels = ["__meta_kubernetes_pod_phase"]
        regex         = "Pending|Succeeded|Failed|Completed"
        action        = "drop"
      }
      rule {
        source_labels = ["__meta_kubernetes_namespace"]
        target_label  = "namespace"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_name"]
        target_label  = "pod"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_container_name"]
        target_label  = "container"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_node_name"]
        target_label  = "node"
      }
    }

    // ── Log Collection ─────────────────────────────────────────────────
    loki.source.kubernetes "pods" {
      targets    = discovery.relabel.pods.output
      forward_to = [loki.write.default.receiver]
    }

    // ── Log Shipping ───────────────────────────────────────────────────
    loki.write "default" {
      endpoint {
        url = "LOKI_PUSH_ENDPOINT"
      }
      external_labels = {
        cluster = "CLUSTER_NAME",
      }
    }
  RIVER

  alloy_k8s_metrics_config = <<-RIVER
    // ── Kubelet / cAdvisor Metrics ─────────────────────────────────────
    discovery.kubernetes "nodes" {
      role = "node"
    }

    discovery.relabel "kubelet" {
      targets = discovery.kubernetes.nodes.targets

      rule {
        target_label = "__address__"
        replacement  = "kubernetes.default.svc:443"
      }
      rule {
        source_labels = ["__meta_kubernetes_node_name"]
        regex         = "(.+)"
        target_label  = "__metrics_path__"
        replacement   = "/api/v1/nodes/$${1}/proxy/metrics/cadvisor"
      }
      rule {
        source_labels = ["__meta_kubernetes_node_name"]
        target_label  = "node"
      }
    }

    prometheus.scrape "kubelet" {
      targets    = discovery.relabel.kubelet.output
      forward_to = [prometheus.remote_write.mimir.receiver]

      scheme     = "https"
      bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
      tls_config {
        insecure_skip_verify = true
      }
      scrape_interval = "60s"
    }

    // ── kube-state-metrics ─────────────────────────────────────────────
    discovery.kubernetes "services" {
      role = "service"
      namespaces {
        names = ["observability"]
      }
    }

    discovery.relabel "kube_state_metrics" {
      targets = discovery.kubernetes.services.targets

      rule {
        source_labels = ["__meta_kubernetes_service_label_app_kubernetes_io_name"]
        regex         = "kube-state-metrics"
        action        = "keep"
      }
    }

    prometheus.scrape "kube_state_metrics" {
      targets    = discovery.relabel.kube_state_metrics.output
      forward_to = [prometheus.remote_write.mimir.receiver]
      scrape_interval = "60s"
    }

    // ── node-exporter ──────────────────────────────────────────────────
    discovery.relabel "node_exporter" {
      targets = discovery.kubernetes.services.targets

      rule {
        source_labels = ["__meta_kubernetes_service_label_app_kubernetes_io_name"]
        regex         = "prometheus-node-exporter"
        action        = "keep"
      }
    }

    prometheus.scrape "node_exporter" {
      targets    = discovery.relabel.node_exporter.output
      forward_to = [prometheus.remote_write.mimir.receiver]
      scrape_interval = "60s"
    }

    // ── Remote Write to Mimir ──────────────────────────────────────────
    prometheus.remote_write "mimir" {
      endpoint {
        url = "MIMIR_REMOTE_WRITE_ENDPOINT"
      }
      external_labels = {
        cluster = "CLUSTER_NAME",
      }
    }
  RIVER

  alloy_k8s_config = local.mimir_enabled ? "${local.alloy_k8s_logs_config}\n${local.alloy_k8s_metrics_config}" : local.alloy_k8s_logs_config

  # Alloy Helm request for the observability cluster itself (in-cluster Loki DNS)
  alloy_obs_helm_request = local.loki_enabled ? [{
    class        = local.obs_cluster_name
    tenant       = null
    type         = "helm"
    chart        = "alloy"
    repository   = "https://grafana.github.io/helm-charts"
    version      = "1.6.0"
    namespace    = "observability"
    release_name = "alloy"
    wait         = true
    timeout      = 300
    values = yamlencode({
      alloy = {
        configMap = {
          content = replace(
            replace(
              replace(
                local.alloy_k8s_config,
                "LOKI_PUSH_ENDPOINT",
                "http://loki-gateway.observability.svc.cluster.local/loki/api/v1/push"
              ),
              "CLUSTER_NAME",
              local.obs_cluster_name
            ),
            "MIMIR_REMOTE_WRITE_ENDPOINT",
            "http://mimir-gateway.observability.svc.cluster.local:80/api/v1/push"
          )
        }
      }
      controller = {
        type = "daemonset"
      }
      rbac = {
        rules = concat(
          [
            {
              apiGroups = ["", "discovery.k8s.io", "networking.k8s.io"]
              resources = ["endpoints", "endpointslices", "ingresses", "pods", "services"]
              verbs     = ["get", "list", "watch"]
            },
            {
              apiGroups = [""]
              resources = ["pods", "pods/log", "namespaces"]
              verbs     = ["get", "list", "watch"]
            },
            {
              apiGroups = ["monitoring.grafana.com"]
              resources = ["podlogs"]
              verbs     = ["get", "list", "watch"]
            }
          ],
          local.mimir_enabled ? [
            {
              apiGroups = [""]
              resources = ["nodes", "nodes/proxy", "nodes/metrics"]
              verbs     = ["get", "list", "watch"]
            }
          ] : []
        )
      }
    })

    # Unused fields (required by application_requests interface)
    script           = null
    params           = null
    target_tag_key   = null
    target_tag_value = null
    targeting_mode   = "compute"
    targets          = null
    playbook         = null
    playbook_file    = null
  }] : []

  # Alloy Helm template for non-observability EKS clusters
  # Root module fans this out per-cluster, replacing LOKI_PUSH_ENDPOINT with NLB DNS
  alloy_helm_template = local.loki_enabled ? {
    tenant       = null
    type         = "helm"
    chart        = "alloy"
    repository   = "https://grafana.github.io/helm-charts"
    version      = "1.6.0"
    namespace    = "observability"
    release_name = "alloy"
    wait         = true
    timeout      = 300
    values = yamlencode({
      alloy = {
        configMap = {
          content = local.alloy_k8s_config
        }
      }
      controller = {
        type = "daemonset"
      }
      rbac = {
        rules = concat(
          [
            {
              apiGroups = ["", "discovery.k8s.io", "networking.k8s.io"]
              resources = ["endpoints", "endpointslices", "ingresses", "pods", "services"]
              verbs     = ["get", "list", "watch"]
            },
            {
              apiGroups = [""]
              resources = ["pods", "pods/log", "namespaces"]
              verbs     = ["get", "list", "watch"]
            },
            {
              apiGroups = ["monitoring.grafana.com"]
              resources = ["podlogs"]
              verbs     = ["get", "list", "watch"]
            }
          ],
          local.mimir_enabled ? [
            {
              apiGroups = [""]
              resources = ["nodes", "nodes/proxy", "nodes/metrics"]
              verbs     = ["get", "list", "watch"]
            }
          ] : []
        )
      }
    })

    # Unused fields (required by application_requests interface)
    script           = null
    params           = null
    target_tag_key   = null
    target_tag_value = null
    targeting_mode   = "compute"
    targets          = null
    playbook         = null
    playbook_file    = null
  } : null

  helm_application_requests = concat(
    local.loki_helm_request,
    local.grafana_helm_request,
    local.alloy_obs_helm_request,
    local.mimir_helm_request,
    local.tempo_helm_request,
    local.kube_state_metrics_helm_request,
    local.prometheus_node_exporter_helm_request
  )

  # ── Alloy Agent Application Requests ───────────────────────────────────
  # Ansible-based deployment of Grafana Alloy to EC2 instances
  alloy_application_requests = length(local.agent_log_paths) > 0 ? [{
    class  = "alloy-agent"
    tenant = null
    type   = "ansible"

    playbook      = "alloy"
    playbook_file = "playbook.yml"
    params = {
      LOG_PATHS  = join(",", local.agent_log_paths)
      AWS_REGION = var.aws_region
    }

    targeting_mode = local.agent_targeting_mode == "managed" ? "tags" : local.agent_targeting_mode
    targets = (
      local.agent_targeting_mode == "managed" ? [
        {
          key    = "tag:Namespace"
          values = [var.namespace]
        }
      ] :
      local.agent_targeting_mode == "wildcard" ? [
        {
          key    = "InstanceIds"
          values = ["*"]
        }
      ] : null
    )

    # Unused fields
    script           = null
    target_tag_key   = null
    target_tag_value = null
    chart            = null
    repository       = null
    version          = null
    namespace        = null
    release_name     = null
    values           = null
    wait             = null
    timeout          = null
  }] : []
}

# ============================================================================
# S3 Access for Loki - via EKS Pod Identity (dependency inversion)
# ============================================================================
# Emits pod_identity_requests to compute module, which creates the IAM role,
# policy, and pod identity association. This avoids a circular dependency:
# observability emits compute_class_requests → compute creates cluster →
# compute creates pod identity associations using these requests.

locals {
  pod_identity_requests = local.eks_defined ? concat(
    local.loki_enabled ? [
      {
        name            = "loki-s3"
        cluster_class   = local.obs_cluster_name
        namespace       = "observability"
        service_account = "loki"
        policy = jsonencode({
          Version = "2012-10-17"
          Statement = [{
            Effect = "Allow"
            Action = [
              "s3:PutObject",
              "s3:GetObject",
              "s3:DeleteObject",
              "s3:ListBucket"
            ]
            Resource = [
              local.loki_chunks_bucket_arn,
              "${local.loki_chunks_bucket_arn}/*",
              local.loki_ruler_bucket_arn,
              "${local.loki_ruler_bucket_arn}/*"
            ]
          }]
        })
      }
    ] : [],
    local.mimir_enabled ? [
      {
        name            = "mimir-s3"
        cluster_class   = local.obs_cluster_name
        namespace       = "observability"
        service_account = "mimir"
        policy = jsonencode({
          Version = "2012-10-17"
          Statement = [{
            Effect = "Allow"
            Action = [
              "s3:PutObject",
              "s3:GetObject",
              "s3:DeleteObject",
              "s3:ListBucket"
            ]
            Resource = [
              local.mimir_blocks_bucket_arn,
              "${local.mimir_blocks_bucket_arn}/*"
            ]
          }]
        })
      }
    ] : [],
    local.tempo_enabled ? [
      {
        name            = "tempo-s3"
        cluster_class   = local.obs_cluster_name
        namespace       = "observability"
        service_account = "tempo"
        policy = jsonencode({
          Version = "2012-10-17"
          Statement = [{
            Effect = "Allow"
            Action = [
              "s3:PutObject",
              "s3:GetObject",
              "s3:DeleteObject",
              "s3:ListBucket"
            ]
            Resource = [
              local.tempo_traces_bucket_arn,
              "${local.tempo_traces_bucket_arn}/*"
            ]
          }]
        })
      }
    ] : []
  ) : []
}
