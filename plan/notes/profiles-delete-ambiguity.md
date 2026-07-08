# Open question: `profiles delete <name>` vs. `<name> delete`

This is the specific ambiguity the user request's requirement 3 flagged as the design task
most likely to need escalation ("If truly ambiguous ... flag it back via `needs input`/
`user_questions` rather than guessing silently"). It is a direct textual contradiction
within requirement 3 itself, not an inference gap this plan can resolve on its own
authority.

## The contradiction, quoted verbatim

Requirement 3's bullet list includes, as one of five sibling bullets describing the
settled command grammar:

> - `ai-sandbox profiles delete <name>` — delete a profile. New.

Two bullets later, the same requirement's explanatory paragraph states:

> Once a resource (instance OR profile) exists, it is addressed directly by its own bare
> name as the noun, exactly like today's per-instance dispatch: `ai-sandbox <name> <verb>`.
> The user's explicit example: `ai-sandbox profiles create foo` then later
> `ai-sandbox foo detail` — i.e. a profile named `foo` is addressed via `ai-sandbox foo
> detail`/`ai-sandbox foo delete`, the SAME bare-name-then-verb dispatch mechanism
> instances already use, NOT via `ai-sandbox profiles show foo`. This means instances and
> profiles share one flat namespace of addressable names and one dispatch mechanism for
> post-creation verbs — `profiles`/`instances` subcommands are ONLY for `ls` and `create`
> (the two operations where there's no existing name yet to dispatch through).

These cannot both be followed literally: the first says `ai-sandbox profiles delete <name>`
is itself a recognized three-token command; the second says `profiles`/`instances`
subcommands are used for `ls` and `create` *only*, gives `ai-sandbox foo delete` as the
canonical delete spelling, and explicitly rules out the parallel `profiles show foo` form
with the same shape as the disputed `profiles delete <name>` bullet.

## Why this is load-bearing, not cosmetic

The answer changes concrete implementation surface across every phase of this plan:

- **Dispatch parsing** (`src/options.sh`): whether a "noun create/delete" branch needs to
  exist under both `instances` and `profiles`, or only `create` (with `ls` and `create`
  being the sole two-token forms and everything else routed through the flat
  name-then-verb path).
- **Reserved-word set** (requirement 5): whether `delete` needs special handling when it
  follows a noun word, versus only ever appearing as a per-name verb.
- **Help text / README / architecture.md** (requirement 7): the documented profile-deletion
  syntax differs materially between the two readings.
- **Test coverage** (requirement 7): which exact invocation shapes get asserted.

## Two candidate resolutions

**A. Bullet-list wins.** `ai-sandbox profiles delete <name>` is a real, additional
three-token command, implemented alongside `ls`/`create` under the `profiles` noun. A
profile can then be deleted either via `ai-sandbox profiles delete foo` or (per the
flat-namespace mechanism) `ai-sandbox foo delete` — both work, calling the same underlying
delete logic. This requires the dispatch parser to recognize `delete` as a third verb under
the `profiles` noun (asymmetric with `instances`, which per the explanatory paragraph would
NOT get a parallel `instances delete <name>`, since deleting an instance was never
mentioned as a noun-level command in the bullet list — only for profiles).

**B. Explanatory-paragraph wins.** `profiles`/`instances` noun words support only `ls` and
`create`, full stop. Deleting a profile is exclusively `ai-sandbox foo delete` (resolved
through the shared flat-namespace, per-name dispatch mechanism, gated to profile-appropriate
verbs). The bullet-list line is treated as an imprecise summary that the explanatory
paragraph immediately corrects. No `profiles delete <name>` three-token form is implemented.

This plan's phase summaries are written to be agnostic to which of A or B is chosen — the
underlying `profile_exists`/verb-gating mechanism (see
[current-dispatch-audit.md](./current-dispatch-audit.md)) is needed either way; the only
difference is whether `src/options.sh` additionally recognizes a `profiles delete <name>`
parse path as a second, redundant entry point. Once resolved, task breakdown for the
`profiles-resource` phase can proceed without further research.
