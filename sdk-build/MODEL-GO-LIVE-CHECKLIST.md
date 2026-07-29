# Model go-live checklist

Everything that has to be published, updated, documented, and built to take a new
Desert Ant Labs on-device model from "trained" to "live everywhere," in order.
This is the end-to-end **release surface** checklist; the **build/CI mechanics**
(the shared mise catalog and the reusable workflows) are in
[`sdk-build/README.md`](./README.md). Read both.

It is written to be followed top to bottom by a person or an agent. Copy the
checkboxes into a release issue and tick them off. Fill in the
[Model-specific nuances](#model-specific-nuances) section for the model you are
shipping — every model has a few.

---

## ⚠️ Read first — the rules that don't bend

- **Training data, datasets, and the `<model>-training` repo stay private. Forever.**
  Real user/customer content (e.g. Subwave content) is **never** committed to a
  public repo, uploaded to a public HF repo, or embedded in a demo. This includes
  model **prediction dumps** and eval sets that contain real text. When in doubt,
  it does not go public.
- **Demo examples must be synthetic.** The demo Space and the website demo widgets
  ship with the model — author clean, synthetic, multilingual examples. Never real
  content.
- **The SDK GitHub repo must be PUBLIC before you release.** Org publish secrets
  (`NPM_TOKEN`, `MAVEN_CENTRAL_*`, `SIGNING_IN_MEMORY_KEY*`) have visibility
  **"Public repositories"** on the current plan — a **private** repo's CI receives
  them **empty**, and npm/Maven publish fail with auth errors. (This corrects the
  "needs no secret setup" note in the build README: true only once the repo is
  public.)
- **The HF model repo must be tagged at the exact revision the SDK pins.** The SDK
  pins a `modelRevision`; if no matching git tag/branch exists on the HF model repo,
  `Model.load()` / downloads **404 for everyone**. Tag the HF repo (e.g. `v2.1.0`)
  and pin the SDK to it. See [Phase 1](#phase-1--model-artifacts-on-hugging-face).
- **Never commit build artifacts.** `packages/<model>-node/native/` (prebuilt
  `.so`/`.dylib`, tens of MB), `.build/`, `dist/`, wasm, and the model binaries are
  CI-built or downloaded — gitignore them.
- **English prose on the website has no em/en dashes** (`—`, `–`). A test enforces
  it. Use commas/parentheses. (This is English-only house style; other locales use
  their own typography.)

---

## Coordinates & naming (fill in `<model>` / `<Product>`)

| Surface | Coordinate |
|---|---|
| Training repo (**private**) | `Desert-Ant-Labs/<model>-training` |
| SDK repo (public) | `github.com/Desert-Ant-Labs/<model>` (monorepo: Swift + `packages/<model>-node` + `packages/<model>-kotlin`) |
| npm | `@desert-ant-labs/<model>` |
| Maven | `ai.desertant:<model>` (+ `ai.desertant:<model>-tflite-resources` for offline bundling) |
| HF model | `huggingface.co/desert-ant-labs/<model>` |
| HF demo Space | `huggingface.co/spaces/desert-ant-labs/<model>-demo` |
| License | `https://license.desertant.com/1.0` · `licensing@desertant.com` |
| Website model page | `desertant.com/models/<model>/` (generated) |

Swift product = `<Product>` (capitalized). Native libs = `lib<Product>Node`,
`lib<Product>Android`. These derive from `model`/`product` in the model repo's
`mise.toml` `[vars]`.

---

## Phase 0 — Prerequisites (private)

- [ ] Model trained; deployable artifacts exported (int8 embedding/weights, head as
      Core ML `.mlmodelc` **and** LiteRT `.tflite` **and** ONNX where the web path
      needs it, tokenizer, `*_config.json`, `taxonomy.json` or equivalent sidecars).
- [ ] `<model>-training` repo holds training code, data registry, eval — **private**.
- [ ] Parity verified: the on-device path (int8 pooling + platform head) matches the
      reference (ONNX/PyTorch) on a real eval set. Record the numbers.

## Phase 1 — Model artifacts on Hugging Face

- [ ] Create/confirm the model repo `desert-ant-labs/<model>` (start **private** if
      you want to stage; flip public in Phase 3).
- [ ] Upload the deployable files to the repo root via `upload_folder`. Use
      `delete_patterns=["*"]` only when you intend to fully replace the file set;
      otherwise upload additively.
- [ ] Author the **model card** (`README.md`) with YAML front-matter (license,
      language, tags, `pipeline_tag`, `library_name`). See an existing card
      (e.g. `desert-ant-labs/gist`) for the template.
- [ ] **Tag the HF model repo** at the revision the SDK will pin
      (`api.create_tag(..., tag="vX.Y.Z", revision="main")`). ⚠️ Without this, the
      SDK's pinned `modelRevision` resolves to nothing and downloads 404.
- [ ] **Variants** (optional): ship additional builds under a subfolder
      (e.g. `en/` for an English-only variant) at the **same tag**, with the **same
      file names**. The SDK selects a variant by prefixing the download paths — no
      core change needed (the download cache keys on repo+revision). Do **not** use a
      same-revision subfolder if you need separate cache/manifest isolation; a
      subfolder shares the managed cache dir (fine for read; re-verifies on switch).
- [ ] Verify each file resolves at the tag:
      `curl -sI https://huggingface.co/desert-ant-labs/<model>/resolve/vX.Y.Z/<file>`
      (200/302/307 = ok).

## Phase 2 — SDK repo content

Structure follows the shared template (see `sdk-build/README.md`): `Package.swift`,
`Sources/<Product>*`, `packages/<model>-node`, `packages/<model>-kotlin`, `mise.toml`
including the catalog, `.github/workflows/{build,release}.yml`.

- [ ] `mise.toml` `[vars]` set (`model`, `product`, `tflite_files`) and the catalog
      `includes` pinned to a core tag.
- [ ] SDK pins `modelRepo` + `modelRevision` (matching the HF tag from Phase 1).
- [ ] **Versions consistent** — run `mise run set-version X.Y.Z`. It updates
      `packages/<model>-node/package.json` (+ lock), both Gradle modules, and the
      Swift `from:` line in the README. ⚠️ It does **not** update Kotlin coordinate
      examples (`ai.desertant:<model>:X.Y.Z`) in the README — fix those by hand.
      `mise run check-version` must pass (it gates the release).
- [ ] **Clean copied-template leftovers.** New SDKs are cloned from emo/redact —
      grep for the source model's name and fix every hit: `THIRD_PARTY_NOTICES.md`
      title, source-comment references (`Package.swift`, Gradle `build.gradle.kts`
      **description**, tokenizer comments), the Firebase test-APK path, and the
      instrumented test (`<Other>Test.kt` referencing a non-existent class/API →
      rewrite as `<Product>Test.kt` against this model's API). A stale Gradle
      `description` ships to Maven Central.
- [ ] `swift build` + `swift test` green locally.
- [ ] `.gitignore` excludes `packages/<model>-node/native/`, `.build/`, `dist/`,
      wasm, model binaries.

## Phase 3 — Make it public

Flip **all three**; keep datasets/training private.

- [ ] HF model repo → public (`update_repo_settings(..., private=False)`).
- [ ] GitHub SDK repo → public
      (`gh repo edit Desert-Ant-Labs/<model> --visibility public --accept-visibility-change-consequences`).
      ⚠️ Required before release so org secrets apply (see rules).
- [ ] HF demo Space → public (Phase 5).

## Phase 4 — Release (tag-driven CI)

Prereqs: repo public (Phase 3), versions consistent (Phase 2), org publish secrets
exist with **"All / Public repositories"** visibility.

- [ ] Commit + push everything to `main`.
- [ ] Tag and push: `git tag -aX.Y.Z … ` then `git push origin vX.Y.Z`.
      (Run bare git commands — compound/`-c`-prefixed git invocations can trip the
      command classifier.)
- [ ] CI (`model-sdk-release.yml`) publishes only what changed since the last tag:
      GitHub Release (always), Maven (`Sources/` or `packages/<model>-kotlin/`
      changed), npm (`Sources/` or `packages/<model>-node/` changed). See the table
      in `sdk-build/README.md`.
- [ ] Watch it: `gh run watch <id> -R Desert-Ant-Labs/<model> --exit-status`.
- [ ] On failure, read the failed step (`gh run view --job <id> --log-failed`).
      Common causes seen: repo still private → empty creds; `check-version`
      mismatch; missing HF tag.
- [ ] Verify published: `npm view @desert-ant-labs/<model> version`;
      `https://repo1.maven.org/maven2/ai/desertant/<model>/X.Y.Z/` (Maven Central
      search index lags ~30 min behind the repo1 mirror — check the mirror URL).

## Phase 5 — Demo Space

- [ ] Space `desert-ant-labs/<model>-demo` exists; front-matter `sdk: static` for an
      HTML demo (built from the shared `desert-ant-demo` template).
- [ ] `upload_folder(..., repo_type="space", delete_patterns=["*"])`.
- [ ] **Synthetic examples only.** If scores are shown, capture them from the real
      on-device path so they're truthful, but the input text must be synthetic.

## Phase 6 — Documentation

- [ ] **SDK `README.md`** — per-platform install + usage (Swift/Kotlin/JS), model &
      size, eval table, repo layout, license. Document any **variant flag**.
- [ ] **npm package README** — `packages/<model>-node/README.md` must **exist** and
      be listed in `package.json` `files[]`, or npmjs.com shows an empty page.
      ⚠️ It ships with the version that's published *after* it's added — a README
      added post-release only appears on the next version bump.
- [ ] **HF model card** — kept current (Phase 1); document variants, eval, license,
      citation.
- [ ] `THIRD_PARTY_NOTICES.md` — names this model and its real data provenance.
- [ ] License block points to `https://license.desertant.com/1.0` /
      `licensing@desertant.com`.

## Phase 7 — Org landing pages

- [ ] **GitHub org profile** — `Desert-Ant-Labs/.github` → `profile/README.md`. Add a
      product-table row: What it does · [Model] · [Demo] · SDK links (all three
      platform columns point at the monorepo for a monorepo SDK). Public, auto-live
      on push.
- [ ] **HF org page** — `huggingface.co/desert-ant-labs` **auto-lists public models**;
      once the model repo is public it appears with no push. Pinning/among-featured
      and the org blurb are settings-UI actions (manual, owner-only).

## Phase 8 — Website (desertant.com)

Repo `Desert-Ant-Labs/website` (**private**, Cloudflare Pages). Data-driven: pages
are generated from `data/*.json`. See its `README.md` and `.claude/skills/` (`i18n`,
`translate`, `translate-review`, `catalog-sync`).

- [ ] `data/models.json` — add one model object. Match an existing entry's schema
      (`slug`, `name`, `cardName`, `category`, `status`, `claim`, `h1`, `lede`,
      `overview[]`, `useCases[]`, `features[]`, `facts[]`, `platforms[]`
      (install+usage per platform), `links` (hfModel, demo), `keywords[]`,
      `benchmarks`, `repo`).
- [ ] `data/home.json` — add a homepage `card`. ⚠️ **The homepage template
      (`data/home.template.html`) has fixed, index-bound card slots**
      (`{{home.card.N.kind/claim}}`) with **hardcoded name + href per slot**. Adding
      a card means: insert the card in `home.json` **and** add a matching `<a>` slot
      in the template **and** renumber every `home.card.N` after the insertion point.
      Inserting mid-list marks the shifted cards **stale** for i18n (below).
- [ ] `data/platforms.json` — add the model's `oneLiners` for `swift`, `kotlin`, `js`.
- [ ] **demo widget** (optional): `demoWidget` is **per-model** (needs render code in
      `public/assets/demos.js` + a demo test + a vendored SDK bundle). If you don't
      wire it, just set `links.demo` to the HF Space — the page links out cleanly.
- [ ] **i18n — the build gate.** ⚠️ `npm run build` runs `i18n-check` first and
      **blocks deploy** if any shipped locale is incomplete or **stale**. A new model
      (and any renumbered `home.card.*`) is missing/stale in **every** locale
      (`data/i18n/<locale>.json`, ~12 languages). Fix with the **`translate`** skill
      per locale (`node build/i18n-todo.mjs <locale>` → translate → `translate-review`),
      then `node build/i18n-status.mjs` must be all-ready. Keep the English edit and
      its translation refresh in the same change.
- [ ] Build + verify: `npm install` (needs deps, e.g. `shiki`), `npm run vendor`
      (self-hosts demo SDK bundles), `npm run build`, `npm test`. Confirm
      `dist/models/<model>/index.html`, homepage card, `catalog.json`, `sitemap.xml`.
- [ ] Deploy: `./deploy.sh` — builds and `wrangler pages deploy` to the `desertant`
      Cloudflare Pages project. ⚠️ Needs Cloudflare auth (wrangler); this is a human
      step, not an agent one, unless credentials are present.

## Phase 9 — Verify (public URLs)

- [ ] `github.com/Desert-Ant-Labs/<model>` (public) + release tag page
- [ ] `huggingface.co/desert-ant-labs/<model>` (card renders, files at the tag)
- [ ] `huggingface.co/spaces/desert-ant-labs/<model>-demo` (running)
- [ ] `npmjs.com/package/@desert-ant-labs/<model>` (version + README render; the page
      403s to scripts but loads in a browser — trust `npm view` for the version)
- [ ] `central.sonatype.com/artifact/ai.desertant/<model>` (mirror first, index lags)
- [ ] `github.com/Desert-Ant-Labs` org profile shows the model
- [ ] `desertant.com` homepage card + `desertant.com/models/<model>/`
- [ ] End-to-end smoke: `npm i @desert-ant-labs/<model>@X.Y.Z` and run one call.

## Phase 10 — Telemetry / billing

- [ ] SDKs report usage automatically via desert-ant-core's tracked inference session
      → `https://platform.desertant.ai/api/v1/ingest` (MAD = distinct devices). No
      SDK code needed to *send*, but:
- [ ] ⚠️ **Per-SDK attribution** requires the core version to include the `sdk-info`
      + call-coalescing fixes **and** the SDK to pass its `SDKInfo` when building the
      session. If the core pin predates those, events fire but are attributed to
      core's default identity (not this model) and may over-count. Confirm the pinned
      core carries them before relying on billing numbers.

---

## Model-specific nuances

> Fill this in for the model being shipped. Things that are **not** captured by the
> shared flow above. Examples of what goes here:
> - Extra or non-standard artifacts (multiple heads, a router, per-script tables).
> - **Variants** and how the SDK flag selects them (e.g. an English-only build under
>   `en/`, selected with `variant: "english"` / `.english` / `GistVariant.ENGLISH`).
> - Language/script coverage caveats (e.g. an English-only variant produces noise on
>   non-Latin input — document it as a deliberate mode).
> - Offline-bundling resource targets and their size trade-off.
> - Any platform not yet shipped ("Soon").
> - Demo-widget specifics (custom engine, sample inputs).

- **`<model>`:** _(describe here)_

---

## Pitfalls seen in real releases (keep adding)

- Private SDK repo at release time → empty publish creds → npm/Maven fail.
- SDK pinned an HF `modelRevision` with no matching tag → downloads 404.
- `set-version` left the Kotlin README coordinates and a Gradle `description` stale.
- npm package shipped with no README (file missing though listed) → empty npm page.
- `git add -A` swept in `native/` (73 MB) and real-content prediction dumps.
- Website: em/en dashes in English prose failed the style test; a mid-list homepage
  card insert desynced the fixed template slots and marked every later card stale in
  all locales; the build blocks deploy until all locales are complete.
- Copied-template leftovers (another model's name in notices, Gradle description,
  tests, Firebase scripts).
