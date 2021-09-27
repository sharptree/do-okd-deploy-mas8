#/bin/bash

set -e

org_id=""
namespace="mongodb"

cmdname=${0##*/}
usage()
{
    cat << EOS >&2
Usage:
    $cmdname
    -o | --organization         The MongoDB organiation Id
    -n | --namespace            The Openshift MongoDB namespace (mongodb)
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
            -o|--organization ) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  private_key=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing a MongoDB organization Id." >&2
                  exit 1
              fi
            ;; 
            -n|--namespace) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  namespace=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing." >&2
                  exit 1
              fi
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

    if [ -z "${public_key}" ]; then
        get_orgid        
    fi


    create_sls_cred
}

get_orgid() {
    while [ -z "$org_id" ]; do
        read -p "Enter the MongoDB organization Id: " org_id

        if [ -z "$org_id" ]; then
            printf "\nThe MongoDB organization Id is required.\n"
        fi
    done
}

create_sls_cred(){
    # If the secret already exists then delete it.
    if [ ! -z "$(oc get configmap "ibm-sls-config" --ignore-not-found=true -n ${namespace})" ]; then
        oc delete configmap "ibm-sls-config" -n ${namespace} > /dev/null 2>&1
    fi

oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ibm-sls-config
data:
  projectName: "ibm-sls"
  orgId: ${org_id}
  baseUrl: http://ops-manager-svc.${namespace}.svc.cluster.local:8080
EOF

echo "Create OpenShift ConfigMap \"ibm-sls-config\""

}

main $@
if [ $? -ne 0 ]; then
    exit 1
else
    exit 0
fi