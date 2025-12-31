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

The load balancer behavior is configured via environment variables that are automatically set by the K3s ServiceLB controller when creating DaemonSet pods.

### Environment Variables

| Variable | Description | K3s Source | Example |
|----------|-------------|------------|---------|
| `SRC_IPS` | Comma-separated list of IPs to listen on. If set, klipper-lb only accepts traffic destined for these specific IPs (using `-d` in iptables). If not set, listens on all interfaces. | `service.spec.externalIPs`, `service.spec.loadBalancerIP`, or `service.status.loadBalancer.ingress` | `192.168.1.100,192.168.1.101` |
| `SRC_PORT` | Source port to listen on | `service.spec.ports[].port` | `80` |
| `SRC_RANGES` | Comma-separated list of source IP ranges allowed to connect (implements `.spec.loadBalancerSourceRanges`). Uses `-s` in iptables to filter source addresses. | `service.spec.loadBalancerSourceRanges` | `10.0.0.0/8,192.168.0.0/16` |
| `DEST_IPS` | Destination IPs to forward traffic to (DNAT target). Either cluster IPs or node IPs depending on `externalTrafficPolicy`. | `service.spec.clusterIPs` (Cluster mode) or `status.hostIPs` (Local mode) | `10.43.0.50` |
| `DEST_PORT` | Destination port to forward traffic to | `service.spec.ports[].port` (Cluster mode) or `service.spec.ports[].nodePort` (Local mode) | `8080` |
| `DEST_PROTO` | Protocol for forwarding | `service.spec.ports[].protocol` | `TCP` or `UDP` |

### How Environment Variables are Set

These variables are **not** set manually. They are automatically populated by the K3s ServiceLB controller when it creates the DaemonSet for your LoadBalancer service.

**Example DaemonSet Pod Env:**
```yaml
env:
  - name: SRC_IPS
    value: "192.168.1.100"
  - name: SRC_PORT
    value: "80"
  - name: SRC_RANGES
    value: "0.0.0.0/0"
  - name: DEST_PROTO
    value: "TCP"
  - name: DEST_PORT
    value: "8080"
  - name: DEST_IPS
    value: "10.43.0.50"
```

**Resulting iptables rule:**
```bash
iptables -t nat -A PREROUTING -d 192.168.1.100 -s 0.0.0.0/0 -p TCP --dport 80 \
  -j DNAT --to-destination 10.43.0.50:8080
```

## Service Configuration

### Overview

There are three ways to configure a LoadBalancer service with klipper-lb, each with different behavior regarding which IPs the load balancer listens on.

### Option 1: Using `externalIPs` (Recommended with SRC_IPS)

Specify **multiple external IPs** that should be used for the service. This is the key difference from `loadBalancerIP` which only accepts a single IP.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: LoadBalancer
  externalIPs:
    - 192.168.1.100
    - 192.168.1.101
    - 192.168.1.102
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
  selector:
    app: my-app
```

**What happens:**
- ✅ **With SRC_IPS support**: klipper-lb listens **only** on 192.168.1.100:80, 192.168.1.101:80, and 192.168.1.102:80
- ❌ **Without SRC_IPS** (current upstream): klipper-lb listens on **all IPs** on port 80 (security issue)
- The specified IPs must already exist on the nodes or be routed to them
- Traffic to other IPs on port 80 is ignored (with SRC_IPS support)
- You can specify a **single IP** or **multiple IPs** (unlike `loadBalancerIP`)

**Use cases:**
- You have specific external IPs assigned to your nodes
- You're using a VIP system (Keepalived) and want failover IPs
- You want to expose services on specific IPs only
- Multiple services on different IPs
- **Load balancing across multiple IPs** (e.g., DNS round-robin)

**Status field:**
```yaml
status:
  loadBalancer:
    ingress:
    - ip: <node1-external-ip>
    - ip: <node2-external-ip>
    - ip: <node3-external-ip>
```

**iptables rules (with SRC_IPS):**
```bash
# Each node gets these rules (one per externalIP):
iptables -t nat -A PREROUTING -d 192.168.1.100 -p TCP --dport 80 -j DNAT --to <cluster-ip>:8080
iptables -t nat -A PREROUTING -d 192.168.1.101 -p TCP --dport 80 -j DNAT --to <cluster-ip>:8080
iptables -t nat -A PREROUTING -d 192.168.1.102 -p TCP --dport 80 -j DNAT --to <cluster-ip>:8080
```

### Option 2: Using `loadBalancerIP` (Deprecated in k8s but Supported)

Specify a single IP for the load balancer. This field is deprecated in Kubernetes but still supported.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.1.100
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
  selector:
    app: my-app
```

**What happens:**
- ✅ **With SRC_IPS support**: klipper-lb listens **only** on 192.168.1.100:80
- ❌ **Without SRC_IPS**: klipper-lb listens on **all IPs** on port 80
- Same behavior as `externalIPs` with a single IP
- The IP must already exist on the nodes or be routed to them

