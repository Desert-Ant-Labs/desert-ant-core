# Redact JavaScript Examples

Tiny Node and browser examples for trying Redact with `@desert-ant-labs/redact` from npm.

## Setup

```bash
npm install
```

## Run in Node

```bash
npm run node-example
```

Pass your own text as arguments:

```bash
node main.mjs "Email Anna at anna@example.com"
```

## Run in a browser

```bash
npm run browser-example
```

The first redaction downloads the pinned LiteRT model to the local cache. Later runs use the cached model offline when the host cache is available.
