#!/bin/bash
#
# Script to create a CGU with all the NonCompliant policies in a given cluster

# Check if we're in mgmt1
oc whoami --show-server |grep preprod1-ocp-mgmt &>/dev/null
if [ $? -eq 1 ]; then
  echo "Log in Management cluster before running this script"
  exit
fi

# Read cluster name
cluster=${1:-"none"}

if [ ${cluster} == "none" ]; then
  echo "ERROR: You must provide a cluster name"
  exit
fi

# Validate if cluster name is a valid name
oc get clusterdeployment -n ${cluster} ${cluster} &>/dev/null
if [ $? -eq 1 ]; then
  echo "ERROR: The provided cluster name is not a valid cluster"
  exit
fi

# Delete current CGU for ${cluster}
oc delete clustergroupupgrade -n ztp-install ${cluster} &>/dev/null

# Get NonCompliant policies
# TODO: it could be improved by checking the status field
policies=$(oc get --no-headers \
                  -n ztp-policy \
                  policies.policy.open-cluster-management.io \
                  --sort-by=".metadata.annotations.ran\.openshift\.io/ztp-deploy-wave" \
                  -o jsonpath='{range .items[*]}{@.metadata.name},{@.status.compliant},{range .status.status[*]}{.clustername}={.compliant};{end}{"\n"}{end}' \
                  | grep "${cluster}=NonCompliant" \
                  | awk -F, '{ print "  - "$1 }')

# Create a new CGU with the latest policies
dry_run=${2:-""}

cat <<EOF | oc apply -o yaml ${dry_run} -f -
apiVersion: ran.openshift.io/v1alpha1
kind: ClusterGroupUpgrade
metadata:
  finalizers:
  - ran.openshift.io/cleanup-finalizer
  name: ${cluster}
  namespace: ztp-install
spec:
  actions:
    afterCompletion:
      addClusterLabels:
        ztp-done: ""
      deleteClusterLabels:
        ztp-running: ""
      deleteObjects: true
    beforeEnable:
      addClusterLabels:
        ztp-running: ""
  backup: false
  clusters:
  - ${cluster}
  enable: true
  managedPolicies:
${policies}
  preCaching: false
  remediationStrategy:
    maxConcurrency: 5
EOF
