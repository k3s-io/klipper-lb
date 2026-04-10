Klipper Service Load Balancer
=================

This repo builds the runtime image for the integrated service load balancer
(aka [ServiceLB](https://github.com/k3s-io/k3s/blob/main/pkg/cloudprovider/servicelb.go))
in K3s and RKE2. This works by using a host port for each service load balancer
and setting up iptables to forward the request to the cluster IP. The regular
k8s scheduler will find a free host port. If there are no free host ports, the
service load balancer will stay in pending.

## Building

`make`
