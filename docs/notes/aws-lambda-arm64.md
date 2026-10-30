# AWS Lambda on arm64

Lambda doesn't mount `/sys/devices/system/cpu`. On arm64, the CPU backend reads that directory to count cores. Without the directory, the library loads but inference fails on every call. Preload the shim that ships alongside the native library:

```
LD_PRELOAD=/var/task/node_modules/@desert-ant-labs/redact/native/linux-arm64/libdalcpushim.so
```

Set `LD_PRELOAD` as a function environment variable. Correct the path if the package lives in a layer (`/opt/nodejs/node_modules/...`). The shim answers reads of the two files the CPU backend needs there, `possible` and `present`, and passes every other call through. The dynamic linker has to insert the shim before libc, so the SDK can't set it up for you.

On x86_64 you don't need the shim, because the core count comes from a CPU instruction instead of sysfs.
