#! /bin/bash
opsman_password=1gTW#aTa4TxFr-QkeT
opsman_db_password=1gTW#aTa4TxFr-QkeT
mongodb_namespace=mongodb

cluster_name=maximo
cluster_domain=sharptree.app

project_exists=$(oc get project  $mongodb_namespace --ignore-not-found=true)

if [ ! -z "${project_exists}" ]; then
    confirm=""
    while [ -z "$confirm" ]; do
        read -p "The project $mongodb_namespace exists, do you want to delete and recreate it (data will be lost)? (yes / no): " confirm
        
        confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')

        if [ "$confirm" != "no" ] && [ "$confirm" != "yes" ]; then
            confirm=""
            echo "Please respond with \"yes\" to continue or \"no\" to cancel."                    
        fi

        if [  "$confirm" = "no" ]; then
            exit 0
        fi

    done

  echo "Deleting existing $mongodb_namespace project..."

  oc delete project $mongodb_namespace >> /dev/null

  project_exists=$(oc get project $mongodb_namespace --ignore-not-found=true)

  # Wait until the project actually is deleted.
  while [ ! -z "${project_exists}" ]; do
    sleep 10
    project_exists=$(oc get project $mongodb_namespace --ignore-not-found=true)
  done

  echo "Project $mongodb_namespace deleted."
fi

# Sometimes there are left over resources, so make sure they are deleted.
if [ ! -z "$(oc get customresourcedefinitions.apiextensions.k8s.io "mongodb.mongodb.com" --ignore-not-found=true)" ]; then
  oc delete customresourcedefinitions.apiextensions.k8s.io "mongodb.mongodb.com"
fi

if [ ! -z "$(oc get customresourcedefinitions.apiextensions.k8s.io "mongodbusers.mongodb.com" --ignore-not-found=true)" ]; then
  oc delete customresourcedefinitions.apiextensions.k8s.io "mongodbusers.mongodb.com"
fi

if [ ! -z "$(oc get customresourcedefinitions.apiextensions.k8s.io "opsmanagers.mongodb.com" --ignore-not-found=true)" ]; then
  oc delete customresourcedefinitions.apiextensions.k8s.io "opsmanagers.mongodb.com"
fi

if [ ! -z "$(oc get clusterroles.rbac.authorization.k8s.io "mongodb-enterprise-operator-mongodb-webhook" --ignore-not-found=true)" ]; then
  oc delete clusterroles.rbac.authorization.k8s.io "mongodb-enterprise-operator-mongodb-webhook"
fi

if [ ! -z "$(oc get clusterroles.rbac.authorization.k8s.io "mongodb-enterprise-operator-mongodb-certs" --ignore-not-found=true)" ]; then
  oc delete clusterroles.rbac.authorization.k8s.io "mongodb-enterprise-operator-mongodb-certs"
fi

if [ ! -z "$(oc get clusterrolebindings.rbac.authorization.k8s.io "mongodb-enterprise-operator-mongodb-webhook-binding" --ignore-not-found=true)" ]; then
  oc delete clusterrolebindings.rbac.authorization.k8s.io "mongodb-enterprise-operator-mongodb-webhook-binding"
fi

if [ ! -z "$(oc get clusterrolebindings.rbac.authorization.k8s.io "mongodb-enterprise-operator-mongodb-certs-binding" --ignore-not-found=true)" ]; then
  oc delete clusterrolebindings.rbac.authorization.k8s.io "mongodb-enterprise-operator-mongodb-certs-binding"
fi

oc create namespace ${mongodb_namespace}
oc create -f https://github.com/mongodb/mongodb-enterprise-kubernetes/raw/master/crds.yaml
oc create -f https://github.com/mongodb/mongodb-enterprise-kubernetes/raw/master/mongodb-enterprise-openshift.yaml

oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
stringData:
  FirstName: Operations
  LastName: Manager
  Password: ${opsman_password}
  Username: opsman
type: Opaque
metadata:
  name: opsman-admin-credentials
  namespace: ${mongodb_namespace}
EOF

oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
stringData:
  password: ${opsman_db_password}
type: Opaque
metadata:
  name: opsman-db-password
  namespace: ${mongodb_namespace}
EOF

oc apply -f - >/dev/null <<EOF
apiVersion: mongodb.com/v1
kind: MongoDBOpsManager
metadata:
  name: ops-manager
  namespace: mongodb
spec:
  replicas: 1
  version: 5.0.1
  adminCredentials: opsman-admin-credentials

  backup:
    enabled: false

  applicationDatabase:
    members: 3
    version: 5.0.1-ent
    passwordSecretKeyRef:
      name: opsman-db-password
EOF

