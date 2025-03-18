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

## `runc`

This was the original tool used to spin up containers. 

> Practically speaking, a container consists of:
> 
> - a tarball of files, and 
> 1 config file glueing it all together 
{: .prompt-info }

The tarball is the filesystem of the container: complete with all the binaries necessary to run the processes in the container. The config file is a JSON that dictates where to expect certain libraries and what to execute. Thus, in order to run the container, we need those two.

You can get the tarball like so:

```bash
mkdir -p container/rootfs
docker pull nginx
container_id=$(docker create nginx --name mynginx)
docker export "$container_id" | tar -C container/rootfs -xf -
docker rm "$container_id"
```

Your local folder doesn't have to be called container, but I think it's a nice way of directly knowing what's in there. Next, you can generate the config file by running the specs on the `container` directory:

```bash
cd container
runc spec
```

You might also want to change the `config.json` like so:

```json
{
	"ociVersion": "1.2.0",
	"process": {
		"terminal": false,
		"user": {
			"uid": 1000,
			"gid": 1000
		},
		"args": [
			"/usr/sbin/nginx",
			"-g",
			"daemon off;"
		],
		"env": [
			"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
			"TERM=xterm"
		],
		"cwd": "/",
		"capabilities": {
			"bounding": [
				"CAP_AUDIT_WRITE",
				"CAP_KILL",
				"CAP_NET_BIND_SERVICE"
			],
			"effective": [
				"CAP_AUDIT_WRITE",
				"CAP_KILL",
				"CAP_NET_BIND_SERVICE"
			],
			"permitted": [
				"CAP_AUDIT_WRITE",
				"CAP_KILL",
				"CAP_NET_BIND_SERVICE"
			],
			"ambient": [
				"CAP_AUDIT_WRITE",
				"CAP_KILL",
				"CAP_NET_BIND_SERVICE"
			]
		},
		"rlimits": [
			{
				"type": "RLIMIT_NOFILE",
				"hard": 1024,
				"soft": 1024
			}
		],
		"noNewPrivileges": true
	},
	"root": {
		"path": "rootfs",
		"readonly": false
	},
	"hostname": "runc",
	"mounts": [
		{
			"destination": "/proc",
			"type": "proc",
			"source": "proc"
		},
		{
			"destination": "/dev",
			"type": "tmpfs",
			"source": "tmpfs",
			"options": [
				"nosuid",
				"strictatime",
				"mode=755",
				"size=65536k"
			]
		},
		{
			"destination": "/dev/pts",
			"type": "devpts",
			"source": "devpts",
			"options": [
				"nosuid",
				"noexec",
				"newinstance",
				"ptmxmode=0666",
				"mode=0620",
				"gid=5"
			]
		},
		{
			"destination": "/dev/shm",
			"type": "tmpfs",
			"source": "shm",
			"options": [
				"nosuid",
				"noexec",
				"nodev",
				"mode=1777",
				"size=65536k"
			]
		},
		{
			"destination": "/dev/mqueue",
			"type": "mqueue",
			"source": "mqueue",
			"options": [
				"nosuid",
				"noexec",
				"nodev"
			]
		},
		{
			"destination": "/sys",
			"type": "sysfs",
			"source": "sysfs",
			"options": [
				"nosuid",
				"noexec",
				"nodev",
				"ro"
			]
		},
		{
			"destination": "/sys/fs/cgroup",
			"type": "cgroup",
			"source": "cgroup",
			"options": [
				"nosuid",
				"noexec",
				"nodev",
				"relatime",
				"ro"
			]
		}
	],
	"linux": {
		"resources": {
			"devices": [
				{
					"allow": false,
					"access": "rwm"
				}
			]
		},
		"namespaces": [
			{
				"type": "pid"
			},
			{
				"type": "network",
				"path": "/var/run/netns/nginx_netw"
			},
			{
				"type": "ipc"
			},
			{
				"type": "uts"
			},
			{
				"type": "mount"
			},
			{
				"type": "cgroup"
			}
		],
		"maskedPaths": [
			"/proc/acpi",
			"/proc/asound",
			"/proc/kcore",
			"/proc/keys",
			"/proc/latency_stats",
			"/proc/timer_list",
			"/proc/timer_stats",
			"/proc/sched_debug",
			"/sys/firmware",
			"/proc/scsi"
		],
		"readonlyPaths": [
			"/proc/bus",
			"/proc/fs",
			"/proc/irq",
			"/proc/sys",
			"/proc/sysrq-trigger"
		]
	}
}
```
{: .scroll}

Two of the most prominent changes were providing the `.process.args` to the command that will be run when the container starts. For nginx, we just start the server. The value of `terminal` is false, due to not wanting to spawn a shell within the container. The other important change is under `.linux.namespaces.type`. Since we want to be able to view and be able to talk to the container later, we have to tell it in which namespace it is being deployed.

Now, lets create the aforementioned namespace. The following block creates the namespace and connects it via a virtual ethernet cable to the host. The ip assigned serves two purposes. Firstly, it makes the namespace reachable from host under a local ip. Secondly, it assigns an address for the services inside the namespace to use.

```bash
sudo ip netns add nginx_netw
sudo ip link add name veth-host type veth peer name veth-alpine
sudo ip link set veth-alpine netns nginx_netw
sudo ip netns exec nginx_netw ip addr add 192.168.10.1/24 dev veth-alpine
sudo ip netns exec nginx_netw ip link set veth-alpine up
sudo ip netns exec nginx_netw ip link set lo up
sudo ip link set veth-host up
sudo ip route add 192.168.10.1/32 dev veth-host
sudo ip netns exec nginx_netw ip route add default via 192.168.10.1 dev veth-alpine
```

You can now finally run the container via: 

```bash
cd container
sudo runc create nginx --bundle .
sudo runc run nginx
```

At this point, you should see the average nginx output on your terminal. If you open a new one and `curl http://192.168.10.1:8080`, you can also make sure you see the welcome page! Browsers like firefox work here as well!

## Summary

This went through ways of starting containers in different levels. It started with the familiar docker, then continued to containerd and it closed with runc. I hope that after reading through or trying out the runc tweaks yourself, you can begin to appreciate and understand docker a bit more :D
