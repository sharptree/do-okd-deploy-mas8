#!/bin/bash

function check_utilities(){

}

function validate_cert_manager(){
    if [ ! (oc get Deployment/cert-manager -n cert-manager | wc -l ) == 0 ]; then
        echo 'The cert-manager v1.1.0 is required, but is not installed.'
        echo 'Attempting to install the cert-manager v1.1.0.'

        oc apply -f https://github.com/jetstack/cert-manager/releases/download/v1.1.0/cert-manager.yaml

    else         
        echo 'Cert-manager is installed, checking version.'
        
        cert-manager-version=(oc get Deployment/cert-manager -n cert-manager -o json | jq '.spec.template.spec.containers[0].image')

        if [ ! cert-manager-version == 'quay.io/jetstack/cert-manager-controller:v1.1.0' ]; then
            echo 'The version of cert-manager is from ${cert-manager-version}, which is not supported.'
            exit 1            
        fi

        echo 'Cert-manager is installed and is the correct version.'
    fi
}

function config_mongo_cert(){
    # Create the Mongo CA and TLS certs
    if [ (oc get ClusterIssuer/letsencrypt | wc -l) == 0 ]; then 
        echo "The ClusterIssuer CRD letsencrypt is required, run the ./scripts/create-letsencrypt-cluster-issuer.sh script to create the ClusterIssuer."
        exit 1
    fi

    oc create -f ../resources/mongo-certs.yaml

    mkdir -p ./mongodb
    
    oc get secret ibm-sls-mongo-tls -o json | jq '.data["tls.crt"]'| sed -e 's/^"//' -e 's/"$//' | base64 --decode > ./mongodb/ibm-sls-0-pem
    oc get secret ibm-sls-mongo-tls -o json | jq '.data["tls.key"]'| sed -e 's/^"//' -e 's/"$//' | base64 --decode >> ./mongodb/ibm-sls-0-pem

    oc get secret ibm-sls-mongo-tls -o json | jq '.data["tls.crt"]'| sed -e 's/^"//' -e 's/"$//' | base64 --decode > ./mongodb/ibm-sls-1-pem
    oc get secret ibm-sls-mongo-tls -o json | jq '.data["tls.key"]'| sed -e 's/^"//' -e 's/"$//' | base64 --decode >> ./mongodb/ibm-sls-1-pem

    oc get secret ibm-sls-mongo-tls -o json | jq '.data["tls.crt"]'| sed -e 's/^"//' -e 's/"$//' | base64 --decode > ./mongodb/ibm-sls-2-pem
    oc get secret ibm-sls-mongo-tls -o json | jq '.data["tls.key"]'| sed -e 's/^"//' -e 's/"$//' | base64 --decode >> ./mongodb/ibm-sls-2-pem

    # If the secret already exists then delete it.
    if [ (oc get secret/ibm-sls-cert | wc -l) > 0]; then
        oc delete secret ibm-sls-cert -n mongodb
    fi 

    (cd ./mongodb && oc create secret generic ibm-sls-cert --from-file=ibm-sls-0-pem --from-file=ibm-sls-1-pem --from-file=ibm-sls-2-pem -n mongodb)

    oc get secret ibm-sls-mongo-tls -o json | jq '.data["ca.crt"]'| sed -e 's/^"//' -e 's/"$//' | base64 --decode > ./mongodb/ca-pem 
    
    (cd ./mongodb && oc create configmap ibm-sls-ca --from-file=ca-pem)   
}