app_status=$(oc get opsmanagers.mongodb.com --namespace ${mongodb_namespace} -o json  | jq -r ".items[] | select(.metadata.name == \"ops-manager\").status.applicationDatabase.phase")
ops_status=$(oc get opsmanagers.mongodb.com --namespace ${mongodb_namespace} -o json  | jq -r ".items[] | select(.metadata.name == \"ops-manager\").status.opsManager.phase")

while [ "${app_status}" != "Running" ] || [ -z "${app_status}" ] || [ "${ops_status}" != "Running" ] || [ -z "${ops_status}" ]; do
    
    
    echo "Waiting for MongoDB Ops Manager to be installed..."
    sleep 30
    app_status=$(oc get opsmanagers.mongodb.com --namespace ${mongodb_namespace} -o json  | jq -r ".items[] | select(.metadata.name == \"ops-manager\").status.applicationDatabase.phase")
    ops_status=$(oc get opsmanagers.mongodb.com --namespace ${mongodb_namespace} -o json  | jq -r ".items[] | select(.metadata.name == \"ops-manager\").status.opsManager.phase")

    if [ "$app_status" = "Failed" ] || [ "$ops_status" = "Failed"  ]; then
        echo "The installation of the MongoDB failed."
        exit 1
    fi    
done

oc apply -f - >/dev/null <<EOF
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  name: ops-manager
  namespace: mongodb
