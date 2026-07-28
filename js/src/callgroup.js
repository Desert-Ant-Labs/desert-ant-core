// Reusable usage call-group helper for the model node packages. A logical
// operation that issues several native calls should bill as one usage call; the
// native side coalesces runs that share a group id (desert-ant-core's Inference
// registry, released via the generic `dal_call_group_end` C symbol every SDK's
// core exports). This is the JS half: mint an id, hand it to the calls inside,
// and release it when they finish.
//
// Node-only usage (koffi binds `dal_call_group_end`), but this file itself is
// pure JS so it also works with the WebAssembly host if it ever exposes an
// equivalent release hook.

/** The generic C prototype every SDK core exports for releasing a group. */
export const CALL_GROUP_END_SYMBOL = "void dal_call_group_end(const char*)";

function newGroupId() {
  return (globalThis.crypto?.randomUUID?.() ??
    `dal-${Date.now()}-${Math.random().toString(16).slice(2)}`);
}

/**
 * Build the call-group API around a group-release function.
 *
 * @param {(id: string) => void} endGroup releases the native group for `id`
 *   (e.g. `lib.dal_call_group_end`).
 * @returns {{ withCallGroup: (body: (group: string) => Promise<any>) => Promise<any> }}
 */
export function makeCallGroups(endGroup) {
  return {
    /**
     * Run `body(group)` with a fresh group id, so every call inside that passes
     * `{ group }` bills as a single usage call. The group is released when
     * `body` settles (resolve or reject).
     */
    async withCallGroup(body) {
      const group = newGroupId();
      try {
        return await body(group);
      } finally {
        endGroup(group);
      }
    },
  };
}
