# Local observability runbook

This runbook verifies the local OpenTelemetry path managed by ArgoCD. It requires the kind lab from `bash ./scripts/lab.sh create` and does not require Azure access.

## Signal path

```text
telemetrygen-traces ──OTLP/gRPC──┐
                                 ├──> OpenTelemetry Collector
telemetrygen-metrics ─OTLP/gRPC──┘       ├── traces -> debug output
                                         ├── metrics -> Prometheus exporter :8889
                                         └── collector metrics :8888
                                                └──> Prometheus -> Grafana
```

The generator sends one trace or metric per second with service name `lab-checkout`. The collector's trace debug exporter is intentionally ephemeral; it demonstrates receipt and export in collector logs rather than providing trace storage.

## Verify deployment and OTLP signals

1. Check that ArgoCD reconciled both pinned Helm chart Applications:

   ```bash
   kubectl -n argocd get applications lab-observability otel-collector
   ```

   Both should become `Synced` and `Healthy`.

2. Check that the collector, generators, Prometheus, and Grafana are ready:

   ```bash
   kubectl -n observability get deployments,pods,services
   ```

   The `telemetrygen-traces`, `telemetrygen-metrics`, and `otel-collector` Deployments should have one ready replica.

3. Confirm that traces reach the collector:

   ```bash
   kubectl -n observability logs deployment/otel-collector --since=2m | grep lab-checkout
   ```

   The debug exporter should include spans associated with `lab-checkout`.

4. Port-forward Prometheus and query the collector's scrape and pipeline counters:

   ```bash
   kubectl -n observability port-forward svc/lab-observability-kube-prometheus-prometheus 9090:9090
   ```

   Open <http://localhost:9090> and run these queries. Allow about a minute for the first samples.

   ```promql
   up{job="otel-collector"}
   sum(rate(otelcol_receiver_accepted_spans[5m]))
   sum(rate(otelcol_exporter_sent_spans[5m]))
   sum(rate(otelcol_receiver_accepted_metric_points[5m]))
   sum(rate(otelcol_exporter_sent_metric_points[5m]))
   sum(lab_gen)
   ```

   The scrape target should be `1`; accepted and sent counters should increase while the generators run. `lab_gen` is the telemetrygen sample gauge after the Collector's Prometheus exporter adds the `lab_` namespace prefix.

5. Open Grafana and inspect **Local telemetry pipeline**:

   ```bash
   kubectl -n observability port-forward svc/lab-observability-grafana 3000:80
   ```

   Browse to <http://localhost:3000>. The initial Grafana password is stored in the chart-created Secret and can be read locally with:

   ```bash
   kubectl -n observability get secret lab-observability-grafana \
     -o jsonpath='{.data.admin-password}' | base64 --decode; echo
   ```

   Sign in as `admin`. The dashboard compares received with exported spans and metric points, and shows failed exports.

## Diagnose a broken path

Follow the signal in order from source to backend:

1. **ArgoCD application not healthy:** inspect the child Application's conditions and events:

   ```bash
   kubectl -n argocd describe application otel-collector
   kubectl -n argocd describe application lab-observability
   ```

   A chart fetch or Helm rendering error appears in Application status.

2. **Generator not running or no spans in collector logs:** check pod status, events, and generator logs:

   ```bash
   kubectl -n observability get pods
   kubectl -n observability describe pod -l app.kubernetes.io/name=telemetrygen-traces
   kubectl -n observability logs deployment/telemetrygen-traces --since=5m
   kubectl -n observability get endpoints otel-collector
   ```

   Image pull failures prevent generation. OTLP connection errors usually mean the collector service has no ready endpoints or the OTLP service port is unavailable.

3. **Collector receives but does not export:** inspect collector errors and the dashboard's failure panels:

   ```bash
   kubectl -n observability logs deployment/otel-collector --since=5m
   ```

   Compare accepted and sent counters. A positive failure rate points to an exporter or downstream issue; this local configuration exports traces to debug output and metrics to the Prometheus exporter.

4. **Prometheus has no collector samples:** in Prometheus, check `up{job="otel-collector"}` and `up{job="otel-exported-metrics"}`. If either is `0` or absent, inspect the scrape targets at <http://localhost:9090/targets>, then check the collector service and logs:

   ```bash
   kubectl -n observability get service otel-collector -o yaml
   kubectl -n observability logs deployment/otel-collector --since=5m
   ```

   The collector telemetry endpoint is port `8888`; the OTLP metrics exporter is port `8889`.

5. **Prometheus queries work but Grafana is empty:** confirm Grafana is ready, the `Prometheus` data source is healthy, and the dashboard ConfigMap is present:

   ```bash
   kubectl -n observability get pods,configmap telemetry-pipeline-dashboard
   ```

   Recheck the dashboard time range after waiting for the first scrape samples.

## Mapping to Azure Monitor / Application Insights

The local path is a learning analog, not an Azure integration. No cloud exporter, credentials, or live Azure resource is configured.

| Local lab signal or component | Azure mapping |
| --- | --- |
| OTLP trace and metric receivers in the Collector | Azure Monitor OpenTelemetry distribution / Azure Monitor exporter ingestion |
| `service.name=lab-checkout` on generated telemetry | Application Insights cloud role name and service identity |
| Collector accepted/sent/failure counters | Azure Monitor OpenTelemetry Collector health and ingestion diagnostics |
| Prometheus metrics and Grafana dashboard | Azure Monitor workspace managed Prometheus and Azure Managed Grafana |
| Collector debug trace output | Application Insights transaction search and distributed trace views when exporting to Azure |

In an Azure deployment, retain the OpenTelemetry resource identity and replace the local debug/Prometheus exporters with appropriately configured Azure Monitor exporters or the supported Azure Monitor OpenTelemetry distribution. Supply authentication through managed identity or another approved secret mechanism; do not put credentials in Git.
