#!/bin/bash

oc create namespace ibm-sls

oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ibm-sls
  namespace: ibm-sls
spec:
  targetNamespaces:
  - ibm-sls
EOF

oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-sls
  namespace: ibm-sls
spec:
  channel: 3.x
  name: ibm-sls
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace 
  startingCSV: ibm-sls.v3.2.0
EOF

status=$(oc get ClusterServiceVersion --namespace ibm-sls -o json  | jq -r ".items[] | select(.metadata.name == \"ibm-sls.v3.2.0\").status.phase")

while [ "${status}" != "Succeeded" ] || [ -z "${status}" ]; do
    echo "Waiting for IBM SLS Operator to be installed..."
    sleep 30
    status=$(oc get ClusterServiceVersion --namespace ibm-sls -o json  | jq -r ".items[] | select(.metadata.name == \"ibm-sls.v3.2.0\").status.phase")
    if [ "$status" = "Failed" ]; then
        echo "The installation of the IBM SLS Operator failed."
        exit 1
    fi    
done

echo "IBM SLS Operator installed."



oc apply -f - >/dev/null <<EOF
apiVersion: sls.ibm.com/v1
kind: LicenseService
metadata:
  name: sls
  namespace: ibm-sls
spec:
  license:
    accept: true
  domain: apps.maximo.sharptree.app
  mongo:
    configDb: ibm-sls
    nodes:
    - host: maximo-users-set-svc.mongodb.svc.cluster.local
      port: 27017
    secretName: sls-mongo-credentials
  rlks:
    storage:
      class: do-block-storage
      size: 5G
EOF