**Use cases:**
- Legacy configurations using the old Kubernetes API
- Simple single-IP deployments
- Migration from cloud providers that used this field

**Note:** Prefer using `externalIPs` for new deployments as `loadBalancerIP` is deprecated.

**Status field:**
```yaml
status:
  loadBalancer:
    ingress:
    - ip: <node1-external-ip>
    - ip: <node2-external-ip>
    - ip: <node3-external-ip>
```

**iptables rules (with SRC_IPS):**
```bash
iptables -t nat -A PREROUTING -d 192.168.1.100 -p TCP --dport 80 -j DNAT --to <cluster-ip>:8080
```

### Option 3: Default (No IPs specified)

Create a LoadBalancer service without specifying any external IPs.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
  selector:
    app: my-app
```

**What happens:**
- klipper-lb listens on **all interfaces** on port 80 (both with and without SRC_IPS support)
- No `-d <IP>` filter in iptables rules
- Traffic to ANY IP on port 80 will be forwarded to the service
- The service is accessible via all node IPs

**Use cases:**
- Simple deployments where you want the service accessible on all node IPs
- Development/testing environments
- When you don't care which IP is used to access the service
- Default K3s behavior

**Status field:**
```yaml
status:
  loadBalancer:
    ingress:
    - ip: <node1-external-ip>
    - ip: <node2-external-ip>
    - ip: <node3-external-ip>
```

**iptables rules:**
```bash
# No -d flag, matches all destination IPs
iptables -t nat -A PREROUTING -p TCP --dport 80 -j DNAT --to <cluster-ip>:8080
```

### Comparison Table

| Configuration | IPs Supported | SRC_IPS ENV | iptables Filter | Security                           | Use Case                          |
|---------------|---------------|-------------|-----------------|------------------------------------|-----------------------------------|
| `externalIPs: [192.168.1.100, 192.168.1.101, 192.168.1.102]` | **Multiple** ✅ | `192.168.1.100,192.168.1.101,192.168.1.102` | `-d <IP>` (one rule per IP) | ✅ Listen only on the specified ips | Multiple IPs                      |
| `loadBalancerIP: 192.168.1.100` | **Single only** | `192.168.1.100` | `-d 192.168.1.100` | ✅ Listen only on the specified ip  | K8s Legacy single IP (deprecated) |
| No IPs specified | N/A | (not set) | No `-d` flag (matches **any** IP) | ⚠️ Listen on all ips | k3s Legacy, simple                |


### Combined Configuration

You can combine multiple options, though this is uncommon:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.1.100
  externalIPs:
    - 192.168.1.101
    - 192.168.1.102
  ports:
    - port: 80
      targetPort: 8080
```

**What happens:**
- All IPs are collected: `[192.168.1.100, 192.168.1.101, 192.168.1.102]`
- klipper-lb listens on all three IPs
- Useful for migration scenarios or complex setups

### IP Requirements

**Important:** The IPs you specify must be reachable on the nodes. klipper-lb does **not** assign IPs; it only listens on them.

**How to configure IPs on nodes:**

1. **Manual assignment** (loopback):
   ```bash
   # On each node
   ip addr add 192.168.1.100/32 dev lo
   ```

2. **Manual assignment** (interface):
   ```bash
   # On each node
   ip addr add 192.168.1.100/24 dev eth0
   ```

3. **VIP with Keepalived** (VRRP):
   - uses VRRP protocol
   - IP is active on one node (master), standby on others


4. **No configuration** (default):
   - Don't specify any IPs
   - Service accessible via node IPs automatically

### Example Workflows

#### Workflow 1: Multiple Services, Different IPs

```yaml
# Service 1 - Web on .100
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: LoadBalancer
  externalIPs:
    - 192.168.1.100
  ports:
    - port: 80
      targetPort: 8080
  selector:
    app: web
---
# Service 2 - API on .101
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  type: LoadBalancer
  externalIPs:
    - 192.168.1.101
  ports:
    - port: 80
      targetPort: 3000
  selector:
    app: api
```

Result: Web accessible on 192.168.1.100:80, API on 192.168.1.101:80 (same port, different IPs)

#### Workflow 2: Simple Default

```yaml
# No IP configuration needed
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 8080
  selector:
    app: web
```

Result: Accessible on all node IPs on port 80

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

## References

### Official Documentation
- [K3s ServiceLB Documentation](https://docs.k3s.io/networking/networking-services) - Official K3s documentation on ServiceLB
- [Kubernetes Services](https://kubernetes.io/docs/concepts/services-networking/service/) - Kubernetes Service concepts

### Source Code
- [klipper-lb Repository](https://github.com/k3s-io/klipper-lb) - This repository (load balancer runtime)
- [K3s Repository](https://github.com/k3s-io/k3s) - K3s main repository
- [K3s ServiceLB Controller](https://github.com/k3s-io/k3s/tree/master/pkg/cloudprovider) - Controller source code

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
