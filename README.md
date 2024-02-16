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
The ssh command will look something like this: `ssh ubuntu@<publicNodeIP> -i ~/.ssh/id_rsa` (change the private key file if required)

### Slides

The slides for the Talk are available here

### What are we trying to do

The above steps will bring the infrastructure to the state where we want to start exploring the k8s setup.
The main object for us is to run this command:

`kubectl run nginx --image=nginx --restart=Never`

We will do as many changes as required to get the above pod running on our node.

### First error

```shell
$ kubectl run nginx --image=nginx --restart=Never
The connection to the server 10.0.143.142:6443 was refused - did you specify the right host or port?
```

The kubectl is clearly trying to connect to port 6443 on given IP. The ip is of the private IP of the host machine.
What is the kubectl is trying to connect to. 

Running the kubectl command with verbose mode

```shell
$ kubectl run nginx --image=nginx --restart=Never -v=9
...
curl -v -XGET  -H "Accept: application/json, */*" -H "User-Agent: kubectl/v1.24.17 (linux/amd64) kubernetes/22a9682" 'https://10.0.143.142:6443/api?timeout=32s'
...
```
The kubectl is trying to reach the /api for application running on port 6443 on localhost.
The connection is reduced for this curl request. Clearly no application is running on 6443. 

You can check services on various ports running using command `sudo lsof -i`

So which component in k8s architecture provide the /api endpoint?

Its the `Kubernetes API server`. That is the component that is missing and the one we need to install. 

### Setting up the kubernetes API server

Since we are using the kubeadm to setup the cluster. We can check if there are any command that allows will allow us to setup kubernetes API server.
Here is the link to the Kubeadm documentation for init process: https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init-phase/

Since its the API server that is missing, we will just setup that and proceed to check if the pod works for us. 

```shell
$ sudo kubeadm init phase control-plane apiserver --v=9 --config kubeadm-config.yaml
...
[control-plane] Creating static Pod manifest for "kube-apiserver"
...
[control-plane] wrote static Pod manifest for component "kube-apiserver" to "/etc/kubernetes/manifests/kube-apiserver.yaml"
```
Important lines are shown above.

### Static pods

Kubernetes uses the concept of a Static pod to run the kubernetes components. Simply put, the Static pods are the one 
which are directly managed by the Kubelet service on that node. 

Static pods is what allows kubernetes to run its own Components as Pods.

Here are more details about static pods from the kubernetes documentation: https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/

#### How the static pods deployed

As mentioned static pods are managed by the Kubelet service running on the node. The Kubelet looks at a manifest directory. 
This is generally, `/etc/kubernetes/manifests/`. The static pod details are provided as an yaml file called as pod manifest.

Kubelet reads any new files from this directory and schedule them. It will also pick up changes to the files and make appropriate changes. 