spec:
  host: ops-manager-mongodb.apps.$cluster_name.$cluster_domain
  to:
    kind: Service
    name: ops-manager-svc
    weight: 100
  port:
    targetPort: mongodb
  tls:
    termination: edge
    certificate: |
      -----BEGIN CERTIFICATE-----
      MIIFeDCCBGCgAwIBAgISA6t+bohCdpEqdB+n6cgRQ4npMA0GCSqGSIb3DQEBCwUA
      MDIxCzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MQswCQYDVQQD
      EwJSMzAeFw0yMTA4MTYyMjMzMzFaFw0yMTExMTQyMjMzMjlaMCQxIjAgBgNVBAMT
      GWFwcHMubWF4aW1vLnNoYXJwdHJlZS5hcHAwggEiMA0GCSqGSIb3DQEBAQUAA4IB
      DwAwggEKAoIBAQC6vcJe5jgOiWu50Qk2ykiUXOtvRay11JkxNuK7IGKBxf9Nvz33
      FWBzV1UhPQcepABIOKTMmSQ3POSUcEQ1/wxUlHoUB4xIsEmIrnh8L2J3hgT09+el
      eaREs/Y0xTUQCjg8AutQ/I+rBQ950TPMW0Xy8SamfYYGtLncBIpWBIyDnVZ38vkY
      xg21PiE9b2S5AIHt6MeUmN+wLj/bnJKeKBhaerlVpbGloD8xWY1icAvytcF0EMS/
      kJ9AbgPBxgxndlbIp8TOg7DBR995ypA4ZNKDi0/JoEgLKCNbVSL/LlRijFaV9xE9
      LLUOPspoth8yIJ0GkdyuYjATsTDC6DjETBpdAgMBAAGjggKUMIICkDAOBgNVHQ8B
      Af8EBAMCBaAwHQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMCMAwGA1UdEwEB
      /wQCMAAwHQYDVR0OBBYEFAc8QwgHs4uHfqZdHDRJLK2DFVN8MB8GA1UdIwQYMBaA
      FBQusxe3WFbLrlAJQOYfr52LFMLGMFUGCCsGAQUFBwEBBEkwRzAhBggrBgEFBQcw
      AYYVaHR0cDovL3IzLm8ubGVuY3Iub3JnMCIGCCsGAQUFBzAChhZodHRwOi8vcjMu
      aS5sZW5jci5vcmcvMGMGA1UdEQRcMFqCGyouYXBwcy5tYXhpbW8uc2hhcnB0cmVl
      LmFwcIIgKi5ob21lLmFwcHMubWF4aW1vLnNoYXJwdHJlZS5hcHCCGWFwcHMubWF4
      aW1vLnNoYXJwdHJlZS5hcHAwTAYDVR0gBEUwQzAIBgZngQwBAgEwNwYLKwYBBAGC
      3xMBAQEwKDAmBggrBgEFBQcCARYaaHR0cDovL2Nwcy5sZXRzZW5jcnlwdC5vcmcw
      ggEFBgorBgEEAdZ5AgQCBIH2BIHzAPEAdgBc3EOS/uarRUSxXprUVuYQN/vV+kfc
      oXOUsl7m9scOygAAAXtRUCMBAAAEAwBHMEUCIERud/PmL/Sai0XkuDRhsUipWLws
      4s8gKSuofto7jmBgAiEAj5WzcdbxFSn+yk3plBS9JTM3jqh0oK9wMXtT/oayE2QA
      dwD2XJQv0XcwIhRUGAgwlFaO400TGTO/3wwvIAvMTvFk4wAAAXtRUCL6AAAEAwBI
      MEYCIQDZIq/MvboedTxflJfAcF8Ssqz13lzCbD+wRBDrtMtXbgIhAPOvyGIPGug9
      M+6nB7hsXqyqCgNnjJPtefN/RPCpq2pJMA0GCSqGSIb3DQEBCwUAA4IBAQBqhK4C
      7fEKWW49hVoW1jtXu7wLb+1n7HCO6Fg9jPlJVqqbk/XpO1kxG9xqVNpvEr1Jj1OI
      zWmdkx+J65rM0YMRC4tpDFcFSOfODsy4Hfei4VLMp/E63xeGORV+VmY2fBsaWPm8
      3cPRQDxuwvPquSFHHVWCF93jgIhwE7Z+69NUzuOR/OnVJ8EZ6UUkt0l45yaY/QWa
      tHpq+hrsWeO0D9rnzX3K/zUUiozx0KKvNycoQBAxGFUrcUM26I13kVb/SKkDLiKl
      VmdKQUogT5qXzinpgKDzx9LyOYQUwVzZz781V/VKrNVgse44SRv6leJd+0hyYVIQ
      z/zlysiHsCQyJANv
      -----END CERTIFICATE-----
    key: |
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEAur3CXuY4DolrudEJNspIlFzrb0WstdSZMTbiuyBigcX/Tb89
      9xVgc1dVIT0HHqQASDikzJkkNzzklHBENf8MVJR6FAeMSLBJiK54fC9id4YE9Pfn
      pXmkRLP2NMU1EAo4PALrUPyPqwUPedEzzFtF8vEmpn2GBrS53ASKVgSMg51Wd/L5
      GMYNtT4hPW9kuQCB7ejHlJjfsC4/25ySnigYWnq5VaWxpaA/MVmNYnAL8rXBdBDE
      v5CfQG4DwcYMZ3ZWyKfEzoOwwUffecqQOGTSg4tPyaBICygjW1Ui/y5UYoxWlfcR
      PSy1Dj7KaLYfMiCdBpHcrmIwE7Ewwug4xEwaXQIDAQABAoIBAHBaFwWNsZBdcajc
      cZS7Y6uPtD7ARscnX/vSL9uyAlJd09rtAtUT0XHTy24yD4SJ23mYSt6mDLoHMud0
      HDX4e2yv4DsIx4g8OCG6BteAkteilHzmYkKWyxRiyfC57dD2tRq2Duos6itU4hjC
      m02KZK1kFYL55pdGSMRtHuXd2sSb7yY94kt1RmDxu+WOYfh/Dug1Qlprt4qqCJdx
      ab5d/cmfqrVBvOiy5kCfqXsRhyPJm4eNwPK6qWTGML2mTnFLtf0sqqVmDEemtJHY
      R4a/hBcOhdG3HBARWHtPJf+B4H3Gs5TCwiNfnvBYB1zpcOiOG/EcVS5I4l1KbNvp
      b4vlRikCgYEAycixtEtjiEoLAlOs70eMXca/ahIZfJTEIjEoPSXT3gWwNUIw8PIj
      lZGoRV6Qkjea8I1RCsbdDg9SLBMK9Rpiqx9CXycSrJxduSUQWu7XuWFENovqlfT8
      YOYU3cGVEJ5+58bbRgZrS73Dfy+fPfZ6lG84WGtCSqtA50jbEBqpldsCgYEA7Oph
      0ZpyhREVMqEHUkzKTQI307OemnkKFViIJC4lsEA2nTwpSFpb4dbQhcsOjtKxlvey
      9XqRO+JA2l8Ziyf6Q3N3CCyjMUTnQ/+KPtnBl1uTo8ONsLCHJQyUwXAwb7+XQpyH
      lvlnHIVnAAiVxVCw0iZnb0mQk3ijibl7PIwMsicCgYBx93dexGGv/Vngc5AuCTQf
      VvyPlS9t7LwmL6txdecG9CGEwyDPRYORm5X1sCZpXxyUlsxaEN2TblXT7OF4c/Gc
      guhCw9fJQ/uvcV6ebV3MJ0KWqEnTbm4I8IqCgS6HF23HzMnV8BQz0DcVo7kGDytG
      oNarIdFsSPM8birEGrsDlwKBgQDBpOXlS8c1Cnx4EHSKiWeFQD3fVN5bRnm+bsmA
      QRPfFu1M4YKgt/KICmwQH6O7i21KhxWIXfFdsBXwJ3Eac8ez4Cm3zbxppfcddj5K
      FvSMQXbQkSM7+13LI5hm78s3W7NH5+dPuHTWNBe3SE0apVSRwIAkz01TrHSHOssG
      9zXdWwKBgFWmtd5+afaGGFL6hyVyAS5PybLbwuicjJQRmVnsM5z40jzGfjA0iRMv
      rzUCRYg7ATNArXtJv6kPXh0t/feA7lwAz+OyPj3kijECMnGIh2v/UnzKeFejeRz9
      5i43+tYCaf8YhA1GSTUmoK9vhC/Ap517fVNh79vhguGChtxmOGFP
      -----END RSA PRIVATE KEY-----
    caCertificate: |
      -----BEGIN CERTIFICATE-----
      MIIFFjCCAv6gAwIBAgIRAJErCErPDBinU/bWLiWnX1owDQYJKoZIhvcNAQELBQAw
      TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
      cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMjAwOTA0MDAwMDAw
      WhcNMjUwOTE1MTYwMDAwWjAyMQswCQYDVQQGEwJVUzEWMBQGA1UEChMNTGV0J3Mg
      RW5jcnlwdDELMAkGA1UEAxMCUjMwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
      AoIBAQC7AhUozPaglNMPEuyNVZLD+ILxmaZ6QoinXSaqtSu5xUyxr45r+XXIo9cP
      R5QUVTVXjJ6oojkZ9YI8QqlObvU7wy7bjcCwXPNZOOftz2nwWgsbvsCUJCWH+jdx
      sxPnHKzhm+/b5DtFUkWWqcFTzjTIUu61ru2P3mBw4qVUq7ZtDpelQDRrK9O8Zutm
      NHz6a4uPVymZ+DAXXbpyb/uBxa3Shlg9F8fnCbvxK/eG3MHacV3URuPMrSXBiLxg
      Z3Vms/EY96Jc5lP/Ooi2R6X/ExjqmAl3P51T+c8B5fWmcBcUr2Ok/5mzk53cU6cG
      /kiFHaFpriV1uxPMUgP17VGhi9sVAgMBAAGjggEIMIIBBDAOBgNVHQ8BAf8EBAMC
      AYYwHQYDVR0lBBYwFAYIKwYBBQUHAwIGCCsGAQUFBwMBMBIGA1UdEwEB/wQIMAYB
      Af8CAQAwHQYDVR0OBBYEFBQusxe3WFbLrlAJQOYfr52LFMLGMB8GA1UdIwQYMBaA
      FHm0WeZ7tuXkAXOACIjIGlj26ZtuMDIGCCsGAQUFBwEBBCYwJDAiBggrBgEFBQcw
      AoYWaHR0cDovL3gxLmkubGVuY3Iub3JnLzAnBgNVHR8EIDAeMBygGqAYhhZodHRw
      Oi8veDEuYy5sZW5jci5vcmcvMCIGA1UdIAQbMBkwCAYGZ4EMAQIBMA0GCysGAQQB
      gt8TAQEBMA0GCSqGSIb3DQEBCwUAA4ICAQCFyk5HPqP3hUSFvNVneLKYY611TR6W
      PTNlclQtgaDqw+34IL9fzLdwALduO/ZelN7kIJ+m74uyA+eitRY8kc607TkC53wl
      ikfmZW4/RvTZ8M6UK+5UzhK8jCdLuMGYL6KvzXGRSgi3yLgjewQtCPkIVz6D2QQz
      CkcheAmCJ8MqyJu5zlzyZMjAvnnAT45tRAxekrsu94sQ4egdRCnbWSDtY7kh+BIm
      lJNXoB1lBMEKIq4QDUOXoRgffuDghje1WrG9ML+Hbisq/yFOGwXD9RiX8F6sw6W4
      avAuvDszue5L3sz85K+EC4Y/wFVDNvZo4TYXao6Z0f+lQKc0t8DQYzk1OXVu8rp2
      yJMC6alLbBfODALZvYH7n7do1AZls4I9d1P4jnkDrQoxB3UqQ9hVl3LEKQ73xF1O
      yK5GhDDX8oVfGKF5u+decIsH4YaTw7mP3GFxJSqv3+0lUFJoi5Lc5da149p90Ids
      hCExroL1+7mryIkXPeFM5TgO9r0rvZaBFOvV2z0gp35Z0+L4WPlbuEjN/lxPFin+
      HlUjr8gRsI3qfJOQFy/9rKIJR0Y/8Omwt/8oTWgy1mdeHmmjk7j1nYsvC9JSQ6Zv
      MldlTTKB3zhThV1+XWYp6rjd5JW1zbVWEkLNxE7GJThEUG3szgBVGP7pSWTUTsqX
      nLRbwHOoq7hHwg==
      -----END CERTIFICATE----- 
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF
