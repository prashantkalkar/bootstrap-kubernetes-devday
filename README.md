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

Create `terraform.auto.tfvars` in k8s_node directory with following variables, provide appropriate values
```
person_name="<name>"
public_subnet_id="<instance_subnet>"
vpc_name="<instance_vpc_name>"
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

### Video

The recorded video of this talk is available here: https://www.youtube.com/watch?v=vTGry6GKo_k

### What are we trying to do

The above steps will bring the infrastructure to the state where we want to start exploring the k8s setup.
The main object for us is to run this command:

```shell
kubectl run nginx --image=nginx --restart=Never
```

We will do as many changes as required to get the above pod running on our node.

### First error

```shell
$ kubectl run nginx --image=nginx --restart=Never
The connection to the server 10.0.136.21:6443 was refused - did you specify the right host or port?
```

The kubectl is clearly trying to connect to port 6443 on given IP. The ip is of the private IP of the host machine.
What is the kubectl is trying to connect to. 

Running the kubectl command with verbose mode

```shell
$ kubectl run nginx --image=nginx --restart=Never -v=9
...
curl -v -XGET  -H "Accept: application/json, */*" -H "User-Agent: kubectl/v1.24.17 (linux/amd64) kubernetes/22a9682" 'https://10.0.136.21:6443/api?timeout=32s'
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
This is generally, `/etc/kubernetes/manifests/`. The static pod details are provided as a yaml file called as pod manifest.

Kubelet reads any new files from this directory and schedule them. It will also pick up changes to the files and make appropriate changes.

In this case, the kubeadm is generating the static pod manifest (yaml file) in the manifest directory that kubelet is watching. 
This is done as part of the api-server deployment command.  

See the [slides](#slides) for diagram on how Kubelet and Static Pods works.  

### Second Error

Let's try to see if we can connect to the api server now. 

```shell
$ kubectl get pods
The connection to the server 10.0.136.21:6443 was refused - did you specify the right host or port?
```
API server is still not accessible. 

If we look at the containers created using `docker ps`

```shell
$ sudo docker ps -a
CONTAINER ID   IMAGE                       COMMAND                  CREATED          STATUS                      PORTS     NAMES
2736ade11385   4f1c5007cffa                "kube-apiserver --ad…"   38 seconds ago   Exited (1) 17 seconds ago             k8s_kube-apiserver_kube-apiserver-ip-10-0-136-21_kube-system_e38ea624e8485701ac1fecf4714144c4_6
671e396334a0   registry.k8s.io/pause:3.9   "/pause"                 8 minutes ago    Up 8 minutes                          k8s_POD_kube-apiserver-ip-10-0-136-21_kube-system_e38ea624e8485701ac1fecf4714144c4_0
```
We can see the kube-api server is exited 17 seconds ago.

Looking at the container logs it fails with `connection error: desc = "transport: Error while dialing dial tcp 127.0.0.1:2379: connect: connection refused". Reconnecting...`

```shell
$ sudo docker logs 2736ade1138
...
W0216 07:19:46.916140       1 clientconn.go:1331] [core] grpc: addrConn.createTransport failed to connect to {127.0.0.1:2379 127.0.0.1 <nil> 0 <nil>}. Err: connection error: desc = "transport: Error while dialing dial tcp 127.0.0.1:2379: connect: connection refused". Reconnecting...
...
```

The API server is trying to connect to an application on localhost (127.0.0.1) on port 2379.

Which component runs on port 2379. 
API server requires a database to store the data like pods, deployments created etc. 
Kubernetes API server uses the databased called `etcd`. API server is failing to connect to etcd db on port 2379.
This is because the etcd db is missing and is not installed. 

So let's install etcd db to fix the issue. 

### Setting up ETCD database

Looking at the Kubeadm phases again. We can see etcd phase.

```shell
$ sudo kubeadm init phase etcd local --v=9 --config kubeadm-config.yaml
...
[etcd] Creating static Pod manifest for local etcd in "/etc/kubernetes/manifests"
I0216 07:24:08.216398    9828 local.go:65] [etcd] wrote Static Pod manifest for a local etcd member to "/etc/kubernetes/manifests/etcd.yaml"
```

Same approach of static pods is followed here for etcd deployment. 

If we now try and see if the API is up and etcd pods are up we can see both containers running

```shell
$ sudo docker ps
CONTAINER ID   IMAGE                       COMMAND                  CREATED              STATUS              PORTS     NAMES
cb0bc9c654b4   4f1c5007cffa                "kube-apiserver --ad…"   27 seconds ago       Up 26 seconds                 k8s_kube-apiserver_kube-apiserver-ip-10-0-136-21_kube-system_e38ea624e8485701ac1fecf4714144c4_7
21270d18d7a1   fce326961ae2                "etcd --advertise-cl…"   About a minute ago   Up About a minute             k8s_etcd_etcd-ip-10-0-136-21_kube-system_84a39450e394445fcf67db137858efb3_0
51d024d6cfb9   registry.k8s.io/pause:3.9   "/pause"                 About a minute ago   Up About a minute             k8s_POD_etcd-ip-10-0-136-21_kube-system_84a39450e394445fcf67db137858efb3_0
671e396334a0   registry.k8s.io/pause:3.9   "/pause"                 13 minutes ago       Up 13 minutes                 k8s_POD_kube-apiserver-ip-10-0-136-21_kube-system_e38ea624e8485701ac1fecf4714144c4_0
```
As can be seen the apiserver container seems to be Up since 26 seconds (first entry).

Looking to see if Kubectl works for us now. 

```shell
$ kubectl get pods --all-namespaces
NAMESPACE     NAME                            READY   STATUS    RESTARTS        AGE
kube-system   etcd-ip-10-0-136-21             1/1     Running   0               3m28s
kube-system   kube-apiserver-ip-10-0-136-21   1/1     Running   7 (8m56s ago)   3m35s
```

The reason get pods command works is that the API server is now up and running.

### Third error

Executing the original command to see if we can run a pod on this cluster

```shell
$ kubectl run nginx --image=nginx --restart=Never
Error from server (Forbidden): pods "nginx" is forbidden: error looking up service account default/default: serviceaccount "default" not found
```

Pod creation is still failing. The main error is 'default' service account (sa) is not found in the default namespace (default/default is namespace/sa-name)

Listing the service accounts, we can see that is missing. 

```shell
$ kubectl get sa
No resources found in default namespace.
```
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
I0216 07:40:32.691500   10276 manifests.go:154] [control-plane] wrote static Pod manifest for component "kube-controller-manager" to "/etc/kubernetes/manifests/kube-controller-manager.yaml"
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

