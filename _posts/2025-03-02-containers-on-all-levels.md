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

Docker provides a user-friendly way to run containers. It handles image pulling, container creation, isolation, networking, and lifecycle management with a simple frontend. Let’s see this in action by running an Nginx web server inside a container.

```bash
docker run --rm -d -p 8080:80 nginx
```

Once the container is running, you can verify that Nginx is serving pages by making an HTTP request: `curl http://localhost:8080`. You should see the default Nginx welcome page in the terminal output.

It is worth noting that docker utilizes a client-server protocol. So, the `docker` binary communicates with the `dockerd` process running in the background via RESTful API calls. The daemon then checks if the image is available locally and pulls it if necessary. If something like `compose` or `swarm` was used, those configurations are handled as well. Afterwards, the execution is handed over to `containerd`.


