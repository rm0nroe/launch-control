# Verification Reference

## Pre-delivery: local and staging

Run every runnable repository gate required by the changed package or ticket, then the
user-observable checks from the selected platform and relevant capability sections before
delivery. Do not use this common block to widen execution to other platforms. Record each
result in the ticket plan.

{{#if PLATFORM_GENERAL}}
### General or unknown

Use the repository's documented checks. If no user-observable target exists, record that
boundary instead of inventing application QA.
{{/if}}
{{#if PLATFORM_IOS}}
### iOS

Build and launch the selected simulator target, exercise the changed flow, capture the
screen, and inspect accessibility state before delivery.
{{#if HAS_XCODEBUILD_MCP}}
Use available `mcp__XcodeBuildMCP__*` or `mcp__ios-simulator__*` tools.
{{/if}}
{{/if}}
{{#if PLATFORM_ANDROID}}
### Android

Run {{ANDROID_TEST_CMD}}, then exercise the changed flow on the selected emulator or device.
{{/if}}
{{#if PLATFORM_WEB}}
### Web

Drive a real browser against the change: navigate, interact, inspect console output, and
capture the changed state before delivery. Use the first driver in this order that works:

- The project's own browser tests when it has them (for example Playwright or Cypress
  specs), mocking the session and network the way the existing specs do.
{{#if HAS_CHROME_MCP}}
- Use `mcp__chrome__use_browser` for navigation and capture.
{{/if}}
{{#if HAS_CHROME_DEVTOOLS_MCP}}
- Use available `mcp__chrome-devtools__*` navigation, inspection, and screenshot tools.
{{/if}}
{{#if HAS_PLAYWRIGHT_MCP}}
- Use available `mcp__playwright__*` tools when the project mandates Playwright.
{{/if}}
- Otherwise, any available browser automation tool.

The verification result names which driver ran.
{{#if HAS_FIGMA_MCP}}
For Figma-driven work, use the detected Figma implementation capability.
{{/if}}
{{/if}}
{{#if PLATFORM_BACKEND}}
### Backend

Exercise the local or staging endpoint at {{BACKEND_LOCAL_URL}} and run
{{BACKEND_E2E_CMD}} when detected. Check staging logs when an observability capability exists.
{{#if HAS_CODE_SEARCH_MCP}}
- Use the semantic code-search MCP to map endpoint impact.
{{/if}}
{{#if HAS_DATADOG_MCP}}
- Use available `mcp__datadog__*` tools for staging logs and spans.
{{/if}}
{{#if HAS_SENTRY_MCP}}
- Use available `mcp__sentry__*` tools for error-rate monitoring.
{{/if}}
{{/if}}
{{#if PLATFORM_SHARED}}
### Shared

Run repository gates, then run only the consuming platform checks explicitly named in
the ticket plan. If no affected platform is named, stop and resolve that ambiguity.
{{/if}}
{{#if HAS_GROWTHBOOK_MCP}}
### Feature flags

Use available `mcp__growthbook__*` tools to verify the flag and rules before delivery;
do not mutate them without separate authorization.
{{/if}}

{{#if AI_EVAL_ENABLED}}
## AI evaluation contract

- Pin a versioned model, prompt, and configuration for every recorded run.
- Use representative evaluation cases with explicit correctness or groundedness criteria.
- Include negative and abuse cases plus safe refusal and escalation behavior.
- Record latency and cost distributions against declared thresholds.
- Name a human owner for subjective quality and risk acceptance.
- Keep deterministic policy and tool-authorization tests separate from probabilistic output scoring.
- Store inputs, outputs, scores, configuration versions, and rerun instructions as reproducible evidence.
{{/if}}

## Result record

| TC | Description | Status |
|---|---|---|
| TC1 | Expected behavior | Verified or blocked with reason |

Unverified work needs a concrete reason. A skipped check is not a pass.

## Post-deploy: production only

Run this section only after delivery.

{{#if HAS_DEPLOY_VERIFY_COMMAND}}
- Run `/{{DEPLOY_VERIFY_COMMAND_NAME}} <service>` and record its deployed revision.
{{/if}}
- Confirm the deployed revision equals the intended merge result.
- Repeat the user-observable production check for the changed behavior.
- Read back production state or assets from the serving system when applicable.
- Check available error and latency telemetry for regressions.

Local, staging, CI, or deployment-success output is not production proof.