Few interesting controllers can be
deployment-controller - responsible for creating/updating deployments
daemonset-controller - responsible for creating/updating daemonsets
etc

For default SA creation, serviceaccount-controller must be responsible.  

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

We can look inside etcd for our newly created pod. 

To connect to etcd we need etcdctl to get the access etcd server. 

#### Install etcdctl 

```shell
$ curl -LO https://github.com/etcd-io/etcd/releases/download/v3.5.12/etcd-v3.5.12-linux-amd64.tar.gz
$ tar -xvf etcd-v3.5.12-linux-amd64.tar.gz
$ etcd-v3.5.12-linux-amd64/etcdctl --help
```
This should make the etcdctl available on the node. 

#### Get the Etcd endpoint ip and port

We should be able to find out the etcd endpoint (where it accepts the client traffic)
so that we can use etcdctl to connect to our etcd.

```shell
$ kubectl get pods -n kube-system
NAME                                     READY   STATUS    RESTARTS      AGE
etcd-ip-10-0-136-21                      1/1     Running   0             22m
kube-apiserver-ip-10-0-136-21            1/1     Running   7 (27m ago)   22m
kube-controller-manager-ip-10-0-136-21   1/1     Running   0             7m9s
$ kubectl describe pod etcd-ip-10-0-136-21 -n kube-system
...
    Command:
      etcd
      --advertise-client-urls=https://10.0.136.21:2379
      --cert-file=/etc/kubernetes/pki/etcd/server.crt
...
```
We can use the advertised client url for etcdctl to connect to. 
In this case it is 10.0.136.21:2379 

#### Getting values from the etcd cluster

```shell
$ ETCDCTL_API=3 sudo etcd-v3.5.12-linux-amd64/etcdctl --endpoints 10.0.136.21:2379 --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key get / --prefix --keys-only
/registry/apiregistration.k8s.io/apiservices/v1.

/registry/apiregistration.k8s.io/apiservices/v1.admissionregistration.k8s.io

/registry/apiregistration.k8s.io/apiservices/v1.apiextensions.k8s.io

/registry/apiregistration.k8s.io/apiservices/v1.apps

/registry/apiregistration.k8s.io/apiservices/v1.authentication.k8s.io
```
This should show lot of entries from etcd.

