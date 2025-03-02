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

The following uncovers what each tool actually does and how much heavy lifting happens behind the scenes. This journey will help appreciate the abstractions provided. It is worth noting that this blog only focuses on the way docker does things. Tools like `podman` are also in my backlog, so watch out for those!

## Docker

Docker provides a user-friendly way to run containers. It handles image pulling, container creation, isolation, networking, and lifecycle management with a simple frontend. Let’s see this in action by running an Nginx web server inside a container.

```bash
docker run --rm -d -p 8080:80 nginx
```

Once the container is running, you can verify that Nginx is serving pages by making an HTTP request:

`curl http://localhost:8080`. You should see the default Nginx welcome page in the terminal output.

With just a single command, Docker handled everything! But what’s happening under the hood?



