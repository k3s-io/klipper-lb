# Implementation Guide for SRC_IPS Support in klipper-lb

This guide explains how to implement full support for `loadBalancerIP` and `externalIPs` in klipper-lb and K3s.

## Overview

Currently, klipper-lb listens on **all interfaces** even when `externalIPs` are specified. This implementation allows:

1. Listening on all interfaces by default (current behavior)
2. Listening only on specified IPs when `loadBalancerIP`, `externalIPs`, or `status.loadBalancer.ingress` are configured

## Required Modifications

### 1. klipper-lb (this repository) ✅ DONE

**File**: `entry`

**Changes**: Modified the `start_proxy()` function to:
- Check if the `SRC_IPS` environment variable is set
- If set: create PREROUTING rules with the `-d` flag for each IP
- If not set: default behavior (no `-d` flag, listens on all interfaces)

**Support**: IPv4 and IPv6

### 2. K3s ServiceLB Controller ⏳ TODO

**Repository**: https://github.com/k3s-io/k3s

**File**: `pkg/cloudprovider/servicelb.go`

**Function to modify**: `newDaemonSet()` (line ~432)

#### Required changes:

1. **Collect source IPs** (after line 441):
   ```go
   // Collect source IPs from externalIPs, loadBalancerIP, and status ingress IPs
   var srcIPs []string

   // Add externalIPs from service spec
   if len(svc.Spec.ExternalIPs) > 0 {
       srcIPs = append(srcIPs, svc.Spec.ExternalIPs...)
   }

   // Add deprecated loadBalancerIP if set
   if svc.Spec.LoadBalancerIP != "" {
       srcIPs = append(srcIPs, svc.Spec.LoadBalancerIP)
   }

   // Add IPs from status.loadBalancer.ingress
   for _, ingress := range svc.Status.LoadBalancer.Ingress {
       if ingress.IP != "" {
           srcIPs = append(srcIPs, ingress.IP)
       }
   }
   ```

2. **Add the SRC_IPS environment variable** (after line 539):
   ```go
   // Add SRC_IPS environment variable if any source IPs are configured
   if len(srcIPs) > 0 {
       container.Env = append(container.Env, core.EnvVar{
           Name:  "SRC_IPS",
           Value: strings.Join(srcIPs, ","),
       })
   }
   ```

## Applying the Changes

### For klipper-lb

The changes are already applied in this repository. To use this modified version:

1. Build the Docker image:
   ```bash
   docker build -t your-registry/klipper-lb:custom .
   ```

2. Configure K3s to use your image:
   ```bash
   k3s server --servicelb-image=your-registry/klipper-lb:custom
   ```

### For K3s

1. Clone the K3s repository:
   ```bash
   git clone https://github.com/k3s-io/k3s.git
   cd k3s
   ```

2. Apply the patch:
   ```bash
   cd /path/to/klipper-lb
   patch -p1 < k3s-servicelb-srcips.patch
   ```

   Or manually modify the `pkg/cloudprovider/servicelb.go` file according to the instructions above.

3. Build K3s:
   ```bash
   make
   ```

## Usage Examples

### Example 1: Using externalIPs

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
  ports:
    - port: 80
      targetPort: 8080
  selector:
    app: my-app
```

Result: klipper-lb will listen **only** on 192.168.1.100:80 and 192.168.1.101:80

### Example 2: Using loadBalancerIP (deprecated but supported)

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
  selector:
    app: my-app
```

Result: klipper-lb will listen **only** on 192.168.1.100:80

### Example 3: Default behavior (no IPs specified)

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
  selector:
    app: my-app
```

Result: klipper-lb will listen on **all interfaces** (current behavior)

## Environment Variables

The klipper-lb container now accepts these variables:

| Variable | Description | K3s Source |
|----------|-------------|------------|
| `SRC_IPS` | Comma-separated list of IPs to listen on | `externalIPs`, `loadBalancerIP`, or `status.loadBalancer.ingress` |
| `SRC_PORT` | Source port to listen on | `service.spec.ports[].port` |
| `SRC_RANGES` | Allowed source IP ranges | `service.spec.loadBalancerSourceRanges` |
| `DEST_IPS` | Destination IPs (cluster IPs) | `service.spec.clusterIPs` or `status.hostIPs` |
| `DEST_PORT` | Destination port | `service.spec.ports[].port` or `nodePort` |
| `DEST_PROTO` | Protocol (TCP/UDP) | `service.spec.ports[].protocol` |

## Testing

To test that the modifications work correctly:

1. Create a service with `externalIPs`
2. Check the iptables rules in the klipper-lb pod:
   ```bash
   kubectl exec -n kube-system <klipper-lb-pod> -- iptables -t nat -L PREROUTING -n -v
   ```
3. Verify that the DNAT rules contain `-d <IP>` for the specified IPs

## References

- klipper-lb repository: https://github.com/k3s-io/klipper-lb
- K3s repository: https://github.com/k3s-io/k3s
- K3s ServiceLB documentation: https://docs.k3s.io/networking/networking-services
