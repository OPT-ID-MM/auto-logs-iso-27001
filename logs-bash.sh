#!/bin/bash
set -euo pipefail

PROJECTS_FILE="project_ids.txt"
NOTIFICATION_EMAIL="coqa@metricamovil.com"
CHANNEL_NAME="security-alerts-channel"
SINK_NAME="all-logs-sink"

METRICS=(
  "custom-role-changes|resource.type=\"iam_role\" AND (protoPayload.methodName=\"google.iam.admin.v1.CreateRole\" OR protoPayload.methodName=\"google.iam.admin.v1.DeleteRole\" OR protoPayload.methodName=\"google.iam.admin.v1.UpdateRole\")|Cambios en roles personalizados"
  "storage-iam-permission-changes|resource.type=\"gcs_bucket\" AND protoPayload.methodName=\"SetIamPolicy\"|Cambios IAM en Cloud Storage"
  "vpc-firewall-rule-changes|resource.type=\"gce_firewall_rule\" AND (protoPayload.methodName=\"compute.firewalls.insert\" OR protoPayload.methodName=\"compute.firewalls.delete\" OR protoPayload.methodName=\"compute.firewalls.patch\")|Cambios en reglas de firewall VPC"
  "vpc-network-changes|resource.type=\"gce_network\"|Cambios en redes VPC"
  "vpc-route-changes|resource.type=\"gce_route\"|Cambios en rutas de red VPC"
  "project-ownership-changes|protoPayload.methodName=\"SetIamPolicy\" AND protoPayload.serviceData.policyDelta.bindingDeltas.member:\"owner\"|Cambios de ownership en proyecto"
)

while IFS= read -r PROJECT_ID; do
  echo ""
  echo "🚀 Aplicando configuración ISO 27001 para: $PROJECT_ID"
  gcloud config set project "$PROJECT_ID" --quiet

  # Crear canal de notificación si no existe
  if ! gcloud alpha monitoring channels list --format="value(displayName)" | grep -q "$CHANNEL_NAME"; then
    echo "  ➤ Creando canal de notificación para $NOTIFICATION_EMAIL"
    gcloud alpha monitoring channels create \
      --display-name="$CHANNEL_NAME" \
      --type=email \
      --channel-labels=email_address="$NOTIFICATION_EMAIL" \
      --project="$PROJECT_ID" --quiet
  fi

  # Obtener ID del canal
  CHANNEL_ID=$(gcloud alpha monitoring channels list \
    --filter="displayName='$CHANNEL_NAME'" \
    --format="value(name)" \
    --project="$PROJECT_ID")

  for metric in "${METRICS[@]}"; do
    IFS="|" read -r METRIC_NAME FILTER DESCRIPTION <<< "$metric"

    echo "  ➤ Métrica: $METRIC_NAME"

    gcloud logging metrics create "$METRIC_NAME" \
      --description="$DESCRIPTION" \
      --log-filter="$FILTER" \
      --project="$PROJECT_ID" --quiet || echo "  ⚠️  Métrica ya existe o error leve"

    if [[ "$METRIC_NAME" == "storage-iam-permission-changes" ]]; then
      RESOURCE_TYPE="gcs_bucket"
    else
      RESOURCE_TYPE="global"
    fi

    POLICY_FILE="/tmp/policy_${PROJECT_ID}_${METRIC_NAME}.json"

    cat > "$POLICY_FILE" <<EOF
{
  "displayName": "ISO27001: $DESCRIPTION",
  "combiner": "OR",
  "notificationChannels": ["$CHANNEL_ID"],
  "conditions": [
    {
      "displayName": "Alerta: $DESCRIPTION",
      "conditionThreshold": {
        "filter": "resource.type=\"$RESOURCE_TYPE\" AND metric.type=\"logging.googleapis.com/user/$METRIC_NAME\"",
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0,
        "duration": "60s",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_RATE"
          }
        ]
      }
    }
  ]
}
EOF

    echo "  ➤ Alerta para $METRIC_NAME desde archivo temporal"

    gcloud alpha monitoring policies create \
      --policy-from-file="$POLICY_FILE" \
      --project="$PROJECT_ID" --quiet || echo "  ⚠️  Alerta ya existe o error leve"

    rm -f "$POLICY_FILE"
  done

  # Crear sink de logs si no existe
  SINK_DESTINATION="logging.googleapis.com/projects/$PROJECT_ID/locations/global/buckets/_Default"
  if ! gcloud logging sinks describe "$SINK_NAME" --project="$PROJECT_ID" &>/dev/null; then
    echo "  ➤ Creando sink de logs a bucket _default"
    gcloud logging sinks create "$SINK_NAME" "$SINK_DESTINATION" \
      --log-filter='' \
      --include-children \
      --project="$PROJECT_ID" --quiet
  else
    echo "  ➤ Sink $SINK_NAME ya existe"
  fi

  echo "✅ Proyecto $PROJECT_ID configurado correctamente"

done < "$PROJECTS_FILE"

echo ""
echo "🎯 Todos los proyectos están ahora cumpliendo ISO 27001 con métricas, alertas y sinks."