See the [slides](#slides) for diagram on how Kubelet and Static Pods works.  

### Second Error

API server is still not accessible. 

If we look at the containers created using `docker ps`

```shell
$ sudo docker ps -a
CONTAINER ID   IMAGE                       COMMAND                  CREATED         STATUS                     PORTS     NAMES
9c57c04cbcea   4f1c5007cffa                "kube-apiserver --ad…"   4 minutes ago   Exited (1) 3 minutes ago             k8s_kube-apiserver_kube-apiserver-ip-10-0-143-142_kube-system_ba80a88393c91300a1debc5ee0c67a52_234
89bde7290d11   registry.k8s.io/pause:3.9   "/pause"                 20 hours ago    Up 20 hours                          k8s_POD_kube-apiserver-ip-10-0-143-142_kube-system_ba80a88393c91300a1debc5ee0c67a52_0
```
We can see the kube-api server is exited 3 min ago.

Looking at the container logs it fails with `connection error: desc = "transport: Error while dialing dial tcp 127.0.0.1:2379: connect: connection refused". Reconnecting...`

```shell
$ sudo docker logs 9c57c04cbcea
...
W0215 10:33:27.829563       1 clientconn.go:1331] [core] grpc: addrConn.createTransport failed to connect to {127.0.0.1:2379 127.0.0.1 <nil> 0 <nil>}. Err: connection error: desc = "transport: Error while dialing dial tcp 127.0.0.1:2379: connect: connection refused". Reconnecting...
...
```

The API server is trying to connect to an application on localhost (127.0.0.1) on port 2379.

Which component runs on port 2379. API server is trying to connect to etcd db. 

### Setting up ETCD database

Looking at the Kubeadm phases again. We can see etcd phase.

```shell
$ sudo kubeadm init phase etcd local --v=9 --config kubeadm-config.yaml
...
[etcd] Creating static Pod manifest for local etcd in "/etc/kubernetes/manifests"
I0215 10:43:43.449033   15858 local.go:65] [etcd] wrote Static Pod manifest for a local etcd member to "/etc/kubernetes/manifests/etcd.yaml"
```

Same approach is done for etcd deployment. 

If we now try and see if the API is up and etcd pods are up we can see both containers running

```shell
$ sudo docker ps
CONTAINER ID   IMAGE                       COMMAND                  CREATED         STATUS         PORTS     NAMES
ad9d8ae9bf08   4f1c5007cffa                "kube-apiserver --ad…"   4 minutes ago   Up 4 minutes             k8s_kube-apiserver_kube-apiserver-ip-10-0-143-142_kube-system_ba80a88393c91300a1debc5ee0c67a52_236
5c4227d130e9   fce326961ae2                "etcd --advertise-cl…"   4 minutes ago   Up 4 minutes             k8s_etcd_etcd-ip-10-0-143-142_kube-system_3694ec52414a8e6f0854682e9e51cd46_0
d1aae5728ffc   registry.k8s.io/pause:3.9   "/pause"                 4 minutes ago   Up 4 minutes             k8s_POD_etcd-ip-10-0-143-142_kube-system_3694ec52414a8e6f0854682e9e51cd46_0
89bde7290d11   registry.k8s.io/pause:3.9   "/pause"                 20 hours ago    Up 20 hours              k8s_POD_kube-apiserver-ip-10-0-143-142_kube-system_ba80a88393c91300a1debc5ee0c67a52_0
```

Looking to see if Kubectl works for us now. 

```shell
$ kubectl get pods --all-namespaces
NAMESPACE     NAME                             READY   STATUS    RESTARTS          AGE
kube-system   etcd-ip-10-0-143-142             1/1     Running   0                 3m4s
kube-system   kube-apiserver-ip-10-0-143-142   1/1     Running   236 (9m15s ago)   3m
```
The reason get pods command works is that the API server is now up and running.

### Third error

Executing the original command to see if we can run a pod on this cluster

```shell
$ kubectl run nginx --image=nginx --restart=Never
Error from server (Forbidden): pods "nginx" is forbidden: error looking up service account default/default: serviceaccount "default" not found
```

Looking at service accounts
```shell
$ kubectl get sa
No resources found in default namespace.
```

It's now failing for not having the serviceaccount 'default' in the default namespace. For the pod to be created we will need service account 'default' to be created. 

Which k8s components actual create the service account 'default' in various namespaces?

### Setting up the controller manager

The k8s controller manager is responsible for service account creation (it's responsible for a lot of other things as well). 
Deploying the controller manager should auto create the service account for us.

Looking at the kubeadm documentation the controller manager, the controller manager can be deployed as
```shell
$ sudo kubeadm init phase control-plane controller-manager --v=9 --config kubeadm-config.yaml
...
[control-plane] Creating static Pod manifest for "kube-controller-manager"
...
I0215 11:01:29.512056   16269 manifests.go:154] [control-plane] wrote static Pod manifest for component "kube-controller-manager" to "/etc/kubernetes/manifests/kube-controller-manager.yaml"
```

Let's look at if SA is created for us by the controller manager. 

```shell
$ kubectl get sa
NAME      SECRETS   AGE
default   0         2m26s
```

### (Detour) What else k8s controller manager do

Controller manager is collection of many Controllers in kubernetes.

Looking at controller manager documentation its consist of lot independent Controllers bundled as single deployable.

https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/#:~:text=%2D%2D-,controllers%20strings,-Default%3A%20%22*%22

We will come back to controllers later. 

### Back to the pod 

This should allow us to create the pod.

```shell
$ kubectl run nginx --image=nginx --restart=Never
pod/nginx created
```

Yay!! the pod is now created. Let's look at the pod status. 
 
```shell
$ kubectl get pods
NAME    READY   STATUS    RESTARTS   AGE
nginx   0/1     Pending   0          26s
```

The pod is now created. But it remains in pending state. 

### Lets look inside Etcd

To connect to etcd we need etcdctl to get the access etcd server. 

#### Install etcdctl 

```shell
$ curl -LO https://github.com/etcd-io/etcd/releases/download/v3.5.12/etcd-v3.5.12-linux-amd64.tar.gz
$ tar -xvf etcd-v3.5.12-linux-amd64.tar.gz
$ cd etcd-v3.5.12-linux-amd64
$ ./etcdctl --help
```
This should make the etcdctl available on the node. 

#### Getting values from the etcd cluster

ETCDCTL_API=3 etcdctl --endpoints 10.0.139.27:2379 --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key get / --prefix --keys-only

### Solving the pending pod

Looking at the pod, it not show any errors or any events at all. 

```shell
$ kubectl describe pod nginx
Name:         nginx
Namespace:    default
Priority:     0
Node:         <none>
Labels:       run=nginx
Annotations:  <none>
Status:       Pending
IP:
IPs:          <none>
Containers:
  nginx:
    Image:        nginx
    Port:         <none>
    Host Port:    <none>
    Environment:  <none>
    Mounts:
      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-69sz4 (ro)
Volumes:
  kube-api-access-69sz4:
    Type:                    Projected (a volume that contains injected data from multiple sources)
    TokenExpirationSeconds:  3607
    ConfigMapName:           kube-root-ca.crt
    ConfigMapOptional:       <nil>
    DownwardAPI:             true
QoS Class:                   BestEffort
Node-Selectors:              <none>
Tolerations:                 node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
Events:                      <none>
```
No events or error means kubernetes it not even trying to run this pod.

Looking at the node attribute, it's not populated. So not even a node is allocated to the pod.

Which component assigns pod to a node?

It's the job for kubernetes scheduler. 

### Setup Kubernetes scheduler

Install scheduler with kubeadm command

```shell
$ sudo kubeadm init phase control-plane scheduler --v=9 --config kubeadm-config.yaml
```

### Network Not ready 

Install calico

```shell
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml


sudo kubeadm init phase addon kube-proxy --v=9 --config kubeadm-config.yaml
```

### Kubernetes controller





