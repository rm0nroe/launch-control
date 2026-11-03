# Verification Reference

## Pre-delivery: local and staging

Run repository gates required by the changed package or ticket, then checks from the
selected platform and relevant capability sections. Do not widen execution to other
platforms. Record results in the plan before delivery.

### Shared

Run repository gates, then only the consuming platform checks named in the ticket plan.

## AI evaluation contract

- Pin a versioned model, prompt, and configuration.
- Use representative evaluation cases with correctness or groundedness criteria.
- Include negative and abuse cases with escalation behavior.
- Record latency and cost against thresholds.
- Name a human owner for subjective quality and risk acceptance.
- Keep deterministic policy and tool-authorization tests separate from probabilistic output scoring.

| TC | Description | Status |
|---|---|---|
| TC1 | Expected behavior | Verified or blocked with reason |

## Post-deploy: production only

Run `/deploy-verify <service>`, confirm the deployed revision, repeat the production
user flow, read back serving state, and check telemetry. CI is not production proof.
