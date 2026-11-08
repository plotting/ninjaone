# NinjaOne Automation Build & Administration Process (meta-SOP) — 2026-08-19

## What this is

Jeff asked for a reusable process doc covering everything administrative that happens around the `bit-ninjaone-automation` skill — the skill itself only produces the PowerShell script plus that one automation's own SOP/Runbook pair. This new page covers scope determination, approvals, naming (script/field/task/group), NinjaOne custom field + tag + WYSIWYG card creation, ConnectWise ticket template, ConnectWise documentation template, ConnectWise ticket automation ("CW Auto") rules, and pilot testing — the steps every one of the Cove, Quest Rapid Recovery, Vulnerability Management, and AD/Entra builds has needed but that live outside the skill's own output contract.

## Key decisions confirmed with Jeff (via AskUserQuestion, three rounds)

- **Format/location**: single Confluence reference page (not a full SOP+Runbook pair — there's no incident-response scenario here), placed in the existing SOPs folder (`1790115901`) for discoverability rather than a separate internal-process space.
- **Usage pattern**: reference doc, not a live step-by-step checklist.
- **Approvals**: Organization and Organization > Device scoped builds need Account Manager approval + Engineering Lead review; Global-scoped builds go to CAB (Change Approval Board).
- **Custom field "cards" (item 4)**: covers both the literal NinjaOne Admin UI field-creation steps AND the WYSIWYG report/card HTML design conventions already established in the automation skill.
- **Task/Group naming**: both match the automation's own name (same name used in the SOP/Runbook title's `<Topic>`).
- **CW Documentation template (item 6)**: the ticket/company Documents-tab reference doc, not a Configuration record.
- **CW Auto (item 7)**: ConnectWise ticket automation/workflow rules (auto-assign/auto-close/escalation) tied to the ticket type, not an Agreement addition.
- **CW ticket template (item 5)**: covers board/type/sub-type/item, priority + summary/description template with field placeholders, and routing/assignment/SLA — all three, per Jeff's answer.
- **Testing**: pilot device/org first, then expand scope — matches the existing rollout pattern from the Cove and Quest builds.
- **Gotchas section**: of four real production failures surfaced across the Cove/Quest/TreeSize builds (field-permission propagation delay, field-Name verification, undocumented field length limits, tag-creation prerequisite), Jeff asked to include **only** the tag-creation prerequisite. The other three were deliberately left out per his explicit multi-select answer — don't add them back in without asking again.
- **Screenshots**: Jeff will add his own; the page uses Confluence's native `placeholder` inline markers (renders as grayed-out prompt text) at each point a screenshot belongs, e.g. "Screenshot: Custom Field creation screen."

## Technical note: this session's Atlassian MCP takes HTML, not ADF

The `bit-confluence` skill's reference docs describe an older/different Atlassian Remote MCP that only accepts `contentFormat: "markdown"` or `"adf"`. The actual `mcp__Atlassian__*` tools available in this session accept `contentFormat: "html"` with a documented Confluence HTML+ dialect (data-type attributes for panels/status/placeholder/expand/etc.), validated server-side with descriptive rejection errors. Used that instead of hand-building ADF JSON — much lower error rate. One real rejection hit and fixed: arbitrary `style="color:..."` on inline elements (e.g. `<code>`) is **not** supported and gets rejected outright ("Unsupported attribute 'style'") — colored/flagged text has to go through the `status` lozenge macro (`<span data-type="status" data-color="yellow">change me</span>`) instead. Used that to flag "variables you need to change" in the Field info and CW ticket template sections, since the user asked for those to be visually called out.

## Published page

[SOP: NinjaOne Automation Build & Administration Process](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1801551895/SOP+NinjaOne+Automation+Build+Administration+Process) (page `1801551895`, v1, folder `1790115901`).

## Not yet done

Jeff said he'll edit it directly — no further action expected from this side unless he asks for changes. If this page is revised later, bump the Change log table at the bottom (currently v1.0) rather than overwriting history, matching the convention used on every other NinjaOne SOP/Runbook in this space.
