import { call, toPixels } from "./codec.js";
import { Faceprint, matches, reviveFace, revivePerson, seconds, toWire } from "./faceprint.js";

/**
 * The people in a set of photos, for a people view where the user sees, names and
 * fixes faces. Get one from `face.library()`. The library runs in the SDK's Swift
 * core, so every platform groups faces the same way, and every method is async.
 */
export class FaceLibrary {
  #model;
  #handle;

  constructor(model, handle) {
    this.#model = model;
    this.#handle = handle;
  }

  #call(op, args = {}) {
    if (this.#handle == null) return Promise.reject(new Error("@desert-ant-labs/face: library closed"));
    return call(this.#model, `library.${op}`, { handle: this.#handle, ...args });
  }

  /** Add a photo's faces (from `face.faces()`), replacing any it had. Their ids are `"<photo>#<index>"`. */
  async add(faces, photo, { date } = {}) {
    await this.#call("add", { faces: faces.map(toWire), photo: String(photo), date: seconds(date) });
  }

  /** Add one face with your own id. */
  async addFace(face, id, photo, { date } = {}) {
    await this.#call("addFace", { face: toWire(face), id: String(id), photo: String(photo), date: seconds(date) });
  }

  /** Remove a photo and its faces. */
  async removePhoto(photo) { await this.#call("removePhoto", { photo: String(photo) }); }

  /** Remove one face. */
  async removeFace(id) { await this.#call("removeFace", { id: String(id) }); }

  /** The people, most photographed first. `prominent: true` lists the ones that matter to the user. */
  async people({ prominent = false } = {}) {
    return (await this.#call("people", { prominent })).map(revivePerson);
  }

  /** A person by id, or `null`. */
  async person(id) { return revivePerson(await this.#call("person", { person: id })); }

  /** Who this faceprint is, if it clearly matches someone, or `null`. */
  async personFor(faceprint) { return revivePerson(await this.#call("personFor", { faceprint: toWire(faceprint) })); }

  /** A face record by id, or `null`. */
  async face(id) { return reviveFace(await this.#call("face", { id: String(id) })); }

  /** Faces that may be this person, most likely first: for "Is this also Noor?". */
  async suggestions(person, { limit = 20 } = {}) { return this.#call("suggestions", { person, limit }); }

  /** The face records whose person, confirmation or rejections changed since the last call. */
  async takeChanges() { return (await this.#call("takeChanges")).map(reviveFace); }

  /** The names the user gave, by person id. */
  async names() {
    const raw = await this.#call("names");
    return Object.fromEntries(Object.entries(raw).map(([k, v]) => [Number(k), v]));
  }

  /** Name a person, or clear the name with `null`. */
  async name(person, name) { await this.#call("name", { person, name: name ?? undefined }); }

  /** "This is Noor". */
  async confirm(id, person) { await this.#call("confirm", { id: String(id), person }); }

  /** "This is not Noor". */
  async reject(id, person) { await this.#call("reject", { id: String(id), person }); }

  /** "This is Ana", someone new: returns her id, or `null` if there is no such face. */
  async newPerson(id, name) { return this.#call("newPerson", { id: String(id), name: String(name) }); }

  /** "These are the same person": move every face of `other` to `person`. */
  async merge(other, person) { await this.#call("merge", { other, person }); }

  /** Regroup every face now, keeping what the user said. */
  async regroup() { await this.#call("regroup"); }

  /** The whole library as JSON-ready `{ faces, names }`: store it, or pass it to `face.library()`. */
  async save() { return this.#call("save"); }

  /** Release the library. */
  async close() {
    if (this.#handle == null) return;
    await this.#call("close");
    this.#handle = null;
  }
}

export function makeFace(sdk) {
  /**
   * On-device face matching. Create one with `await Face.load()` and reuse it.
   *
   * ```js
   * const face = await Face.load();
   * const library = await face.library();
   * await library.add(await face.faces(image), "IMG_0001");
   * const people = await library.people();
   * ```
   */
  return class Face {
    #model;
    constructor(model) { this.#model = model; }

    /**
     * Load the model. By default Face downloads the model from Hugging Face at the
     * pinned revision, then verifies and caches the files. Pass `directory` (Node)
     * or `modelBaseUrl` (browser) to use files you host yourself: `face_detect.tflite`
     * and `face.tflite`.
     */
    static async load(options = {}) {
      return new Face(await sdk.open(options));
    }

    /**
     * The faces in an image, most confident first: `{ box, landmarks, confidence, faceprint }`,
     * coordinates in 0..1 from the top left. `image` is `{ data, width, height }` with RGB or RGBA
     * bytes (an `ImageData` works as is), or in the browser anything `createImageBitmap` accepts.
     */
    async faces(image, { minimumConfidence, minimumSize, maxFaces, deviceId } = {}) {
      const pixels = await toPixels(image);
      return (await call(this.#model, "faces", { minimumConfidence, minimumSize, maxFaces }, pixels, deviceId)).map(reviveFace);
    }

    /** A new library, or one you saved (`library.save()`) or built from your own rows (`{ faces, names }`). */
    async library(saved = null) {
      const { handle } = await call(this.#model, "library.open", saved ? { library: toWire(saved) } : {});
      return new FaceLibrary(this.#model, handle);
    }

    /** Whether the model is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /** Send the usage recorded so far and await it, before a short-lived process exits. */
    flushLicenses() { return this.#model.flushLicenses(); }

    /** Release the model. The face is unusable afterwards. */
    dispose() { this.#model.dispose(); }

    /** Every faceprint matching `reference`, most similar first: `[{ index, similarity }]`. */
    static matches(reference, faceprints, options) { return matches(reference, faceprints, options); }
  };
}

export function makeFaceDetector(sdk) {
  /**
   * On-device face detection: where the faces in a photo are, with five landmarks
   * each, and no faceprints. Downloads Face's detector alone, which `Face` shares.
   *
   * ```js
   * const detector = await FaceDetector.load();
   * for (const { box } of await detector.faces(image)) blur(box);
   * ```
   */
  return class FaceDetector {
    #model;
    constructor(model) { this.#model = model; }

    /** Load the detector, as `Face.load` loads the model. A `modelBaseUrl` serves `face_detect.tflite`. */
    static async load(options = {}) {
      return new FaceDetector(await sdk.open(options, {
        variant: "detector", files: { artifact: "face_detect.tflite", sidecars: [] },
      }));
    }

    /** The faces in an image, most confident first: `{ box, landmarks, confidence }`, as `Face.faces` takes images. */
    async faces(image, { minimumConfidence, minimumSize, maxFaces, deviceId } = {}) {
      const pixels = await toPixels(image);
      return call(this.#model, "faces", { minimumConfidence, minimumSize, maxFaces }, pixels, deviceId);
    }

    /** Whether the detector is usable with no network. */
    isDownloaded() { return this.#model.isDownloaded(); }

    /** Send the usage recorded so far and await it, before a short-lived process exits. */
    flushLicenses() { return this.#model.flushLicenses(); }

    /** Release the detector. */
    dispose() { this.#model.dispose(); }
  };
}

export { Faceprint };
