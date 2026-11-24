---
sidebar_position: 7
title: Device stats
description: CPU, memory, GPU, disks, network, battery and the resources each test run uses, live on the dashboard.
---

# Device stats

The **Device** page (`#/device`) shows the runner itself:

- **static facts**: OS and version, machine model, BIOS, CPU model, cores and threads, memory
  modules, GPUs, physical disks; refreshed hourly;
- **live load**: CPU total and per core, memory, disk read and write, network throughput, GPU
  engines and memory, volumes, battery, and the busiest processes by CPU and memory;
- **each running test run's process tree**: how many processes, how much CPU and memory, its
  top processes. This is how you spot a test that leaks child processes or a suite that is
  bound by one core;
- **sparklines** of the last 360 samples.

## What it costs the runner

| Sample | Every | When |
| ------ | ----- | ---- |
| full | 3 s | only while a dashboard is open |
| light (CPU, memory, disk, network) | 15 s | otherwise |
| static | hourly | always |

A full sample costs about half a second of one core, which is why it is only taken while
someone looks.

## Platform differences

| | Windows | Linux | macOS |
| --- | --- | --- | --- |
| CPU per core, threads | yes | yes | total only |
| GPU load | every adapter | NVIDIA (`nvidia-smi`) | model only |
| disk read/write | yes | yes | combined I/O |
| battery | yes | yes | yes |

Values a platform cannot give are null, and the dashboard leaves them out. Windows samples
through a long-lived PowerShell process using raw performance counters (locale-independent);
Linux reads `/proc` and `/sys`; macOS asks `sysctl`, `vm_stat`, `ps`, `iostat`, `df` and `pmset`.

## From programs

`GET /api/v1/device` returns `{static, sample, history}`; MCP's `get_device` gives an agent the
same, so it can tell "the test is slow" from "the runner is busy".
