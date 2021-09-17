#!/bin/bash
set -eu -o pipefail

DIGITAL_OCEAN_SPACES_KEY=""
DIGITAL_OCEAN_SPACES_SECRET=""
DIGITAL_OCEAN_ACCESS_TOKEN=""

action_install=0
action_remove=0

# Load the environment variables that control the behavior of this
# script.
source ./config

# Returns a string representing the image ID for a given name.
# Returns empty string if none exists
get_image_from_name() {
    doctl compute image list-user -o json | \
        jq -r ".[] | select(.name == \"${DROPLET_IMAGE_NAME}\").id"
}

# https://docs.fedoraproject.org/en-US/fedora-coreos/provisioning-digitalocean/
create_image_if_not_exists() {
    echo -e "\nCreating custom image ${DROPLET_IMAGE_NAME}.\n"

    # if image exists, return
    if [ "$(get_image_from_name)" != "" ]; then
        echo "Image with name already exists. Skipping image creation."
        return 0
    fi

    # Create the image from the URL
    doctl compute image create         \
        $DROPLET_IMAGE_NAME            \
        --region $DIGITAL_OCEAN_REGION \
        --image-url $FCOS_IMAGE_URL >/dev/null

    # Wait for the image to finish being created
    for x in {0..100}; do
        if [ "$(get_image_from_name)" != "" ]; then
            return 0 # We're done
        fi
        echo "Waiting for image to finish creation..."
        sleep 10
    done

    echo "Image never finished being created." >&2
    return 1
}

