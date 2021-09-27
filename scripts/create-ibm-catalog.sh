#!/bin/bash
entitlement_key=""

cmdname=${0##*/}
usage()
{
    cat << EOS >&2
Usage:
    $cmdname [IBM Entitlement Key]
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

    if [ -z "${PARAMS}" ]; then
        get_entitlement_key        
        create_entitlement ${entitlement_key}
    else 
        create_entitlement ${PARAMS}
    fi
}

get_entitlement_key() {
    while [ -z "$entitlement_key" ]; do
        read -p "Enter IBM Entitlement Key: " entitlement_key

        if [ -z "$entitlement_key" ]; then
            printf "\nAn IBM Entitlement Key is required.\n"
        fi
    done
}

function create_entitlement(){
    redhat_token=$(echo "${entitlement_key}" | xargs)

    local entitlement_key=$1
    oc create secret docker-registry ibm-entitlement-key \
        --docker-username=cp \
        --docker-password=${entitlement_key} \
        --docker-server=cp.icr.io \
        --namespace=openshift-marketplace >/dev/null

    oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
    name: ibm-operator-catalog
    namespace: openshift-marketplace
spec:
    displayName: "IBM Operator Catalog" 
    publisher: IBM
    sourceType: grpc
    image: docker.io/ibmcom/ibm-operator-catalog
    updateStrategy:
    registryPoll:
        interval: 45m
EOF

    echo "Created IBM Catalog Source with entitlement key stored in the docker-registry secret ibm-entitlement-key, openshift-marketplace namespace."

}


main $@
if [ $? -ne 0 ]; then
    exit 1
else
    exit 0
fi