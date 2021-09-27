#!/bin/bash
set -e

APIKEY=""
INSTANCEID=""
DOMAIN=""
EMAIL=""
FIRSTNAME=""
LASTNAME=""


cmdname=${0##*/}
usage()
{
    cat << EOS >&2
Usage:
    $cmdname
    -a | --api-key              The Behavior Analytics access key   
    -d | --domain               The domain for the OKD cluster  
    -e | --email                Email to receive notifications
    -f | --first-name           The contact person's first name    
    -i | --instance             The Suite instance Id
    -l | --last-name            The contact person's last name    
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
            -a|--api-key ) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  APIKEY=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing an api key value." >&2
                  exit 1
              fi
            ;; 
            -d|--domain) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  DOMAIN=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing a domain." >&2
                  exit 1
              fi
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
            -f|--first-name) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  NAMESPACE=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing a first name." >&2
                  exit 1
              fi
            ;;              
            -i|--instance) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  TOKEN=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing a Suite instance Id." >&2
                  exit 1
              fi
            ;;  
            -l|--last-name) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  TOKEN=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing a last name." >&2
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

    if [ -z "${APIKEY}" ]; then
        get_api_key        
    fi

    if [ -z "${INSTANCEID}" ]; then
        get_instance_id            
    fi

    if [ -z "${DOMAIN}" ]; then
        get_domain_id            
    fi

    if [ -z "${EMAIL}" ]; then
        get_email_id            
    fi
    
    if [ -z "${FIRSTNAME}" ]; then
        get_first_name            
    fi

    if [ -z "${LASTNAME}" ]; then
        get_last_name            
    fi    

    create_bas_cfg
}

get_api_key() {
    while [ -z "$APIKEY" ]; do
        read -p "Enter the Behavior Analytics Services API Key: " APIKEY

        if [ -z "$APIKEY" ]; then
            printf "\nA Behavior Analytics Services API Key is required.\n"
        fi
    done
}

get_instance_id() {
    while [ -z "$INSTANCEID" ]; do
        read -p "Enter the Maximo Application Suite instance Id: " INSTANCEID

        if [ -z "$INSTANCEID" ]; then
            printf "\nA Maximo Application Suite instance Id is required.\n"
        fi
    done
}

get_domain_id() {
    while [ -z "$DOMAIN" ]; do
        read -p "Enter the OKD cluster domain: " DOMAIN

        if [ -z "$DOMAIN" ]; then
            printf "\nThe OKD cluster domain is required.\n"
        fi
    done
}

get_email_id() {
    while [ -z "$EMAIL" ]; do
        read -p "Enter a contact email: " EMAIL

        if [ -z "$EMAIL" ]; then
            printf "\nA contact email is required.\n"
        fi
    done
}

get_first_name() {
    while [ -z "$FIRSTNAME" ]; do
        read -p "Enter a contact first name: " FIRSTNAME

        if [ -z "$FIRSTNAME" ]; then
            printf "\nA contact first name is required.\n"
        fi
    done
}

get_last_name() {
    while [ -z "$LASTNAME" ]; do
        read -p "Enter a contact last name: " LASTNAME

        if [ -z "$LASTNAME" ]; then
            printf "\nA contact last name is required.\n"
        fi
    done
}

create_bas_cfg(){
  echo "Creating the Behavior Analytics Configuration."

  /usr/bin/cp -f ./resources/bas-cfg-template.yaml ./resources/bas-cfg.yaml 

  sed -i 's|${INSTANCEID}|'"$INSTANCEID"'|g' ./resources/bas-cfg.yaml 
  sed -i 's|${DOMAIN}|'"$DOMAIN"'|g' ./resources/bas-cfg.yaml 
  sed -i 's|${EMAIL}|'"$EMAIL"'|g' ./resources/bas-cfg.yaml 
  sed -i 's|${FIRSTNAME}|'"$FIRSTNAME"'|g' ./resources/bas-cfg.yaml 
  sed -i 's|${LASTNAME}|'"$LASTNAME"'|g' ./resources/bas-cfg.yaml 

  bascfg_check=$(oc get BasCfg digitalocean-dns -o json -n cert-manager --ignore-not-found)

  secret_check=$(oc get secret $INSTANCEID-usersupplied-bas-creds-system -o json -n cert-manager --ignore-not-found)

  if [ ! -z "$secret_check" ]; then 
    echo "The secret $INSTANCEID-usersupplied-bas-creds-system exits, replacing."
    oc delete secret $INSTANCEID-usersupplied-bas-creds-system -n "mas-${INSTANCEID}-core" >/dev/null
  fi

  oc create secret generic $INSTANCEID-usersupplied-bas-creds-system --from-literal=api_key="${APIKEY}" -n "mas-${INSTANCEID}-core" >/dev/null

  oc apply -f ./resources/bas-cfg.yaml 

  rm ./resources/bas-cfg.yaml 

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