generate_manifests() {
    echo -e "\nGenerating manifests/configs for install.\n"

    # Clear out old generated files
    rm -rf ./generated-files/ && mkdir ./generated-files

    # Copy install-config in place (remove comments) and replace tokens
    # in the template with the actual values we want to use.
    grep -v '^#' resources/install-config.yaml.in > generated-files/install-config.yaml
    for token in BASEDOMAIN      \
                 CLUSTERNAME     \
                 NUM_OKD_WORKERS \
                 NUM_OKD_CONTROL_PLANE;
    do
        sed -i "s/$token/${!token}/" generated-files/install-config.yaml
    done

    # Generate manifests and create the ignition configs from that.
    openshift-install create manifests --dir=generated-files
    openshift-install create ignition-configs --dir=generated-files

    # Copy the bootstrap ignition file to a remote location so we can
    # pull from it on startup. It's too large to fit in user-data.
    sum=$(sha512sum ./generated-files/bootstrap.ign | cut -d ' ' -f 1)
    aws --endpoint-url $SPACES_ENDPOINT s3 cp \
        ./generated-files/bootstrap.ign "${SPACES_BUCKET}/bootstrap.ign" >/dev/null

    # Generate a pre-signed URL to use to grab the config. Ensures
    # only we can grab it and it expires after short period of time.
    url=$(aws --endpoint-url $SPACES_ENDPOINT s3 presign \
                "${SPACES_BUCKET}/bootstrap.ign" --expires-in 300)
    # backslash escape the '&' chars in the URL since '&' is interpreted by sed
    escapedurl=${url//&/\\&}

    # Add tweaks to the bootstrap ignition and a pointer to the remote bootstrap
    cat resources/fcct-bootstrap.yaml     | \
        sed "s|SHA512|sha512-${sum}|"     | \
        sed "s|SOURCE_URL|${escapedurl}|" | \
        fcct -o ./generated-files/bootstrap-processed.ign

    # Add tweaks to the control plane config
    cat resources/fcct-control-plane.yaml | \
        fcct -d ./ -o ./generated-files/control-plane-processed.ign

    # Add tweaks to the worker config
    cat resources/fcct-worker.yaml | \
        fcct -d ./ -o ./generated-files/worker-processed.ign
}

# returns if we have any worker nodes or not to create
have_workers() {
    if [ $NUM_OKD_WORKERS -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# prints a sequence of numbers to iterate over from 0 to N-1
# for the number of control plane nodes
control_plane_num_sequence() {
    seq 0 $((NUM_OKD_CONTROL_PLANE-1))
}

# prints a sequence of numbers to iterate over from 0 to N-1
# for the number of worker nodes
worker_num_sequence() {
    seq 0 $((NUM_OKD_WORKERS-1))
}

create_droplets() {
    echo -e "\nCreating droplets.\n"

    image_id=$(get_image_from_name)

    local common_options=''
    common_options+="--region $DIGITAL_OCEAN_REGION "
    common_options+="--ssh-keys $DROPLET_KEYPAIR "    
    common_options+="--image $(get_image_from_name) "
    common_options+="--vpc-uuid $(get_vpc_id) "

    # Create bootstrap node

    # Check if there is an existing bootstrap first.
    droplet_id=$(doctl compute droplet list -o json | jq -r  ".[] | select(.name == \"bootstrap\" and .region.slug == \"${DIGITAL_OCEAN_REGION}\").id")
    if [ ! -z "$droplet_id" ]; then
        doctl compute droplet delete $droplet_id --force
    fi

    doctl compute droplet create bootstrap $common_options        \
        --size "$DROPLET_SIZE" \
        --tag-names "${ALL_DROPLETS_TAG},${CONTROL_DROPLETS_TAG}" \
        --user-data-file generated-files/bootstrap-processed.ign >/dev/null


    control_droplet_size="${CONTROL_DROPLET_SIZE:-$DROPLET_SIZE}"     

    # Create control plane nodes
    for num in $(control_plane_num_sequence); do

        droplet_id=$(doctl compute droplet list -o json | jq -r  ".[] | select(.name == \"okd-control-${num}\" and .region.slug == \"${DIGITAL_OCEAN_REGION}\").id")

        if [ -z "${droplet_id}" ]; then 
            echo -e "Creating droplet okd-control-${num}.\n"
            doctl compute droplet create "okd-control-${num}" $common_options \
                --tag-names "${ALL_DROPLETS_TAG},${CONTROL_DROPLETS_TAG}" \
                --size "$control_droplet_size" \
                --user-data-file generated-files/control-plane-processed.ign >/dev/null 
        else
            echo -e "\nDroplet okd-control-${num} exists, verifying.\n"
            if [ -z $(doctl compute droplet list -o json | jq -r  ".[] | select(.id == ${droplet_id} and .image.id == ${image_id} and .size.slug == \"${control_droplet_size}\").id") ]; then
                echo -e "\nDroplet okd-control-${num} exists, but is either has the wrong Image Id or does not match the size configured.\n"
                exit 1
            fi
        fi
    done

    # Create worker nodes
    if have_workers; then
        worker_droplet_size="${WORKER_DROPLET_SIZE:-$DROPLET_SIZE}"
        for num in $(worker_num_sequence); do
            droplet_id=$(doctl compute droplet list -o json | jq -r  ".[] | select(.name == \"okd-worker-${num}\" and .region.slug == \"${DIGITAL_OCEAN_REGION}\").id")
            
            if [ -z "${droplet_id}" ]; then 
                echo -e "Creating droplet okd-worker-${num}.\n"
                doctl compute droplet create "okd-worker-${num}" $common_options \
                    --tag-names "${ALL_DROPLETS_TAG},${WORKER_DROPLETS_TAG}" \
                    --size "${worker_droplet_size} " \
                    --user-data-file ./generated-files/worker-processed.ign >/dev/null
            else
                echo -e "\nDroplet okd-worker-${num} exists, verifying.\n"
                if [ -z $(doctl compute droplet list -o json | jq -r  ".[] | select(.id == ${droplet_id} and .image.id == ${image_id} and .size.slug == \"${worker_droplet_size}\").id") ]; then
                    echo -e "\nDroplet okd-worker-${num} exists, but is either has the wrong Image Id or does not match the size configured.\n"
                    exit 1
                fi
            fi
        done
    fi

}

create_load_balancer_if_not_exists() {

    load_balancer_id=$(doctl compute load-balancer list -o json | jq -r  ".[] | select(.name == \"${DOMAIN}\" and .region.slug == \"${DIGITAL_OCEAN_REGION}\" and .vpc_uuid == \"$(get_vpc_id)\").id")
    load_balancer_size=$(doctl compute load-balancer list -o json | jq -r  ".[] | select(.name == \"${DOMAIN}\" and .region.slug == \"${DIGITAL_OCEAN_REGION}\" and .vpc_uuid == \"$(get_vpc_id)\").size")
    
    check="protocol:tcp,port:6443,path:,check_interval_seconds:10,response_timeout_seconds:10,healthy_threshold:2,unhealthy_threshold:10"
    rules=''
    for port in 80 443 6443 22623; do
        rules+="entry_protocol:tcp,entry_port:${port},target_protocol:tcp,target_port:${port},certificate_id:,tls_passthrough:false "
    done
    rules="${rules:0:-1}" # pull off trailing space    

    if [ -z "$load_balancer_id" ]; then
        echo -e "\nCreating load-balancer.\n"
        # Create a load balancer that passes through port 80 443 6443 22623 traffic.
        # to all droplets tagged as control plane nodes.
        # https://www.digitalocean.com/community/tutorials/how-to-work-with-digitalocean-load-balancers-using-doctl

        doctl compute load-balancer create   \
            --name $DOMAIN                   \
            --region $DIGITAL_OCEAN_REGION   \
            --vpc-uuid $(get_vpc_id)         \
            --tag-name $CONTROL_DROPLETS_TAG \
            --health-check "${check}"        \
            --forwarding-rules "${rules}" >/dev/null
        # wait for load balancer to come up
        ip='null'
        while [ "${ip}" == 'null' ]; do
            echo "Waiting for load balancer to come up..."
            sleep 5
            ip=$(get_load_balancer_ip)
        done        
    else 
        echo -e "The load-balancer ${DOMAIN} exists, updating forwarding rules and health checks.\n"
        doctl compute load-balancer update ${load_balancer_id} \
            --name $DOMAIN \
            --region $DIGITAL_OCEAN_REGION   \
            --size $load_balancer_size \
            --tag-name $CONTROL_DROPLETS_TAG \
            --health-check "${check}"        \
            --forwarding-rules "${rules}" >/dev/null
    fi
}

get_load_balancer_id() {
    doctl compute load-balancer list -o json | \
        jq -r ".[] | select(.name == \"${DOMAIN}\").id"
}

get_load_balancer_ip() {
    doctl compute load-balancer list -o json | \
        jq -r ".[] | select(.name == \"${DOMAIN}\").ip"
}

create_firewall_if_not_exists() {
    firewall_id=$(doctl compute firewall list -o json | jq -r ".[] | select (.name =\"$DOMAIN\").id")

    # Allow anything from our VPC and all droplet to droplet traffic
    # even if it comes from a public interface
    iprange=$(get_vpc_ip_range)
    inboundrules="protocol:icmp,address:$iprange,tag:$ALL_DROPLETS_TAG "
    inboundrules+="protocol:tcp,ports:all,address:$iprange,tag:$ALL_DROPLETS_TAG "
    inboundrules+="protocol:udp,ports:all,address:$iprange,tag:$ALL_DROPLETS_TAG "
    # Allow tcp 22 80 443 6443 22623 from the public
    for port in 22 80 443 6443 22623; do
        inboundrules+="protocol:tcp,ports:${port},address:0.0.0.0/0,address:::/0 "
    done
    inboundrules="${inboundrules:0:-1}" # pull off trailing space

    # Allow all outbound traffic
    outboundrules='protocol:icmp,address:0.0.0.0/0,address:::/0 '
    outboundrules+='protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 '
    outboundrules+='protocol:udp,ports:all,address:0.0.0.0/0,address:::/0'

    if [ -z "${firewall_id}" ]; then
        echo -e "\nCreating firewall.\n"

        doctl compute firewall create           \
            --name $DOMAIN                      \
            --tag-names $ALL_DROPLETS_TAG       \
            --outbound-rules "${outboundrules}" \
            --inbound-rules "${inboundrules}" >/dev/null
    else
        echo -e "Firewall already exists, skipping creation.\n"        
    fi
}

get_firewall_id() {
    doctl compute firewall list -o json | \
        jq -r ".[] | select(.name == \"${DOMAIN}\").id"
}

create_vpc_if_not_exists() {

    vpc_id=$(doctl vpcs list -o json | jq -r  ".[] | select(.name == \"${DOMAIN}\" and .region == \"${DIGITAL_OCEAN_REGION}\").id")

    if [ -z "$vpc_id" ]; then
        echo -e "\nCreating VPC for private traffic.\n"
        doctl vpcs create --name $DOMAIN --region $DIGITAL_OCEAN_REGION >/dev/null
    else
        echo -e "\nThe VPC ${DOMAIN} already exists.\n"
    fi
}

get_vpc_id() {
    doctl vpcs list -o json | \
        jq -r ".[] | select(.name == \"${DOMAIN}\").id"
}

get_vpc_ip_range() {
    doctl vpcs list -o json | \
        jq -r ".[] | select(.name == \"${DOMAIN}\").ip_range"
}

create_domain_and_dns_records() {
    echo -e "\nCreating domain and DNS records.\n"
    # Create a domain in DO

    domain_id=$(doctl compute domain list -o json | jq -r  ".[] | select(.name == \"${DOMAIN}\").name")

    if [ -z $domain_id ]; then
        doctl compute domain create $DOMAIN >/dev/null
    fi

    # Set up some DNS records to point at our load balancer IP
    #
    # - Required for OpenShift
    #    -  oauth-openshift.apps.${DOMAIN}.
    #    -                *.apps.${DOMAIN}.
    #    -               api-int.${DOMAIN}.
    #    -                   api.${DOMAIN}.
    #
    ip=$(get_load_balancer_ip)
    for record in "api.${DOMAIN}."     \
                  "api-int.${DOMAIN}." \
                  "*.apps.${DOMAIN}."  \
                  "oauth-openshift.apps.${DOMAIN}.";
    do
        # Get just the non-domain portion of the entry so we can search for it.
        entry_name=$(sed "s/.${DOMAIN}.//" <<< "$record")

        # Get the id for the entry
        entry_data=$(doctl compute domain records list ${DOMAIN} -o json | jq -r  ".[] | select(.name == \"${entry_name}\").data")

        # If the entry doesn't already exist then create it
        if [ -z $entry_data ]; then 
            doctl compute domain records create $DOMAIN \
                --record-name $record \
                --record-type A       \
                --record-ttl 1800     \
                --record-data $ip >/dev/null
        else             
            if [ $entry_data != $ip ]; then 
                echo "The DNS record exists with an IP of $entry_data, setting it to $ip"
                entry_id=$(doctl compute domain records list ${DOMAIN} -o json | jq -r  ".[] | select(.name == \"${entry_name}\").id")
                # If the entry exists, make sure the ip is correct.
                doctl compute domain records update $DOMAIN \
                    --record-name $record \
                    --record-type A       \
                    --record-ttl 1800     \
                    --record-id $entry_id \
                    --record-data $ip >/dev/null            
            fi
        fi

    done

    # Also enter in required internal cluster IP SRV records:
    #    _service._proto.name.              TTL  class  SRV # priority weight  port    target.
    # -------------------------------------------------------------------------------------------------
    #   _etcd-server-ssl._tcp.${DOMAIN}.  86400   IN    SRV     0        10    2380    etcd-0.${DOMAIN}
    #   _etcd-server-ssl._tcp.${DOMAIN}.  86400   IN    SRV     0        10    2380    etcd-1.${DOMAIN}
    #   _etcd-server-ssl._tcp.${DOMAIN}.  86400   IN    SRV     0        10    2380    etcd-2.${DOMAIN}
    for num in $(control_plane_num_sequence); do

        entry_id=$(doctl compute domain records list ${DOMAIN} -o json | jq -r  ".[] | select(.name == \"_etcd-server-ssl._tcp\" and .data == \"etcd-${num}\").id")

        if [ -z "$entry_id" ]; then
            doctl compute domain records create $DOMAIN  \
                --record-name "_etcd-server-ssl._tcp.${DOMAIN}." \
                --record-type SRV      \
                --record-ttl 1800      \
                --record-priority 0    \
                --record-weight 10     \
                --record-port 2380     \
                --record-data "etcd-${num}.${DOMAIN}." >/dev/null
        fi
    done

    # Droplets should be up already. Set up DNS entries.

    # First for the control plane nodes:
    # Set up DNS etcd-{0,1,2..} records (required)
    # Set up DNS okd-control-{0,1,2..} records (optional/convenience)
    for num in $(control_plane_num_sequence); do
        id=$(doctl compute droplet list -o json | jq -r ".[] | select(.name == \"okd-control-${num}\").id")
        # Set DNS record with private IP
        ip=$(doctl compute droplet get $id -o json | jq -r '.[].networks.v4[] | select(.type == "private").ip_address')

        entry_id=$(doctl compute domain records list ${DOMAIN} -o json | jq -r  ".[] | select(.name == \"etcd-${num}\").id")
        
        if [ -z "$entry_id" ]; then
            doctl compute domain records create $DOMAIN \
                --record-name "etcd-${num}.${DOMAIN}." \
                --record-type A       \
                --record-ttl 1800     \
                --record-data $ip >/dev/null
        else 
            doctl compute domain records update $DOMAIN \
                --record-name "etcd-${num}" \
                --record-type A       \
                --record-ttl 1800     \
                --record-id $entry_id \
                --record-data $ip >/dev/null              
        fi

        # Set DNS record with public IP
        ip=$(doctl compute droplet get $id -o json | jq -r '.[].networks.v4[] | select(.type == "public").ip_address')

        entry_id=$(doctl compute domain records list ${DOMAIN} -o json | jq -r  ".[] | select(.name == \"okd-control-${num}\").id")

        if [ -z "$entry_id" ]; then
            doctl compute domain records create $DOMAIN \
                --record-name "okd-control-${num}.${DOMAIN}." \
                --record-type A       \
                --record-ttl 1800     \
                --record-data $ip >/dev/null
        else 
            doctl compute domain records update $DOMAIN \
                --record-name "okd-control-${num}" \
                --record-type A       \
                --record-ttl 1800     \
                --record-id $entry_id \
                --record-data $ip >/dev/null               
        fi
    done

    # Next, for the worker nodes:
    # Set up DNS okd-worker-{0,1,2..} records (optional/convenience)
    # Create worker nodes
    if have_workers; then
        for num in $(worker_num_sequence); do
            id=$(doctl compute droplet list -o json | jq -r ".[] | select(.name == \"okd-worker-${num}\").id")
            # Set DNS record with public IP
            ip=$(doctl compute droplet get $id -o json | jq -r '.[].networks.v4[] | select(.type == "public").ip_address')

            entry_id=$(doctl compute domain records list ${DOMAIN} -o json | jq -r  ".[] | select(.name == \"okd-worker-${num}\").id")
            if [ -z "$entry_id" ]; then
                doctl compute domain records create $DOMAIN \
                    --record-name "okd-worker-${num}.${DOMAIN}." \
                    --record-type A       \
                    --record-ttl 1800     \
                    --record-data $ip >/dev/null
            else
                doctl compute domain records update $DOMAIN \
                    --record-name "okd-worker-${num}" \
                    --record-type A       \
                    --record-ttl 1800     \
                    --record-id $entry_id \
                    --record-data $ip >/dev/null   
            fi
        done
    fi

    # Set up Let's Encrypt authority to issue certificates.
    letsencrypt_caa=$(doctl compute domain records list ${DOMAIN} -o json | jq -r  ".[] | select(.type == \"CAA\" and .name == \"@\" and .data == \"letsencrypt.org\" and .tag == \"issuewild\").id")

    if [ -z "$letsencrypt_caa" ]; then 
        doctl compute domain records create ${DOMAIN} \
        --record-name "@" \
        --record-type "CAA" \
        --record-tag issuewild \
        --record-ttl 3600 \
        --record-data "letsencrypt.org."
    fi

}



# https://github.com/digitalocean/csi-digitalocean
configure_DO_block_storage_driver() {
    echo -e "\nCreating DigitalOcean block storage driver.\n"
    # Create the secret that contains the DigitalOcean creds for volume creation
    oc create -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: digitalocean
  namespace: kube-system
stringData:
  access-token: "${DIGITAL_OCEAN_ACCESS_TOKEN}"
EOF

    # Deploy DO CSI storage provisioner
    DOCSIVERSION='2.1.1'
    oc apply -fhttps://raw.githubusercontent.com/digitalocean/csi-digitalocean/master/deploy/kubernetes/releases/csi-digitalocean-v${DOCSIVERSION}/{crds.yaml,driver.yaml,snapshot-controller.yaml} >/dev/null

    # Patch the statefulset for hostNetwork access so it will work in OKD
    # https://github.com/digitalocean/csi-digitalocean/issues/328
    PATCH='
    spec:
      template:
        spec:
          hostNetwork: true'
    oc patch statefulset/csi-do-controller -n kube-system --type merge -p "$PATCH" >/dev/null
}

configure_DO_S3_storage_driver(){
    echo -e "\nCreating DigitalOcean block storage driver.\n"
    # Create the secret that contains the DigitalOcean creds for volume creation
    oc create -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
    name: csi-s3-secret
    namespace: kube-system
stringData:
    accessKeyID: "${DIGITAL_OCEAN_SPACES_KEY}"
    secretAccessKey: "${DIGITAL_OCEAN_SPACES_SECRET}"
    endpoint: "https://${DIGITAL_OCEAN_REGION}.digitaloceanspaces.com"
    region: ""
    encryptionKey: ""
EOF
    # We are not using a version here because the last published version is not compatible with OKD 4.7, while the current master branch is.
    # CSI_S3_VERSION="1.1.1"
    oc apply -fhttps://raw.githubusercontent.com/ctrox/csi-s3/master/deploy/kubernetes/{provisioner.yaml,attacher.yaml,csi-s3.yaml} >/dev/null
                   
    oc create -f ./resources/storageclass.yaml

}

fixup_registry_storage() {
    echo -e "\nFixing the registry storage to use DigitalOcean volume.\n"
    # Set the registry to be managed.
    # Will cause it to try and create a PVC.
    PATCH='
    spec:
      managementState: Managed
      storage:
        pvc:
          claim:'
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge -p "$PATCH" >/dev/null

    # Update the image-registry deployment to not have a rolling update strategy
    # because it won't work with a RWO backing device.
    # https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/#use-strategic-merge-patch-to-update-a-deployment-using-the-retainkeys-strategy
    PATCH='
    spec:
      strategy:
        $retainKeys:
          - type
        type: Recreate'
    sleep 10 # wait a bit for image-registry deployment
    oc patch deployment image-registry -n openshift-image-registry -p "$PATCH" >/dev/null

    # scale the deployment down to 1 desired pod since the volume for
    # the registry can only be attached to one node at a time
    oc scale --replicas=1 deployment/image-registry -n openshift-image-registry >/dev/null

    # Replace the PVC with a RWO one (DO volumes only support RWO)
    oc delete pvc/image-registry-storage -n openshift-image-registry >/dev/null
    oc create -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: image-registry-storage
  namespace: openshift-image-registry
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ${REGISTRY_VOLUME_SIZE}Gi
  storageClassName: do-block-storage
EOF
}

# This is a hack to allow us to get away with only configuring
# one DigitalOcean load balancer. For now we direct the load
# balancer just at the control-plane nodes.
move_routers_to_control_plane() {
    echo -e "\nMove routers to control plane nodes.\n"

    while ! oc get ingresscontroller default -n openshift-ingress-operator &>/dev/null; do
        echo "Waiting for ingresscontroller to be created..."
        sleep 30
    done

    # Allow ingress routers to run on the control-plane nodes.
    # https://docs.openshift.com/container-platform/4.1/networking/ingress-operator.html#nw-ingress-controller-configuration-parameters_configuring-ingress
    PATCH='
    spec:
      nodePlacement:
       nodeSelector:
         matchLabels:
           beta.kubernetes.io/os: linux
           node-role.kubernetes.io/master: ""
       tolerations:
       - effect: "NoSchedule"
         operator: "Exists"'
    oc patch ingresscontroller default -n openshift-ingress-operator --type=merge -p "$PATCH" >/dev/null

    # Also make a router run on every control-plane
    PATCH="
    spec:
      replicas: ${NUM_OKD_CONTROL_PLANE}"
    oc patch ingresscontroller default -n openshift-ingress-operator --type=merge -p "$PATCH" >/dev/null
}

# https://docs.okd.io/latest/installing/installing_bare_metal/installing-bare-metal.html#installation-approve-csrs_installing-bare-metal
wait_and_approve_CSRs() {
    echo -e "\nApprove CSRs if needed.\n"

    # Some handy commands to run manually if needed
    # oc get csr -o json | jq -r '.items[] | select(.spec.username == "system:node:okd-worker-0")'
    # oc get csr -o json | jq -r '.items[] | select(.spec.username == "system:node:okd-worker-0").status'

    # CSR approval only needs to be done if we have workers
    if ! have_workers; then
        return 0
    fi

    # Wait for all requests for worker nodes to come in and approve them
    while true; do
        csrinfo=$(oc get csr -o json)
        echo "Approving all pending CSRs and waiting for remaining requests.."
        echo $csrinfo |                                              \
            jq -r '.items[] | select(.status == {}).metadata.name' | \
            xargs --no-run-if-empty oc adm certificate approve
        sleep 10
        csrinfo=$(oc get csr -o json) # refresh info
        for num in $(worker_num_sequence); do
            # If no CSR for this worker then continue
            exists=$(echo $csrinfo | jq -r ".items[] | select(.spec.username == \"system:node:okd-worker-${num}\").metadata.name")
            if [ ! $exists ]; then
                echo "CSR not yet requested for okd-worker-${num}. Continuing."
                continue 2 # continue the outer loop
            fi
            # If the CSR is not yet approved for this worker then continue
            statusfield=$(echo $csrinfo | jq -r ".items[] | select(.spec.username == \"system:node:okd-worker-${num}\").status")
            if [[ $statusfield == '{}' ]]; then
                echo "CSR not yet approved for okd-worker-${num}. Continuing."
                continue 2 # continue the outer loop
            fi
        done
        break # all expected CSRs have been approved
    done
}

remove() {
    confirm=""
    while [ -z "$confirm" ]; do
        read -p "All OKD resources will be removed, do you want to continue? (yes / no): " confirm
        
        confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')

        if [ "$confirm" != "no" ] && [ "$confirm" != "yes" ]; then
            confirm=""
            echo "Please respond with \"yes\" to continue or \"no\" to cancel."                    
        fi

        if [  "$confirm" = "no" ]; then
            exit 0
        fi

    done


    cat <<EOF
#########################################################
Deleting resources created for OKD. 
#########################################################
EOF
    set +e
    echo -e "\nDeleting Load Balancer."
    lbid=$(get_load_balancer_id)
    if [ ! -z "$lbid" ]; then
        doctl compute load-balancer delete $lbid --force
    fi

    echo -e "\nDeleting Firewall."
    fwid=$(get_firewall_id)
    
    if [ ! -z "$fwid" ]; then
        doctl compute firewall delete $fwid --force
    fi 

    echo -e "\nDeleting Domain and DNS entries."

    domainid=$(doctl compute domain list -o json | jq -r  ".[] | select(.name == \"${DOMAIN}\").name")
    if [ ! -z "$domainid" ]; then
        doctl compute domain delete $DOMAIN --force
    fi

    echo -e "\nDeleting Droplets."
    # Delete the control droplets
    doctl compute droplet delete --tag-name $CONTROL_DROPLETS_TAG --force
    
    # Delete the worker droplets
    doctl compute droplet delete --tag-name $WORKER_DROPLETS_TAG --force

    # Delete the bootstrap droplet if it exists
    droplet_id=$(doctl compute droplet list -o json | jq -r  ".[] | select(.name == \"bootstrap\" and .region.slug == \"${DIGITAL_OCEAN_REGION}\").id")
    if [ ! -z "$droplet_id" ]; then
        doctl compute droplet delete bootstrap --force >/dev/null
    fi
    

    echo -e "\nDeleting Spaces (S3) bucket and all contents."
    digital_ocean_host=${DIGITAL_OCEAN_REGION}.digitaloceanspaces.com
    digital_oceaon_host_bucket="%\(bucket\)s.${digital_ocean_host}"
    (s3cmd du -q --host=$digital_ocean_host --host-bucket=$digital_oceaon_host_bucket --secret_key=${DIGITAL_OCEAN_SPACES_SECRET} --access_key=${DIGITAL_OCEAN_SPACES_KEY} ${SPACES_BUCKET} 2>/dev/null)
    bucket_exists=$?
    
    if [ $bucket_exists = 0 ]; then
        aws --endpoint-url $SPACES_ENDPOINT s3 rb $SPACES_BUCKET --force
    fi

    sleep 20 # Allow droplets to get removed from the VPC
    echo -e "\nDeleting VPC."
    vpc_id=$(get_vpc_id)

    if [ ! -z "$vpc_id" ]; then
        vpc_not_in_use=$(doctl compute droplet list -o json | jq -r  ".[] | select(.vpc_uuid == \"$vpc_id\" ).name")

        if [ -z "$vpc_not_in_use" ]; then
            doctl vpcs delete $vpc_id --force
        else 
            echo "The VPC still has droplets associated with it and cannot be removed."
        fi
    fi

    echo -e "\nYOU WILL NEED TO MANUALLY DELETE ANY CREATED VOLUMES OR IMAGES"
    set -e
}

which() {
    (alias; declare -f) | /usr/bin/which --read-alias --read-functions --show-tilde --show-dot $@
}

check_requirement() {
    req=$1
    if ! which $req &>/dev/null; then
        echo "No $req. Can't continue" 1>&2
        return 1
    fi
}

cmdname=${0##*/}
usage()
{
    cat << EOS >&2
Usage:
    $cmdname
    -i | --install              Install OKD to Digital Ocean
    -k | --spaces-key           DigitalOcean Spaces Access Key    
    -r | --remove               Remove the OKD installation from Digital Ocean
    -s | --spaces-secret        DigitalOcean Spaces Access Secret    
    -t | --token                DigitalOcaen Personal Access Token    
    -h | --help                 Prints this help message
EOS
}

main() {

    # Check for required software
    reqs=(
        aws
        doctl
        kubectl
        oc
        openshift-install
        jq
        s3cmd
        yq
    )
    for req in ${reqs[@]}; do
        check_requirement $req
    done

    while (( "$#" )); do
        case "$1" in
            -i|--install)
                action_install=1
                shift           
            ;;  
            -k|--spaces-key) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  DIGITAL_OCEAN_SPACES_KEY=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing a DigitalOcean spaces aceess key value." >&2
                  exit 1
              fi
            ;;                         
            -r|--remove)
                action_remove=1
                shift
            ;;  
            -s|--spaces-secret) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  DIGITAL_OCEAN_SPACES_SECRET=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing a DigitalOcean spaces aceess key value." >&2
                  exit 1
              fi
            ;; 
            -t|--token) 
              if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
                  DIGITAL_OCEAN_ACCESS_TOKEN=$2
                  shift 2
              else
                  echo "Error: Argument for $1 is missing a DigitalOcean personal aceess token value." >&2
                  exit 1
              fi
            ;;                                      
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

    if [ $action_install = 1 ] && [ $action_remove = 1 ]; then
        echo "Only the -i (--install) or the -r (--remove) flag may be proided, setting both is not valid."
        exit 1
    fi
    
    if [ $action_install = 0 ] && [ $action_remove = 0 ]; then
        echo "Either the -i (--install) or the -r (--remove) flag must be proided."
        exit 1
    fi    

    # Check for required credentials
    get_do_spaces_key    
    get_do_spaces_secret
    get_do_access_token
    
    for v in DIGITAL_OCEAN_SPACES_KEY \
             DIGITAL_OCEAN_SPACES_SECRET \
             DIGITAL_OCEAN_ACCESS_TOKEN; do
        if [[ -z "${!v-}" ]]; then
            echo "You must set environment variable $v" >&2
            return 1
        fi
    done

    # These values are set because the aws utility expects them
    export AWS_ACCESS_KEY_ID=${DIGITAL_OCEAN_SPACES_KEY}
    export AWS_SECRET_ACCESS_KEY=${DIGITAL_OCEAN_SPACES_SECRET}

    # If we want to remove it all, then do that
    if [ $action_remove = 1 ]; then
        remove
        return 0
    elif [ $action_install = 1 ]; then 
        # Create the spaces bucket to hold the bulky bootstrap config
        # Doing it here tests early that the spaces access works before
        # we create other resources.
        
        # Check if the bucket exists by attempting to do a disk usage on it
        # An error code result is assumed to mean it does not exist.
        digital_ocean_host=${DIGITAL_OCEAN_REGION}.digitaloceanspaces.com
        digital_oceaon_host_bucket="%\(bucket\)s.${digital_ocean_host}"

        set +e
        (s3cmd du -q --host=$digital_ocean_host --host-bucket=$digital_oceaon_host_bucket --secret_key=${DIGITAL_OCEAN_SPACES_SECRET} --access_key=${DIGITAL_OCEAN_SPACES_KEY} ${SPACES_BUCKET} 2>/dev/null)
        bucket_exists=$?
        set -eu -o pipefail

        if [ $bucket_exists != 0 ]; then
            echo "Creating the tempoary S3 bucket ${SPACES_BUCKET}"
            s3cmd mb -q --host=$digital_ocean_host --host-bucket=$digital_oceaon_host_bucket --secret_key=${DIGITAL_OCEAN_SPACES_SECRET} --access_key=${DIGITAL_OCEAN_SPACES_KEY} ${SPACES_BUCKET}    
        fi
        
        # Create the image, load balancer, firewall, and VPC
        create_image_if_not_exists
        create_vpc_if_not_exists; sleep 20
        create_load_balancer_if_not_exists; sleep 20
        create_firewall_if_not_exists

        # Generate the ignition configs (places bootstrap config in spaces)
        generate_manifests

        # Create the droplets and wait some time for them to get assigned
        # addresses so that we can create dns records using those addresses
        create_droplets; sleep 20
        
        # Print IP information to the screen for the logs (informational)
        doctl compute droplet list | colrm 63

        # Create domain and dns records. Do it after droplet creation
        # because some entries are for dynamic addresses
        create_domain_and_dns_records

        # Wait for the bootstrap to complete
        echo -e "\nWaiting for bootstrap to complete.\n"
        openshift-install --dir=generated-files  wait-for bootstrap-complete

        # remove bootstrap node and config space as bootstrap is complete
        echo -e "\nRemoving bootstrap resources.\n"
        doctl compute droplet delete bootstrap --force >/dev/null
        aws --endpoint-url $SPACES_ENDPOINT s3 rb $SPACES_BUCKET --force >/dev/null

        # Set the KUBECONFIG so subsequent oc or kubectl commands can run
        export KUBECONFIG=${PWD}/generated-files/auth/kubeconfig

        # Wait for CSRs to come in and approve them before moving on
        wait_and_approve_CSRs

        # Move the routers to the control plane. This is a hack because
        # currently we only want to run one load balancer.
        move_routers_to_control_plane

        # Wait for the install to complete
        echo -e "\nWaiting for install to complete.\n"
        openshift-install --dir=generated-files  wait-for install-complete

        # Configure DO block storage driver
        # NOTE: this will store your API token in your cluster
        configure_DO_block_storage_driver

        # Configure DO S3 storage driver    
        configure_DO_S3_storage_driver

        # Configure the registry to use a separate volume created
        # by the DO block storage driver
        fixup_registry_storage

        # Copy the generated credentials to the current user's home
        /usr/bin/cp -f generated-files/auth/kubeconfig ~/.kube/config
    fi
}

