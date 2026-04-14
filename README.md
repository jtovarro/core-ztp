# Implementation Guide for CWL Clusters

Follow the instructions below to deploy a CWL cluster using a GitOps based ZTP approach.

## Pre Requisites

Before starting the deployment of the CWL cluster via GitOps based ZTP, certain prerequisites need to be in place. The first list of prerequisites below must have already been configured on the MGMT cluster as part of the MGMT cluster configuration by the validated patterns operator based GitOps procedure. The items are being listed here for completion and to ensure that these were actually configured by the validated pattern:

* The management cluster needs to be installed and configured
* Quay is installed in the MGMT cluster
* RHACM / MCE / CIM in the MGMT cluster needs to be configured. Following are some of the configurations that are needed for RHACM/MCE to be ready:
  * Ensure that the provisioning CR is patched to watch all namespaces
  * Ensure that a secret with the appropriate pull-secret credentials has been created in the multicluster-engine namespace. This pull-secret should have the credentials for both Quay instances (MGMT1 and MGMT2) in additional to the regular credentials that make up the pull-secret
  * Ensure that a config map has been created in the multicluster-engine namespace which includes the ca-bundle certificates for both Quay instances as well as the mirror definitions for the platform installation images
* AgentServiceConfig CR has been created and it points to the mirror registry config map created in the previous step
* An ArgoCD instance for ZTP of the workload clusters has been created

The following prerequisites are not taken care of by the validated pattern and need to be implemented before the CWL cluster can be deployed:

* Quay is installed in the MGMT cluster and all the needed images (OCP platform and cluster operators) have been uploaded to Quay
  * Images need to have been uploaded to both Quay instances (MGMT1 and MGMT2)
  * Keep track of the imageContentSourcePolicy file that was generated when the images were pushed to both Quay instances
* Edit the proxy configuration on the MGMT cluster to add the machineNet CIDR and domain name for the new CWL cluster to the "noProxy" list. The IPMI CIDR for CWL also needs to be included in the "noProxy" list.
* Create an `ClusterImageSet` CR to define the URL for the release image of the OCP version that needs to be installed on the CWL cluster
* Edit the MGMT cluster image service CR to define the Quay certificates as `additionalTrustedCA`. Also add the MGMT cluster domain to the `insecureRegistries` list.
* Define the secrets that will be used by ArgoCD to access the GIT repositories for `clusterInstance` and `policyGenTemplates`.
  * These secrets need to be defined in the namespace of the argoCD instance that has been created for workload cluster ZTP
* Create argoCD applications for the clusterInstance GIT repository as well as for the policyGenTemplate repository

[NOTE]
As soon as the argoCD app for clusterInstance and policyGenTemplate is created and ArgoCD syncs with GIT, it will start to create the clusters that are defined in the kustomization file of clusteInstance and to create the policies that are defined in the policyGenTemplate GIT repository. Ensure that those kustomization files have the correct values before creating the argoCD applications.

## WorkLoad Cluster Deployment via GitOps

Once all the prerequisites have been met, the MGMT cluster is ready to be used to deploy workload clusters via ZTP. The following steps need to be completed in order to deploy a cluster:

* Create a `clusterInstance` CR for the new workload cluster
* Add the `clusterInstance` CR to the kustomization file of the `clusterInstance` GIT repository
* Commit the changes to GIT

The section below provides a high level description of a `clusterInstance` CR.

### Cluster / clusterInstance (previously siteConfig)

Create / Edit the following files to describe the managed clusters that need to be deployed via ZTP:

* clusters/site-name.yaml - Manifest of this CR include the following information:
  * Cluster name, domain, type (compact, sno etc.) , and cluster-labels. The cluster-labels are used later to determine the type of policies that should be applied to the cluster
  * Cluster’s networking details such as CNI type, machine config pool, cluster networking CIDR, service network CIDR, and IP addresses for the cluster’s nodes.
  * Ssh public key that can be used to login to the cluster nodes.
  * BMC access details for each of the cluster nodes, as well as the boot device (disk) that should be used on each node.
  * Role of each node, in case of multiple nodes cluster.
  * Interface configuration for each of the nodes, this includes any bond interface configuration LACP parameters that should be used, and any bridges or vlans that should be configured (on the Multus network).
  * Routing information (default route) that the nodes should use.
  * DNS server that the cluster nodes should be using
  * Name of secrets that would be required to access BMC or to download images from repositories (pull secret)
  * Information about image sources that the disconnected cluster can use, i.e. catalogSources and ImageContentSourcePolicy, providing mapping between public URLs to the privately hosted repository on the Management Cluster.
  * This information from clusteInstance manifest is then used, by the GitOps operator, to generate the specific manifests that are then used for deploying the cluster.
* clusters/resources/site_secrets.yaml
  * Create a yaml file to describe the different secrets for each managed cluster. These secrets include the pull secret for the cluster as well as the BMH credentials to access the cluster nodes
* clusters/user-manifest/\*.yaml
  * Edit the `IDMS` file(s) to reflect the mirroring configuration for disconnected clusters
* clusters/kustomization.yaml
  * Include the clusteInstance and site secrets YAML files

#### Validating clusteInstance files

There is a good way to validate your clusteInstance and policygen templates: 

Generate CRs from clusteInstance file:
```
podman run --rm --log-driver=none -v ./siteconfig:/resources:Z,U registry.redhat.io/openshift4/ztp-site-generate-rhel8:v4.18.1-1 generator install .

Console Output:
/resources/kustomization.yaml does not have clusteInstance CR. Skipping...
Processing clusteInstances: /resources/cwl-site1.yaml 
Generating installation CRs into /resources/out/generated_installCRs ...

```
If the clusteInstance file is valid, then the CRs generated will be in `siteconfig/out/generated_installCRs` directory. 

### PolicyGenTemplate 
Manifest for the PolicyGenTemplate (PGT) define the following parameters:

* A binding rule that is matched against the cluster-label used during the cluster installation. The clusters with the matching label are considered to be target clusters for the policy defined in the PGT
* A namespace that will be used by the rendered policy. The PGT results in three manifests being rendered with the resource type : “Policy”, “PlaceBinding”, & “PlacementRule”. These are stored in the identified namespace. Note that this namespace is also created by the GitOps operator using a separate manifest that contains only the namespace parameters.  

[NOTE]
The name of this namespace must start with “ztp-”.

* The source files for the policies to be applied. Multiple source files can be grouped together by giving them the same “Policy Name”. The fileName is the actual manifest that includes the details of what this particular policy should implement. This would contain CRs that Openshift is able to interpret. There are multiple such source files that are already provided within the ZTP Container, and can be used as-is, or their values can be overridden by specifying only those values in addition to the file’s name. 

### Notes about Waves
The policies include an annotation (ran.openshift.io/ztp-deploy-wave) to detail on which order they must be applied. Here's a quick reference about which wave must be used:

1 - 9: Used for policies that don't colide between them and are basic for the cluster.
10 - 19: Used for policies that install operators: create namespaces, operatorgroups, subscriptions, secrets, etc.
20 - 29: Used for policies that use the previously installed operators: create secrets in namespaces, create instances of CRs installed by operators, etc.
30 - 39: Used for policies that require persistent volumes created using ODF, like Quay and/or Virtual Machines
40 - 49: Used for policies that deploy OpenStack Overcloud

## Authors
Paulo Pacifico <ppacific@redhat.com>
Juan Carlos Tovar <jtovarro@redhat.com>