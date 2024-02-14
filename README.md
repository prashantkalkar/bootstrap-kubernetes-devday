### bootstrap-kubernetes-devday
Repository to contain setup code for bootstrap kubernetes devday talk. 

### Setup details

The repo contains the terraform code under the k8s_node directory. The terraform code create a single EC2 instance along 
with required IAM role and security for the instance. 

Terraform will also execute the instance setup script during the instance provisioning (using remote provisioners).

The script configure the following packages for the instance: 

1. Docker Engine
2. Docker CRI Shrim (cri-dockerd)
3. Kubelet v1.24.0 (as systemd service)
4. Kubeadm v1.24.0
5. Kubectl v1.24.0

That means all of the above are already installed.

We are using kubeadm tool to setup the k8s node. The kubectl is configured to talk with the cluster (using kubeadm phase called kubeconfig). 

Few of the kubeadm steps are already completed during this setup mainly following phases are already executed.

```shell
sudo kubeadm init phase preflight --v=5 --config kubeadm-config.yaml
sudo kubeadm init phase certs all --v=5 --config kubeadm-config.yaml
sudo kubeadm init phase kubeconfig all --v=5 --config kubeadm-config.yaml
sudo kubeadm init phase kubelet-start --v=5 --config kubeadm-config.yaml
sudo kubeadm init phase kubelet-finalize all --v=5 --config kubeadm-config.yaml
```
As can be seen there is a `kubeadm-config.yaml` file. Which provides kubeadm configuration to point to correct cri-socket 
for CRI and also provide the podCidr range. 

### Performing the setup

Ensure you are pointing to correct AWS account. 

Create `terraform.tfvars` in k8s_node directory with following variables, provide appropriate values
```
person_name="<name>"
public_subnet_id="<instance_subnet>"
vpc_name="<instance_vpc>"
```
You can also provide value for `keypair_pub_file` is not using the default value of `~/.ssh/id_rsa.pub`

```shell
cd k8s_node
terraform init
terraform plan -out tfplan
``` 

Verify the plan. Once done, apply the changes. 

```shell
terraform apply tfplan
```
The terraform output should provide the details of how to ssh into the instance. In case the private file name is incorrect please correct it. 
The ssh command will look something like this: `ssh ubuntu@65.0.93.158 -i ~/.ssh/id_rsa` (change the private key file if required)

### What are we trying to do

The above steps will bring the infrastructure to the state where we want to start exploring the k8s setup.
The main object for us is to run this command:

`kubectl run nginx --image=nginx --restart=Never`

We will do as many changes as required to get the above pod running on our node.

### First error


