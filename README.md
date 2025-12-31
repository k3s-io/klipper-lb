Klipper Service Load Balancer
=================

_NOTE: this repository was moved 2020-11-18 out of the github.com/rancher org to github.com/k3s-io
supporting the [acceptance of K3s as a CNCF sandbox project](https://github.com/cncf/toc/pull/447)_.

---

This is the runtime image for the integrated service load balancer in klipper. This
works by using a host port for each service load balancer and setting up
iptables to forward the request to the cluster IP. The regular k8s scheduler will
find a free host port. If there are no free host ports, the service load balancer
will stay in pending.

## Configuration

The load balancer behavior can be configured using environment variables:

- `SRC_IPS`: Comma-separated list of external IPs or loadBalancerIP to listen on. If set, the load balancer will only accept traffic destined for these specific IPs. If not set, the load balancer will listen on all interfaces (default behavior).
- `SRC_RANGES`: Comma-separated list of source IP ranges to accept traffic from (implements `.spec.loadBalancerSourceRanges`).
- `DEST_IPS`: Comma-separated list of destination cluster IPs to forward traffic to.
- `DEST_PROTO`: Protocol (tcp/udp).
- `DEST_PORT`: Destination port on the cluster IP.
- `SRC_PORT`: Source port to listen on.

## Repository Structure

### This Repository (klipper-lb)

This repository contains **only the load balancer runtime image** - the container that runs in DaemonSet pods on each node.

**What's here:**
- `entry`: Shell script that configures iptables rules based on environment variables
- `Dockerfile`: Builds the minimal Alpine-based container image
- Runtime logic for DNAT/SNAT iptables configuration

**What it does:**
- Reads environment variables (`SRC_IPS`, `DEST_IPS`, `SRC_PORT`, etc.)
- Configures iptables PREROUTING rules to forward traffic
- Runs as a privileged pod with `NET_ADMIN` capability
- One instance per node, per service (DaemonSet model)

### K3s Repository (Controller)

The **ServiceLB controller** lives in the K3s repository at [`pkg/cloudprovider/`](https://github.com/k3s-io/k3s/tree/master/pkg/cloudprovider).

**What's there:**
- `servicelb.go`: Controller that watches Services and manages DaemonSets
- `loadbalancer.go`: Cloud provider interface implementation
- Logic for creating/updating/deleting DaemonSets per LoadBalancer service
- Status management (populating `status.loadBalancer.ingress`)

**What it does:**
- Watches for LoadBalancer services
- Creates one DaemonSet per service
- Populates DaemonSet environment variables from Service spec
- Updates Service status with node IPs

### How They Work Together

```
┌─────────────────────────────────────────────────────────────┐
│ K3s Repository (github.com/k3s-io/k3s)                      │
│                                                             │
│  pkg/cloudprovider/servicelb.go                             │
│  ┌────────────────────────────────────────┐                │
│  │ ServiceLB Controller                   │                │
│  │ - Watches LoadBalancer Services        │                │
│  │ - Creates DaemonSet per service        │                │
│  │ - Sets ENV vars (SRC_IPS, DEST_IPS...) │                │
│  └────────────────┬───────────────────────┘                │
│                   │                                         │
└───────────────────┼─────────────────────────────────────────┘
                    │
                    │ Creates DaemonSet with
                    │ image: rancher/klipper-lb:vX.Y.Z
                    │
                    ▼
┌─────────────────────────────────────────────────────────────┐
│ This Repository (github.com/k3s-io/klipper-lb)              │
│                                                             │
│  entry script                                               │
│  ┌────────────────────────────────────────┐                │
│  │ Load Balancer Runtime                  │                │
│  │ - Reads ENV vars from DaemonSet        │                │
│  │ - Configures iptables PREROUTING       │                │
│  │ - Sets up DNAT rules                   │                │
│  └────────────────────────────────────────┘                │
│                                                             │
│  Runs as: DaemonSet pod on each node                       │
└─────────────────────────────────────────────────────────────┘
```

### Development Workflow

**To modify load balancer behavior (iptables rules):**
- Edit files in **this repository** (klipper-lb)
- Build new Docker image
- Update K3s to use new image version

**To modify controller behavior (DaemonSet creation, ENV vars):**
- Edit files in **K3s repository** (`pkg/cloudprovider/`)
- Rebuild K3s binary
- May require new klipper-lb image if new ENV vars are added

### Example: Adding SRC_IPS Support

This demonstrates the two-repository workflow:

**Step 1: klipper-lb (this repo)**
- Modify `entry` script to read `SRC_IPS` environment variable
- Add `-d <IP>` flag to iptables rules when `SRC_IPS` is set
- Build and publish new image: `rancher/klipper-lb:v0.5.0`

**Step 2: K3s repository**
- Modify `pkg/cloudprovider/servicelb.go`
- Update `newDaemonSet()` to set `SRC_IPS` env var from `service.spec.externalIPs`
- Update default image to `rancher/klipper-lb:v0.5.0`
- Rebuild K3s

Both changes are needed for the feature to work end-to-end.

## Architecture

### Overview

K3s ServiceLB uses a **declarative** architecture based on Kubernetes. There is **no direct communication** between the controller and klipper-lb pods. Everything goes through the Kubernetes API.

### Communication Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes API Server                        │
└────────────┬────────────────────────────────┬───────────────────┘
             │                                │
             │ Watch Events                   │ Watch Events
             ▼                                ▼
┌────────────────────────┐         ┌──────────────────────────┐
│  ServiceLB Controller  │         │  Kubelet on each Node    │
│  (pkg/cloudprovider)   │         │                          │
└────────────┬───────────┘         └──────────┬───────────────┘
             │                                │
             │ Create/Update DaemonSet        │ Deploy Pods
             ▼                                ▼
┌────────────────────────┐         ┌──────────────────────────┐
│      DaemonSet         │────────>│   klipper-lb Pods        │
│  svclb-myservice-xyz   │         │  (with ENV variables)    │
└────────────────────────┘         └──────────────────────────┘
                                                │
                                                │ Configure iptables
                                                ▼
                                   ┌──────────────────────────┐
                                   │  iptables PREROUTING     │
                                   │  DNAT rules              │
                                   └──────────────────────────┘
```

### DaemonSet Architecture

#### One DaemonSet per Service

klipper-lb creates **one DaemonSet per LoadBalancer service**, which means **multiple pods per service** (one pod per eligible node).

Each service gets a unique DaemonSet named `svclb-<service-name>-<uid>`.

**Example with 2 services on 3 nodes:**

```
Service "web"                          Service "api"
┌─────────────────────┐               ┌─────────────────────┐
│ DaemonSet:          │               │ DaemonSet:          │
│ svclb-web-abc12345  │               │ svclb-api-def67890  │
└─────────────────────┘               └─────────────────────┘
         │                                     │
    ┌────┴────┬────────┐              ┌───────┴────┬────────┐
    │         │        │               │            │        │
┌───▼──┐  ┌──▼───┐ ┌──▼───┐       ┌──▼───┐    ┌──▼───┐ ┌──▼───┐
│Node1 │  │Node2 │ │Node3 │       │Node1 │    │Node2 │ │Node3 │
│pod-1 │  │pod-2 │ │pod-3 │       │pod-1 │    │pod-2 │ │pod-3 │
└──────┘  └──────┘ └──────┘       └──────┘    └──────┘ └──────┘
```

#### Destination IP Mapping

The **DEST_IPS** (destination IPs) depend on `externalTrafficPolicy`:

**Mode 1: externalTrafficPolicy: Cluster (default)**

Traffic is forwarded to the service **ClusterIP**:

```yaml
# Service web with ClusterIP 10.43.0.50
Service web:
  ClusterIP: 10.43.0.50
  externalIPs: [192.168.1.100]
  Port: 80

# All klipper-lb pods (Node1, Node2, Node3) have:
DEST_IPS=10.43.0.50
DEST_PORT=80

# iptables rule on each node:
iptables -t nat -A PREROUTING -d 192.168.1.100 -p TCP --dport 80 \
  -j DNAT --to-destination 10.43.0.50:80
```

Traffic can arrive on **any node** and will be forwarded to the ClusterIP. Kubernetes (kube-proxy) then load-balances to the backend pods.

**Mode 2: externalTrafficPolicy: Local**

Traffic is forwarded to the **local node IPs**:

```yaml
# Service web with externalTrafficPolicy: Local
Service web:
  ClusterIP: 10.43.0.50
  externalIPs: [192.168.1.100]
  Port: 80
  NodePort: 30080
  externalTrafficPolicy: Local

# On Node1 (IP: 10.0.0.1):
DEST_IPS=10.0.0.1
DEST_PORT=30080

# iptables rule on Node1:
iptables -t nat -A PREROUTING -d 192.168.1.100 -p TCP --dport 80 \
  -j DNAT --to-destination 10.0.0.1:30080
```

Traffic is forwarded to the **NodePort of the local node**, and Kubernetes routes only to pods **local to that node** (no inter-node hop).

#### Complete Mapping Flow

```
┌─────────────────────────────────────────────────────────────┐
│ Service "web"                                               │
│ - ClusterIP: 10.43.0.50:80                                  │
│ - externalIPs: [192.168.1.100]                              │
│ - externalTrafficPolicy: Cluster (default)                  │
└─────────────────────────────────────────────────────────────┘
                            │
              ┌─────────────┴──────────────┐
              │ DaemonSet: svclb-web-xyz   │
              └─────────────┬──────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
    ┌───▼─────┐        ┌────▼────┐        ┌────▼────┐
    │ Node1   │        │ Node2   │        │ Node3   │
    │ pod-web │        │ pod-web │        │ pod-web │
    └─────────┘        └─────────┘        └─────────┘
        │                   │                   │
    iptables           iptables           iptables
        │                   │                   │
    PREROUTING         PREROUTING         PREROUTING
    -d 192.168.1.100   -d 192.168.1.100   -d 192.168.1.100
    -p TCP             -p TCP             -p TCP
    --dport 80         --dport 80         --dport 80
    -j DNAT            -j DNAT            -j DNAT
    --to 10.43.0.50:80 --to 10.43.0.50:80 --to 10.43.0.50:80
        │                   │                   │
        └───────────────────┼───────────────────┘
                            │
                    ┌───────▼────────┐
                    │  ClusterIP     │
                    │  10.43.0.50:80 │
                    └────────────────┘
                            │
                    kube-proxy IPTABLES
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
    ┌───▼────┐         ┌────▼────┐        ┌────▼────┐
    │ Pod 1  │         │ Pod 2   │        │ Pod 3   │
    │ web    │         │ web     │        │ web     │
    └────────┘         └─────────┘        └─────────┘
```

#### Key Points

1. **One DaemonSet per service** → Each LoadBalancer service has its own DaemonSet
2. **One pod per node** → The DaemonSet deploys one klipper-lb pod on each eligible node
3. **Destination IP mapping**:
   - **Cluster mode**: `DEST_IPS = ClusterIP` → Traffic load-balanced across all pods
   - **Local mode**: `DEST_IPS = Node IP` + `DEST_PORT = NodePort` → Traffic to local pods only

This architecture provides high availability: if one node fails, the others continue to serve traffic.

### How It Works

#### Change Detection

The ServiceLB controller watches several Kubernetes resources:

1. **Services** (via cloud provider interface):
   - Creation of a Service with type `LoadBalancer`
   - Modification of an existing Service
   - Deletion of a Service

2. **Pods**: When a klipper-lb pod starts and gets an IP (used to update the Service status)

3. **Nodes**: When node labels change (triggers update of DaemonSet NodeSelectors)

4. **EndpointSlices**: For `ExternalTrafficPolicy: Local` (allows including only nodes with ready pods)

#### Pod Lifecycle

When a DaemonSet is created/modified:

1. **Kubelet** on each eligible node detects the change
2. **If environment variables have changed** → pods are restarted
3. Each klipper-lb pod starts with the new ENV variables
4. The `entry` script executes, reads environment variables, and configures iptables rules

#### Communication Model

Everything goes through the Kubernetes API:
```
Service change → Controller detects → Update DaemonSet →
Kubernetes restarts pods → New pods read ENV → Configure iptables
```

The controller **cannot**:
- Send commands directly to pods
- Modify iptables rules on the fly
- Communicate via network with pods

This architecture is **robust** because:
- Survives controller restarts
- Desired state stored in the Kubernetes API
- Kubernetes guarantees convergence to desired state
- No network dependency between controller and pods

## Building

`make`

## License
Copyright (c) 2024 [K3s Authors](http://github.com/k3s-io)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

[http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
