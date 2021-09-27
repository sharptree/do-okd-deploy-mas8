#!/bin/bash
redhat_token=""

cmdname=${0##*/}
usage()
{
    cat << EOS >&2
Usage:
    $cmdname [RedHat Access Token]    
    -h | --help                 Prints this help message

EOS
}

main(){
    while (( "$#" )); do
        case "$1" in                                     
            -h|--help) 
                usage               
                exit 0
            ;;     
            -*|--*=) # unsupported flags
                printf "\nError: Unsupported flag $1.\n" >&2
                exit 1
            ;;
            *) # preserve positional arguments
                PARAMS="$PARAMS $1"
                shift
            ;;
        esac
    done
    redhat_token=${PARAMS}

    if [ -z "${redhat_token}" ]; then
        get_redhat_token            
    fi

    redhat_token=$(echo "${redhat_token}" | xargs)
    create_redhat_catalog
}

get_redhat_token() {
    while [ -z "$redhat_token" ]; do
        read -p "Enter the RedHat Service Account Token: " redhat_token

        if [ -z "$redhat_token" ]; then
            printf "\nA RedHat Service Account Token is required.\n"
        fi
    done
}

function create_redhat_catalog(){

    oc apply -f - >/dev/null <<EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: redhat-entitlement-key
      namespace: openshift-marketplace
    stringData:
      .dockerconfigjson: |
        {
          "auths": {
            "registry.redhat.io": {
              "auth": "${redhat_token}"
            },
            "registry.connect.redhat.com": {
              "auth": "${redhat_token}"
            }
          }
        }
    type: kubernetes.io/dockerconfigjson
EOF

    oc apply -f - >/dev/null <<EOF
    apiVersion: operators.coreos.com/v1alpha1
    kind: CatalogSource
    metadata:
      name: certified-operators
      namespace: openshift-marketplace
    spec:
      displayName: Certified Operators

      image: 'registry.redhat.io/redhat/certified-operator-index:v4.7'
      secrets:
      - redhat-entitlement-key
      priority: -400
      publisher: Red Hat
      sourceType: grpc
      updateStrategy:
        registryPoll:
          interval: 10m0s
EOF

    oc apply -f - >/dev/null <<EOF
    apiVersion: operators.coreos.com/v1alpha1
    kind: CatalogSource
    metadata:
      name: redhat-operators
      namespace: openshift-marketplace
    spec:
      displayName: RedHat Operators

      image: 'registry.redhat.io/redhat/redhat-operator-index:v4.7'
      secrets:
      - redhat-entitlement-key
      priority: -400
      publisher: Red Hat
      sourceType: grpc
      updateStrategy:
        registryPoll:
          interval: 10m0s
EOF

    echo "Created Red Catalog Source with entitlement key stored in the docker-registry secret redhat-entitlement-key, openshift-marketplace namespace."

}


main $@
if [ $? -ne 0 ]; then
    exit 1
else
    exit 0
fi