#!/bin/bash
set -e

TOKEN=""
NAMESPACE="cert-manager"
EMAIL=""

cmdname=${0##*/}
usage()
{
    cat << EOS >&2
Usage:
    $cmdname     
    -e | --email                Email to receive certificate notifications (optional)
    -n | --namespace            The namespace to create the ClusterIssuer CRD in, defaults to cert-manager
    -t | --token                The DigitalOcean access token (required)
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
            -e|--email) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  EMAIL=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing an email address." >&2
                  exit 1
              fi
            ;;              
            -n|--namespace) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  NAMESPACE=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing a namespace value." >&2
                  exit 1
              fi
            ;;              
            -t|--token) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  TOKEN=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing a DigitalOcean access token." >&2
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
    
    if [ -z "${TOKEN}" ]; then
        get_do_token            
    fi


    create_letsencrypt_ci
}

create_letsencrypt_ci(){
  echo "Creating Let's Encrypt ClusterIssuer CRD."

  secret_check=$(oc get secret digitalocean-dns -o json -n cert-manager --ignore-not-found)

  if [ -z "${secret_check}" ]; then
    oc create secret generic digitalocean-dns --from-literal=access-token="${TOKEN}" -n "${NAMESPACE}" >/dev/null
  else 
    echo "The secret digitalocean-dns already exists, skipping creation."
  fi

  ci_check=$(oc get ClusterIssuer --ignore-not-found -o json |  jq -r ".items[] | select(.metadata.name == \"letsencrypt\").metadata.name")

  if [ -z "${ci_check}" ]; then
    oc apply -f - >/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
    name: letsencrypt    
spec:
  acme:
    email: "${EMAIL}"
    preferredChain: ISRG Root X1
    privateKeySecretRef:
      name: letsencrypt-account-key
    server: 'https://acme-v02.api.letsencrypt.org/directory'
    solvers:
      - dns01:
          digitalocean:
            tokenSecretRef:
              key: access-token
              name: digitalocean-dns
EOF
  else 
    echo "The ClusterIssuer 'letsencrypt' already exists, skipping creation"
  fi

  echo "Created Let's Encrypt ClusterIssuer CRD."
}

get_do_token() {
    while [ -z "$TOKEN" ]; do
        read -p "Enter the DigitalOcean Access Token: " TOKEN

        if [ -z "$TOKEN" ]; then
            printf "\nA DigitalOcean Access Token is required.\n"
        fi
    done
}


main $@
if [ $? -ne 0 ]; then
    exit 1
else
    exit 0
fi