To see the pods specifically 

```shell
$ ETCDCTL_API=3 sudo etcd-v3.5.12-linux-amd64/etcdctl --endpoints 10.0.136.21:2379 --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key get /registry/pod --prefix --keys-only
/registry/pods/default/nginx

/registry/pods/kube-system/etcd-ip-10-0-136-21

/registry/pods/kube-system/kube-apiserver-ip-10-0-136-21

/registry/pods/kube-system/kube-controller-manager-ip-10-0-136-21
```

### Solving the pending pod

Looking at the pod, it doesn't show any errors or any events at all. 

```shell
$ kubectl describe pod nginx
Name:         nginx
...
Node:         <none>
...
Containers:
  nginx:
    Image:        nginx
  ...
Events:           <none>
```
No events or error means kubernetes it not even trying to run this pod.

Looking at the node attribute, it's not populated. So even a node is allocated to the pod 
(that's why its in pending state in the first place).

Which component assigns pod to a node?

It's the job for kubernetes scheduler. 

### Setup Kubernetes scheduler

Install scheduler with kubeadm command

```shell
$ sudo kubeadm init phase control-plane scheduler --v=9 --config kubeadm-config.yaml
...
[control-plane] Creating static Pod manifest for "kube-scheduler"
...
I0216 08:45:05.864141   11318 manifests.go:154] [control-plane] wrote static Pod manifest for component "kube-scheduler" to "/etc/kubernetes/manifests/kube-scheduler.yaml"
```

### Failed scheduling

Lets look at pods after installing kube scheduler. 

```shell
$ kubectl get pods
NAME    READY   STATUS    RESTARTS   AGE
nginx   0/1     Pending   0          9h
```

The pod still remain pending. Let's describe the pod for more details about why the pod is still in pending state. 

```shell
$ kubectl describe pod nginx
Name:         nginx
...
Node:         <none>
...
Containers:
  nginx:
    Image:        nginx
  ...
Events:
  Type     Reason            Age                From               Message
  ----     ------            ----               ----               -------
  Warning  FailedScheduling  13m (x94 over 8h)  default-scheduler  0/1 nodes are available: 1 node(s) had untolerated taint {node.kubernetes.io/not-ready: }. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.
```
As can be seen the node attribute is still set to none (that's why the pod is in pending state). 
But this time we do see some events. Looking at the event details we can see that the event is a warning
about failing to schedule the pod (FailedScheduling). Also the important thing is the event is generated by `default-scheduler`. 
That means this message is given by the default scheduler. 

Looking at the actual message, the reason the pod failed to get scheduled is that there is no node without the `node.kubernetes.io/not-ready` tail. (Since we only have single node, that means our node has this taint).
Since the pod does not tolerate the taint (that's why it's untolerated), it can not be scheduled. 

As the name suggest the taint is saying that our node is not ready. 
Let's look the node status.

```shell
$ kubectl get nodes
NAME             STATUS     ROLES    AGE   VERSION
ip-10-0-136-21   NotReady   <none>   10h   v1.24.17
```

We can also describe the node to see at the node taint. 

```shell
$ kubectl describe node ip-10-0-136-21
Name:               ip-10-0-136-21
Roles:              <none>
...
CreationTimestamp:  Fri, 16 Feb 2024 07:25:18 +0000
Taints:             node.kubernetes.io/not-ready:NoSchedule
...
```

We can see the taint marked as `node.kubernetes.io/not-ready`. The event of the taint is NoSchedule. 
That is why scheduler did not schedule our pod on the node.  

### Why node node ready 

But why the node is not ready? 
Which kubernetes component running at node level (including worker and control-plane/master nodes) is responsible for reporting node status?

It is the Kubelet that reports the node status as Ready or NotReady.

That means we have to look at Kubelet process logs to see if there are any errors reported that is making the node NotReady.

```shell
$ journalctl -xe -u kubelet.service --no-pager
...
Feb 16 17:07:49 ip-10-0-136-21 kubelet[8755]: E0216 17:07:49.058410    8755 kubelet.go:2352] "Container runtime network not ready" networkReady="NetworkReady=false reason:NetworkPluginNotReady message:docker: network plugin is not ready: cni config uninitialized"
...
```

The main error we can see is the above line. Its complaining that network is not ready (NetworkReady=false) and NetworkPluginNotReady. Its also indicating that cni config uninitialized. 

### CNI setup

cni in kubernetes is Container Network Interface (CNI). It's a network plugin required and used by container runtime to setup pod network and other functionality.

The node is not ready because we don't have CNI plugin installed. 
There are many CNI plugins available: eg. Calico, Cilium, AWS VPC, Weave. 

We will use Calico as choice of CNI for this setup.

#### Calico Tigera operator

Looking at the Colico documentation for quick setup [here](https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart)

To install calico, we have to install the Tigera operator first. Which can be done as follows: 

```shell
$ kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml
namespace/tigera-operator created
customresourcedefinition.apiextensions.k8s.io/bgpconfigurations.crd.projectcalico.org created
customresourcedefinition.apiextensions.k8s.io/bgpfilters.crd.projectcalico.org created
...
customresourcedefinition.apiextensions.k8s.io/installations.operator.tigera.io created
customresourcedefinition.apiextensions.k8s.io/tigerastatuses.operator.tigera.io created
serviceaccount/tigera-operator created
clusterrole.rbac.authorization.k8s.io/tigera-operator created
clusterrolebinding.rbac.authorization.k8s.io/tigera-operator created
deployment.apps/tigera-operator created
```
As can be seen above, applying the file create a `tigera-operator` namespace, lot of CRDs, a SA, a clusterrole, a clusterolebinding and a deployment.
The deployment is for a tigera-operator. That means the pods created for this deployment will act as controller for CRD types.

Let's look at the status of the tigera-operator pod.

```shell
$ kubectl get pods -n tigera-operator
NAME                              READY   STATUS             RESTARTS      AGE
tigera-operator-76f5dcbf4-zf2h4   0/1     CrashLoopBackOff   4 (17s ago)   4m34s
```
It's failing. Let's look at the logs for the pod to find out the error.  

```shell
$ kubectl logs tigera-operator-76f5dcbf4-zf2h4 -n tigera-operator
2024/02/16 18:52:48 [INFO] Version: v1.32.3
2024/02/16 18:52:48 [INFO] Go Version: go1.21.5 X:boringcrypto
2024/02/16 18:52:48 [INFO] Go OS/Arch: linux/amd64
2024/02/16 18:53:18 [ERROR] Get "https://10.96.0.1:443/api?timeout=32s": dial tcp 10.96.0.1:443: i/o timeout
```
The main error is the last line. Tigera operator pod is trying to connect to the /api endpoint at IP 10.96.0.1 and port 443. 
But, which IP is this and what is running there?

#### Solving the Tigera operator error

In case of kubernetes, the IP are assigned to pods and services. 
Let's look at all pod ips to see if the IP 10.96.0.1 belong to one of the running pod. 

```shell
$ kubectl get pods -o wide --all-namespaces
NAMESPACE         NAME                                     READY   STATUS    RESTARTS        AGE     IP            NODE             NOMINATED NODE   READINESS GATES
default           nginx                                    0/1     Pending   0               11h     <none>        <none>           <none>           <none>
kube-system       etcd-ip-10-0-136-21                      1/1     Running   0               11h     10.0.136.21   ip-10-0-136-21   <none>           <none>
kube-system       kube-apiserver-ip-10-0-136-21            1/1     Running   7 (11h ago)     11h     10.0.136.21   ip-10-0-136-21   <none>           <none>
kube-system       kube-controller-manager-ip-10-0-136-21   1/1     Running   0               11h     10.0.136.21   ip-10-0-136-21   <none>           <none>
kube-system       kube-scheduler-ip-10-0-136-21            1/1     Running   0               10h     10.0.136.21   ip-10-0-136-21   <none>           <none>
tigera-operator   tigera-operator-76f5dcbf4-zf2h4          1/1     Running   6 (2m58s ago)   9m19s   10.0.136.21   ip-10-0-136-21   <none>           <none>
```
As can be seen the IP does not belong to any pods. 

Then it must be a service IP. Lets look at the services available. 

```shell
$ kubectl get services --all-namespaces
NAMESPACE   NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
default     kubernetes   ClusterIP   10.96.0.1    <none>        443/TCP   11h
```
As can be seen the service IP perfectly match the IP tigera-operator pod is trying to reach to. 
But for some reason the call to this IP (the /api call) is timing out. That means not reply is received from the server side.

Let's describe the service to understand more. 

```shell
$ kubectl describe service kubernetes
Name:              kubernetes
Namespace:         default
Labels:            component=apiserver
                   provider=kubernetes
Annotations:       <none>
Selector:          <none>
Type:              ClusterIP
IP Family Policy:  SingleStack
IP Families:       IPv4
IP:                10.96.0.1
IPs:               10.96.0.1
Port:              https  443/TCP
TargetPort:        6443/TCP
Endpoints:         10.0.136.21:6443
Session Affinity:  None
Events:            <none>
```
The service seems correct. Even the service port 443 looks correct and matches to the port being used by the tigera-operator pod. 
The service also has the endpoint available. Its points to the address, 10.0.136.21:6443. Which is the kube api server address.

So the service looks fine, but somehow the traffic sent to service IP does not reach to pod address (endpoint). 
Why does the service traffic does not reach the pod? Which component is missing? 

#### Kube-proxy setup 

Kube-proxy component in kubernetes is responsible for updating the linux IP tables to ensure that traffic send to service IPs is routed to the appropriate pods.
That means in this case, the kube-proxy is missing. And because of this the tigera operator can not reach API server through the kubernetes service. 
Causing the tigera pod to fail.  

Let's install the kube-proxy to fix this issue. 

```shell
$ sudo kubeadm init phase addon kube-proxy -v=9 --config kubeadm-config.yaml
```
This will install kube-proxy. This should fix the issue of tigera-operator pod. 
Let's see if the issue is solved (you might have to delete the pod to re-create new one). 

```shell
$ kubectl get pods -n tigera-operator
NAME                              READY   STATUS    RESTARTS   AGE
tigera-operator-76f5dcbf4-2p6sj   1/1     Running   0          31s
```
The pod is now Running.

#### Setting up Calico pods. 

Going back to the Calico [quick setup guide](https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart)
We can now create the Calico related resources (CRDs) as follows:
```shell
$ kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/custom-resources.yaml
installation.operator.tigera.io/default created
apiserver.operator.tigera.io/default created
```
This created 2 resources of type installation and apiserver. You can try `kubectl get installation/apiserver` to see if they are working.

This will also create Calico related pods. Which should complete the CNI setup for us. 

To see all the Calico related pods, lets run following command:

```shell
$ kubectl get pods --all-namespaces | grep calico
calico-apiserver   calico-apiserver-b47bf9897-2m625          1/1     Running   0             52s
calico-apiserver   calico-apiserver-b47bf9897-whknb          1/1     Running   0             52s
calico-system      calico-kube-controllers-c8656dcbb-5zz64   1/1     Running   0             114s
calico-system      calico-node-fhl8k                         1/1     Running   0             115s
calico-system      calico-typha-598698b879-bdvzc             1/1     Running   0             115s
calico-system      csi-node-driver-mccpj                     2/2     Running   0             114s
```
All the calico related pods seems to be running fine.

This means that now our node should now be in ready state. 

```shell
$ kubectl get node
NAME             STATUS   ROLES    AGE   VERSION
ip-10-0-136-21   Ready    <none>   12h   v1.24.17
```
As can now be seen the node is in ready state.

### Our nginx pod state

Our nginx pod was not getting scheduled because the node was not ready. 
The node was not ready because CNI setup was missing. 
But now since we have completed the CNI setup and since now the node is ready, our pod should get scheduled. 

Let's have a look

```shell
$ kubectl get pods
NAME    READY   STATUS    RESTARTS   AGE
nginx   1/1     Running   0          11h
```

YaY!!!, Finally our pod is now running.

### Conclusion

We got our pod running. This achieved the goal we set out for us to schedule a simple pod on this k8s node. 
As part of this setup we installed following k8s components:
1. Kube API server. 
2. etcd
3. Kube Controller manager
4. Kube scheduler
5. Tigera operator
6. Kube-proxy
7. Calico CNI
Kubelet, which is another important k8s component, was already installed when we started. 

Hopefully, this journey helped you learn the about the k8s architecture, its components and how do they work (or why they are needed).
