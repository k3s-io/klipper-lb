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
