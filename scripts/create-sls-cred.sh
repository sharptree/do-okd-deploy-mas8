#/bin/bash

set -e

public_key=""
private_key=""
namespace="mongodb"

cmdname=${0##*/}
usage()
{
    cat << EOS >&2
Usage:
    $cmdname
    -k | --key                  The MongoDB private key
    -n | --namespace            The Openshift MongoDB namespace (mongodb)
    -u | --user                 The MongoDB public key
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
            -k|--key ) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  private_key=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing a private key value." >&2
                  exit 1
              fi
            ;; 
            -u|--user) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  public_key=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing a user public key." >&2
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
        get_public_key        
    fi

    if [ -z "${private_key}" ]; then
        get_private_key            
    fi

    create_sls_cred
}

get_public_key() {
    while [ -z "$public_key" ]; do
        read -p "Enter the MongoDB access user (public key): " public_key

        if [ -z "$public_key" ]; then
            printf "\nThe MongoDB access user (public key) is required.\n"
        fi
    done
}

get_private_key() {
    while [ -z "$private_key" ]; do
        read -s -p "Enter the MongoDB access private key: " private_key

        if [ -z "$private_key" ]; then
            printf "\nThe MongoDB access private key.\n"
        fi
    done
    echo ""
}

create_sls_cred(){
    # If the secret already exists then delete it.
    if [ ! -z "$(oc get secret "ibm-sls-api-key" --ignore-not-found=true -n ${namespace})" ]; then
        oc delete secret "ibm-sls-api-key" -n ${namespace} > /dev/null 2>&1
    fi

oc apply -f - >/dev/null <<EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: ibm-sls-api-key
    stringData:
      user: ${public_key}
      publicApiKey: ${private_key}
    type: Opaque
EOF

echo "Create OpenShift Secret \"ibm-sls-api-key\""

}

main $@
if [ $? -ne 0 ]; then
    exit 1
else
    exit 0
fi