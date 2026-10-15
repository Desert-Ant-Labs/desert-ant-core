// Licensing counts installs, not calls, so a call group no longer changes anything.
export const CALL_GROUP_END_SYMBOL = "void dal_call_group_end(const char*)";

function newGroupId() {
  return (globalThis.crypto?.randomUUID?.() ??
    `dal-${Date.now()}-${Math.random().toString(16).slice(2)}`);
}

export function makeCallGroups(_endGroup) {
  return {
    async withCallGroup(body) {
      return body(newGroupId());
    },
  };
}
