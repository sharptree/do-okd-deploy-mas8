#! /bin/bash

oc create namespace cert-manager

oc apply -f https://github.com/jetstack/cert-manager/releases/download/v1.1.0/cert-manager.yaml