get_do_spaces_key() {
    while [ -z "$DIGITAL_OCEAN_SPACES_KEY" ]; do
        read -p "Enter the Digital Ocean Spaces Access Key: " DIGITAL_OCEAN_SPACES_KEY

        if [ -z "$DIGITAL_OCEAN_SPACES_KEY" ]; then
            printf "\nA Digital Ocean Spaces Access Key is required.\n"
        fi
    done
}

get_do_spaces_secret() {
    while [ -z "$DIGITAL_OCEAN_SPACES_SECRET" ]; do
        read -s -p "Enter the Digital Ocean Spaces Secret: " DIGITAL_OCEAN_SPACES_SECRET

        if [ -z "$DIGITAL_OCEAN_SPACES_SECRET" ]; then
            printf "\nA Digital Ocean Spaces Secret is required.\n"
        fi
    done   
    echo "" 
}

get_do_access_token() {
    while [ -z "$DIGITAL_OCEAN_ACCESS_TOKEN" ]; do
        read -s -p "Enter the Digital Ocean Personal Access Token: " DIGITAL_OCEAN_ACCESS_TOKEN

        if [ -z "$DIGITAL_OCEAN_ACCESS_TOKEN" ]; then
            printf "\nA Digital Ocean Personal Access Token is required.\n"
        fi
    done
    echo "" 
}



main $@
if [ $? -ne 0 ]; then
    exit 1
else
    exit 0
fi
