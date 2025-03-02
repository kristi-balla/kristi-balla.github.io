---
title: Containers on All Levels
date: 2025-03-02 19:42 +/-1234
categories: [Notes]
tags: [docker, containerd, runc, virtualization]
toc: true
comments: true
math: false
mermaid: false
---

When most developers think of containers, they think of Docker. A single command like `docker run alpine` spins up an isolated environment, making containerization feel almost magical. But under the hood, there's an entire stack of tools working together to make this happen. Understanding this stack is crucial for those who want to dive deeper into container internals, troubleshoot issues, or work in environments where Docker isn't available.

## What to Expect From This?

The following is a summary of notes about the responsabilities of each tool. This journey will help appreciate the abstractions provided. It is worth noting that this blog only focuses on the way docker does things. Tools like `podman` are also in my backlog, so watch out for those! In addition, this tutorial assumes you know what a container is or what an image consists of. If not, [this](https://docs.docker.com/get-started/docker-overview/#docker-objects) is a good place to start.

## Docker

Docker provides a user-friendly way to run containers. It handles image pulling and networking with a simple frontend. Let’s see this in action by running an Nginx web server inside a container.

```bash
docker run --rm -p 8080:80 nginx
```

Once the container is running, you can verify that Nginx is serving pages by making an HTTP request: `curl http://localhost:8080`. You should see the default Nginx welcome page in the terminal output.

It is worth noting that docker utilizes a client-server protocol. So, the `docker` binary communicates with the `dockerd` process running in the background via RESTful API calls. The daemon then checks if the image is available locally and pulls it if necessary. If something like `compose` or `swarm` was used, those configurations are handled as well. Afterwards, the execution is handed over to `containerd`.

## ContainerD

This tool handles cgroups, namespaces, networking and container life-cycle management. However, it assumes an image is present locally. This implies that when working with containerd, one needs to pull an image before running it:

```bash
sudo ctr images pull docker.io/library/nginx:latest
sudo ctr run --rm docker.io/library/nginx:latest nginx
```

> The attentive reader might have noticed that the `ctr` binary is used here, instead of `containerd`. This is due to `ctr` being a neat wrapper around `containerd`. You're welcome to try this in "vanilla" `containerd`, but you will quickly find your options on the CLI to be severly limited.
{: .prompt-info }

Since containerd foresees no way of providing a port-mapping for the container, an IP will have to be retrieved in a different manner. Since `ctr` sets up the networking namespace for the container, the idea would be to look into this namespace for an IP.

```bash
sudo lsns | grep "nginx"
# --> 4026533340 mnt         9 63579 root             nginx: master process nginx -g daemon off;
# --> 4026533341 uts         9 63579 root             nginx: master process nginx -g daemon off;
# --> 4026533342 ipc         9 63579 root             nginx: master process nginx -g daemon off;
# --> 4026533343 pid         9 63579 root             nginx: master process nginx -g daemon off;
# --> 4026533344 net         9 63579 root             nginx: master process nginx -g daemon off;
sudo nsenter --target 63579 -n ip addr show
# --> 1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
# -->     link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
# -->     inet 127.0.0.1/8 scope host lo
# -->        valid_lft forever preferred_lft forever
# -->     inet6 ::1/128 scope host proto kernel_lo 
# -->        valid_lft forever preferred_lft forever
```

So, the container is running, but it isn't reachable from the outside! The bare minimum configuration that `ctr` performs when starting a container is creating a new network namespace. Adding network interfaces and configuring them is usually delegated to various CNI plugins (e.g. flannel, calico) or a higher-level container runtime (e.g., docker). The former is out of scope and the latter was recently demonstrated 😜

After using the provided image and setting up the necessary namespaces and cgroups, containerd hands over the execution to `runc`.


