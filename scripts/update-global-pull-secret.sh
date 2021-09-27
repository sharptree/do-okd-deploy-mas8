#!/bin/bash

registry_redhat_io=$(oc get secret redhat-entitlement-key --namespace openshift-marketplace  -o yaml | yq -r .data | cut -d : -f 2 | sed -e 's/"//g' -e 's/{//g' -e 's/}//g' -e 's/ //g' | base64 -d | yq -r '.auths."registry.redhat.io".auth')
registry_connect_redhat_com=$(oc get secret redhat-entitlement-key --namespace openshift-marketplace  -o yaml | yq -r .data | cut -d : -f 2 | sed -e 's/"//g' -e 's/{//g' -e 's/}//g' -e 's/ //g' | base64 -d | yq -r '.auths."registry.connect.redhat.com".auth')
cp_icr_io_auth=$(oc get secret ibm-entitlement-key --namespace openshift-marketplace -o yaml | yq -r .data | cut -d : -f 2 | sed -e 's/"//g' -e 's/{//g' -e 's/}//g' -e 's/ //g' | base64 -d | yq -r '.auths."cp.icr.io".auth')

oc apply -f - >/dev/null <<EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: pull-secret
      namespace: openshift-config
    stringData:
      .dockerconfigjson: |
        {
          "auths": {
            "registry.redhat.io": {
            "auth": "${registry_redhat_io}"
            },
            "registry.connect.redhat.com": {
            "auth": "${registry_connect_redhat_com}"
            },
            "cp.icr.io":{
            "auth": "${cp_icr_io_auth}"
            } 
          }
        }
    type: kubernetes.io/dockerconfigjson
EOF