# Config-persistence triad decision (Q-U3)

## Question

Should a new `--add-host` flag participate in ai-sandbox's existing
config-persistence triad (compose `environment:` entry +
`ai.sandbox.<field>` container label + `running_config_matches()`
comparison), the way `--allow-egress` already does? An existing open
followup (`yS0R`) already flags that two sibling capabilities
(host-access/lan-access) currently DON'T participate in this triad — a gap
this new work shouldn't blindly repeat.

Options offered: (1) yes, full triad participation, (2) no, minimal/env-only
for now.

## Answer

Yes, full triad participation and also fold in followup `yS0R` and note to
remove it after the plan is implemented.

Mirror the `--allow-egress` precedent exactly for the new `--add-host`
flag: compose `environment:` entry, `ai.sandbox.<field>` container label,
and `running_config_matches()` comparison, so drift/recreate prompts work
correctly.

Additionally: this plan should also close the pre-existing gap tracked by
followup `yS0R` (`AI_SANDBOX_LAN_CIDR` / `AI_SANDBOX_HOST_LISTEN_PORTS`
currently missing from the same triad) as part of this same effort, rather
than deferring it further — since the new work would otherwise sit right
next to an already-flagged inconsistency without fixing it. Once
implemented, remove followup `yS0R` from `plan/followups.yaml` (the
manager will handle this via `apply-task-report`/`followups_remove` when
the relevant task lands, not the planning agent).
