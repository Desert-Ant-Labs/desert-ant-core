// Type-level assertions for the checks in `mise run check:types`.

/// Exact type identity, not assignability.
///
/// Assignability is the wrong tool for comparing two declarations of one API:
/// TypeScript compares method parameters bivariantly even under `strict`, so a
/// declaration narrowed to `run(deviceId: string)` stays assignable to a generated
/// `run(deviceId: string | null)` in *both* directions, and the drift goes
/// unnoticed. This conditional-inference trick compares invariantly, so any
/// difference at all - a parameter, a return, an added or missing member - is
/// `false`.
export type Equal<X, Y> =
  (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;

/// Fails to compile unless `T` is `true`, which is how an assertion reports.
export type Expect<T extends true> = T;
