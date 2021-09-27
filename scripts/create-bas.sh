#!/bin/bash
bas_username=basuser
bas_password=baspassword

grafana_username=grafanauser
grafana_password=grafanapassword

oc new-project ibm-bas

oc create secret generic database-credentials --from-literal=db_username=${bas_username} --from-literal=db_password=${bas_password} -n ibm-bas

oc create secret generic grafana-credentials --from-literal=grafana_username=${grafana_username} --from-literal=grafana_password=${grafana_password} -n ibm-bas

oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: behavior-analytics-services-operator-certified
  namespace: ibm-bas
spec:
  targetNamespaces:
  - ibm-bas
EOF

oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: behavior-analytics-services-operator-certified
  namespace: ibm-bas
spec:
  channel: alpha
  name: behavior-analytics-services-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace 
EOF

status=$(oc get ClusterServiceVersion --namespace ibm-bas -o json  | jq -r ".items[] | select(.metadata.name == \"behavior-analytics-services-operator.v1.1.0\").status.phase")
while [ "${status}" != "Succeeded" ] || [ -z "${status}" ]; do
    echo "Waiting for Behavior Analytics Service Operator to be installed..."
    sleep 30
    status=$(oc get ClusterServiceVersion --namespace ibm-bas -o json  | jq -r ".items[] | select(.metadata.name == \"behavior-analytics-services-operator.v1.1.0\").status.phase")
    if [ "$status" = "Failed" ]; then
        echo "The installation of the Behavior Analytics Service Operator failed."
        exit 1
    fi    
done

echo "Behavior Analytics Service Operator to be installed."

oc apply -f - >/dev/null <<EOF
apiVersion: bas.ibm.com/v1
kind: FullDeployment
metadata:
  name: maximo
  namespace: ibm-bas
spec:
  db_archive:
    frequency: '@monthly'
    retention_age: 6
    persistent_storage:
      storage_class: csi-s3
      storage_size: 10G
  prometheus_scheduler_frequency: '@daily'
  airgapped:
    enabled: false
    backup_deletion_frequency: '@daily'
    backup_retention_period: 7
  image_pull_secret: bas-images-pull-secret
  kafka:
    storage_class: do-block-storage
    storage_size: 5G
    zookeeper_storage_class: do-block-storage
    zookeeper_storage_size: 5G
  env_type: lite
  prometheus_metrics: []
  event_scheduler_frequency: '@hourly'
  ibmproxyurl: 'https://iaps.ibm.com'
  allowed_domains: '*'
  postgres:
    storage_class: do-block-storage
    storage_size: 10G
EOF

status=$(oc get FullDeployment --namespace ibm-bas -o json  | jq -r ".items[] | select(.metadata.name == \"maximo\").status.phase")

while [ "${status}" != "Ready" ] || [ -z "${status}" ]; do
    echo "Waiting for Behavior Analytics Service Full Deployment to be installed..."
    sleep 30
    status=$(oc get FullDeployment -o json | jq -r ".items[] | select(.metadata.name == \"maximo\").status.phase")
    if [ "$status" = "Failed" ]; then
        echo "The installation of the Behavior Analytics Service Full Deployment failed."
        exit 1
    fi
done

echo "Behavior Analytics Service Full Deployment to be installed."


