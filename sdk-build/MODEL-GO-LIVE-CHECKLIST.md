# Model go-live checklist

A map of **every place** a new Desert Ant Labs model has to appear or be updated to
be fully live — so nothing gets missed. This is the *surface-area* list: **where**,
not **how**. For the build/publish mechanics (mise catalog, reusable CI workflows,
release triggers) see [`sdk-build/README.md`](./README.md).

Copy the checkboxes into a release issue. Fill in
[Model-specific nuances](#model-specific-nuances) — every model has a few.

---

## ⚠️ Rules that don't bend

- **Training data, datasets, and the `<model>-training` repo stay private — forever.**
  Real user/customer content (including prediction dumps and eval sets with real
  text) never goes to a public repo, a public HF repo, or a demo.
- **Demos ship synthetic examples only.** Never real content.
- **The SDK GitHub repo must be public before release.** Publish credentials are org
  secrets scoped to public repos; a private repo's release gets empty creds and fails.
- **The HF model repo must be tagged at the revision the SDK pins**, or downloads 404.
- **The website can't deploy with incomplete translations** — a new model means every
  shipped locale needs its strings, and that gates the build.

---

## Coordinates (the naming is consistent — fill in `<model>`)

| Surface | Where |
|---|---|
| Training (**private**) | `Desert-Ant-Labs/<model>-training` |
| SDK repo | `github.com/Desert-Ant-Labs/<model>` |
| npm | `@desert-ant-labs/<model>` |
| Maven | `ai.desertant:<model>` |
| HF model | `huggingface.co/desert-ant-labs/<model>` |
| HF demo | `huggingface.co/spaces/desert-ant-labs/<model>-demo` |
| Website | `desertant.com/models/<model>/` |
| License | `license.desertant.com` · `licensing@desertant.com` |

---

## The surfaces

### 1. Training (private)
- [ ] `<model>-training` repo holds code/data/eval — stays **private**.

### 2. Hugging Face
- [ ] **Model repo** `desert-ant-labs/<model>` — weights + sidecars, public.
- [ ] **Model card** (the repo README) — what it is, sizes, eval, variants, license, citation.
- [ ] **Revision tag** matching the SDK's pin.
- [ ] **Variants**, if any, hosted alongside (e.g. an `en/` subfolder).
- [ ] **Demo Space** `desert-ant-labs/<model>-demo` — public, synthetic examples.

### 3. SDK repo (GitHub)
- [ ] Source for all shipped platforms (Swift / Kotlin / JS) present and building.
- [ ] Versions consistent across package manifests + README examples.
- [ ] Repo **public**.
- [ ] No copied-template leftovers from the repo it was cloned from (another model's
      name in notices, the Gradle/Maven description, comments, tests, CI scripts).

### 4. Package registries (published by the release)
- [ ] **npm** — `@desert-ant-labs/<model>`.
- [ ] **Maven Central** — `ai.desertant:<model>` (+ resources module if used).
- [ ] **GitHub Release** — the SwiftPM release (the tag itself).

### 5. Documentation
- [ ] **SDK README** — install + usage per platform, sizes, eval, any variant flag.
- [ ] **npm package README** — must exist, or the npm page is blank.
- [ ] **HF model card** — kept in sync (same content as #2).
- [ ] **Third-party notices** — names this model and its data provenance.

### 6. Org landing pages
- [ ] **GitHub org profile** (`Desert-Ant-Labs/.github`) — add the model to the product table.
- [ ] **HF org page** — auto-lists public models (appears once the repo is public;
      pinning/blurb are manual settings).

### 7. Website — desertant.com (`Desert-Ant-Labs/website`)
- [ ] **Model entry** — the per-model page content/copy/specs.
- [ ] **Homepage** — a card in the model grid.
- [ ] **Platform hubs** — the model's one-liner on each platform it ships to.
- [ ] **Translations** — the model's strings in every shipped locale (gates deploy).
- [ ] **Deploy** — publish the built site (Cloudflare; needs credentials).

### 8. Telemetry / billing
- [ ] Confirm usage events flow and are **attributed to this SDK** (not the default
      identity), so billing counts are correct.

---

## Model-specific nuances

> Fill in what the shared flow above does **not** capture for this model. Examples:
> - Non-standard or extra artifacts (multiple heads, a router, per-script tables).
> - **Variants** and how the SDK selects them (e.g. an English-only build).
> - Coverage caveats (e.g. a variant that only handles certain languages/scripts).
> - Model size and the download it implies on first use.
> - Platforms not yet shipped ("Soon").
> - Anything unusual about the demo.

- **`<model>`:** _(describe here)_

---

## Pitfalls seen in real releases (keep adding)

- Private SDK repo at release time → empty publish credentials → publish fails.
- SDK pinned an HF model revision with no matching tag → downloads 404.
- npm package shipped with no README → blank npm page.
- Version bump missed a spot (a README example, a Maven description).
- Build artifacts or real-content dumps swept into a commit.
- Website: a new model missing from a locale blocked the whole deploy; English house
  style (no em/en dashes) failed the style check.
- Copied-template leftovers from the source model the SDK was cloned from.
