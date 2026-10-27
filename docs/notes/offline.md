# Offline

To run a model offline, download its files and point the SDK at the folder. The SDK then needs no network.

1. Find the model's `Catalog.swift` in [`Sources/`](https://github.com/Desert-Ant-Labs/desert-ant-core/tree/main/Sources), at the tag you build against. The catalog lists the Hugging Face repo, the revision, and the files for each platform.
2. Download those files with the [Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/guides/cli). For example, Redact on Apple platforms:
   ```bash
   hf download desert-ant-labs/redact --revision v0.4.0 \
     --include "redact.mlmodelc/*" redact_tokenizer.bin labels.json \
     --local-dir redact
   ```
   On Android, Linux, Windows, and the web, the catalog lists `redact.tflite` in place of the `.mlmodelc` folder.
3. Point the SDK at the folder:
   - Swift: `Redact(directory: path)`
   - Kotlin: `Redact(context, directory = path)`
   - Node: `Redact.load({ directory: path })`
   - Browser: serve the files yourself and pass `modelBaseUrl` to `Redact.load()`.

For a reproducible build, use the revision's commit sha in place of the tag.
