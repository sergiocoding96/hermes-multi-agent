---
name: email-marketing-plusvibe
description: "Cold email outreach agent for plusvibe.ai. Campaign planning, subject line optimization, audience segmentation, drip sequence design, deliverability strategy. Writes all outputs to MemOS email-mkt-cube."
metadata:
  hermes:
    tags: [email, marketing, plusvibe, campaigns, segmentation, drip-sequences, cold-email, outbound]
    related_skills: [web-research]
    category: email
---

# Email Marketing Agent -- plusvibe.ai

## When to Use This Skill

Use when asked to:
- Plan cold email outreach campaigns or sequences
- Write or optimize cold email subject lines and copy
- Define lead segments and targeting criteria
- Design multi-step outreach sequences with follow-ups
- Research competitor outreach strategies and benchmarks
- Manage campaigns, leads, or email accounts via the plusvibe.ai API
- Analyze campaign performance and deliverability metrics
- Set up email warm-up strategies

---

## Phase 1 -- Research (ALWAYS do this first)

Before creating ANY campaign content, research the landscape:

### Step 1.1: Competitor Email Research
```bash
# Use web-research skill to find competitor strategies
web_search("best email marketing campaigns [industry/niche] 2025 2026")
web_search("[competitor name] email onboarding sequence analysis")
web_search("email marketing benchmarks [industry] open rate click rate 2026")
```

### Step 1.2: Extract Key Benchmarks
From research, capture:
- Industry average open rates (typically 20-25% for SaaS)
- Industry average click rates (typically 2-5% for SaaS)
- Competitor subject line patterns
- Competitor email frequency
- Common CTA styles in the niche

### Step 1.3: plusvibe.ai Context
- **Product:** AI-powered cold email outreach platform at scale
- **Core features:** Email warm-up, deliverability optimization, AI prospecting (enrichment), AI sequence writer, unified inbox, ESP matching, lead management
- **Target audience:** B2B sales teams, SDRs, agencies doing outbound prospecting
- **Pricing:** Personal ($37/mo, 25K emails, 1K enrichment credits), Business ($97/mo, 100K emails, unlimited warm-up), Agency ($297/mo, unlimited inboxes + API access)
- **Key differentiators:** Built-in warm-up, prospect enrichment in 1 click, AI-driven icebreakers, IP rotation, ESP matching
- **Tone:** Professional-casual, results-focused, not salesy
- **Brand voice:** Smart outbound expert who helps you close more deals, not a corporate consultant
- **14-day free trial, no credit card required**

---

## plusvibe.ai API Reference

When the task requires programmatic actions (creating campaigns, adding leads, checking stats), use the plusvibe.ai API.

### Authentication
```bash
# All requests require x-api-key header + workspace_id parameter
curl -s -X GET "https://api.plusvibe.ai/v2/..." \
  -H "x-api-key: $PLUSVIBE_API_KEY" \
  -H "Content-Type: application/json"
```
- API key from: https://app.plusvibe.ai/v2/settings/api-access/
- Rate limit: 5 req/sec max
- Business Plan required for API access

### Key API Endpoints

| Category | Endpoint | Purpose |
|----------|----------|---------|
| **Campaigns** | Create campaign | New cold email sequence |
| | Create subsequence | Follow-up sequence for a campaign |
| | Activate/Pause campaign | Control campaign state |
| | Get campaign stats | Performance metrics |
| | Get variation stats | A/B test results |
| **Leads** | Add leads to campaign | Import prospects |
| | Get/search lead | Find specific leads |
| | Update lead status | Mark interested/not interested |
| | Fetch workspace leads | Bulk lead retrieval |
| | Get lead counts by status | Pipeline overview |
| **Email Accounts** | List accounts | Available sending accounts |
| | Check account vitals | Deliverability health |
| | Enable/Pause warmup | Warm-up control |
| | Get warmup stats | Warm-up progress |
| | Bulk add SMTP | Import sending accounts |
| **Unibox** | Get emails | Read inbox |
| | Reply to email | Respond to prospects |
| | Compose new email | Manual outreach |
| **Webhooks** | Add webhook | Real-time event notifications |
| | Events: FIRST_EMAIL_REPLIES, ALL_EMAIL_REPLIES, ALL_POSITIVE_REPLIES, LEAD_MARKED_AS_INTERESTED, EMAIL_SENT, BOUNCED_EMAIL |
| **Analytics** | Campaign summary | Overview metrics |
| | Campaign stats | Detailed performance |
| **Placement Testing** | Create parent test | Recurring inbox placement tests |
| | Get test results | Deliverability by provider |

### Full API docs: https://developer.plusvibe.ai/llms.txt

---

## Phase 2 -- Campaign Planning (Cold Email Outreach)

### Step 2.1: Define Campaign Structure

For each campaign, specify:

```markdown
## Campaign: [Name]

**Goal:** [What success looks like -- quantifiable if possible]
**Audience Segment:** [Who receives this -- behavioral definition]
**Email Count:** [N emails]
**Duration:** [X days/weeks]
**Trigger:** [What starts this sequence]

### Email Sequence

| # | Day | Subject Line | Purpose | CTA |
|---|-----|-------------|---------|-----|
| 1 | 0   | ...         | Welcome | ... |
| 2 | 2   | ...         | Value   | ... |
| 3 | 5   | ...         | Feature | ... |
```

### Step 2.2: Subject Line Generation

For EACH email in the sequence, generate 5+ subject line variants using these frameworks:

| Framework | Example |
|-----------|---------|
| Curiosity gap | "The email trick that 3x'd our open rates" |
| Personalization | "{{first_name}}, your weekly digest is ready" |
| Urgency | "Last chance: early access closes tonight" |
| Value prop | "5 templates that write your emails for you" |
| Social proof | "Join 2,000+ marketers using this workflow" |
| Question | "Are your emails actually getting read?" |
| How-to | "How to write emails that convert in 10 minutes" |
| Number/list | "7 email mistakes killing your conversions" |

For each variant, note which framework it uses and why it fits this email.

### Step 2.3: Audience Segmentation

Define segments by BEHAVIORAL signals, never demographics alone:

| Segment | Definition | Signals |
|---------|-----------|---------|
| New signup (< 7d) | Just created account | signup_date, onboarding_progress |
| Active user | Used platform in last 7 days | last_active, feature_usage |
| Power user | 3+ campaigns sent | campaigns_sent, contacts_imported |
| At-risk | No login in 14+ days | last_login, engagement_score |
| Churned | No activity in 30+ days | last_activity, subscription_status |

---

## Phase 3 -- Campaign Types (Cold Email Outreach)

### Initial Outreach Sequence (3-5 emails, 7-14 days)
```
Email 1 (Day 0): Personalized intro + value prop + soft CTA (reply or book a call)
Email 2 (Day 3): Follow-up — different angle, social proof or case study
Email 3 (Day 6): Value-add — share relevant resource or insight
Email 4 (Day 9): Breakup-style — "Is this relevant?" with clear opt-out
Email 5 (Day 12): Final — "closing the loop" with recap of value
```

### Re-engagement Sequence (2-3 emails, subsequence)
```
For leads who opened but didn't reply:
Email 1: Reference their opens + new angle
Email 2: Direct question or micro-commitment ask
Email 3: Breakup with value (share a resource before going)
```

### Warm Lead Nurture (3-4 emails, subsequence)
```
For leads marked as "interested" but not converted:
Email 1: Case study relevant to their industry
Email 2: ROI calculator or comparison data
Email 3: Limited-time offer or exclusive access
Email 4: Calendar link + "let's make it easy"
```

### Partner/Agency Outreach (3-4 emails)
```
Email 1: Mutual value prop — "we help agencies like yours"
Email 2: Success story from similar agency
Email 3: Partnership offer details
Email 4: Breakup with door-open
```

### Deliverability Best Practices (built into every campaign)
```
- Warm up new accounts for 14+ days before campaigns
- Start with 20 emails/day, ramp to 50 over 2 weeks
- Use plusvibe.ai ESP matching for optimal sender rotation
- Monitor bounce rates (target < 3%)
- A/B test subject lines using campaign variations
- Use webhooks (BOUNCED_EMAIL, ALL_POSITIVE_REPLIES) for automation
```

---

## Phase 4 -- MemOS Dual-Write

After creating the campaign deliverables, persist to MemOS.

### Write Protocol

For EACH major deliverable (campaign plan, segment definition, subject line set):

```bash
curl -s -X POST http://localhost:8001/product/add \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "email-marketing-agent",
    "writable_cube_ids": ["email-mkt-cube"],
    "async_mode": "sync",
    "messages": [
      {
        "role": "assistant",
        "content": "[DELIVERABLE]: [title]\n\n[Full content of deliverable]"
      }
    ],
    "custom_tags": ["email", "campaign", "[campaign-type]"],
    "info": {
      "source_type": "email_campaign",
      "campaign_type": "[welcome|nurture|reengagement|announcement]",
      "email_count": [N]
    }
  }'
```

### Write Rules
- One POST per deliverable (campaign plan, segment def, subject line set)
- async_mode MUST be "sync"
- If POST returns non-200, log the error but DO NOT retry
- Include campaign_type in info metadata

---

## Phase 5 -- Self-Improvement

After completing a campaign:

1. **Review output quality:**
   - Did research inform the campaign? (If not, research step needs improvement)
   - Are subject lines varied? (If all use same framework, diversify)
   - Are segments behavioral? (If demographic-only, fix segmentation instructions)

2. **Patch if needed:**
   ```
   skill_manage(action="patch", name="email-marketing-plusvibe",
     file="SKILL.md",
     old="[section that failed]",
     new="[improved section]")
   ```

3. **Log in MEMORY.md:**
   - What was improved and why
   - New benchmarks discovered
   - Competitor insights worth remembering

---

## Output Format

Present the final deliverable as:

```markdown
# Email Campaign Plan: [Campaign Name]

## Research Summary
[3-5 bullet points from competitor/benchmark research]

## Campaign Overview
- **Goal:** ...
- **Audience:** [segment name + behavioral definition]
- **Emails:** N over X days
- **Trigger:** ...

## Email Sequence
[Table with day, subject line (top pick), purpose, CTA]

## Subject Line Variants
[For each email: 5+ variants with framework labels]

## Audience Segments
[Table with segment name, definition, signals]

## Benchmarks
- Expected open rate: X% (industry avg: Y%)
- Expected click rate: X% (industry avg: Y%)

## Sources
[URLs from research phase]
```

---

## Common Mistakes to Avoid

- Don't skip research. Every campaign starts with competitor analysis.
- Don't use generic subject lines. Each must use a specific framework.
- Don't define segments by demographics. Behavior > demographics.
- Don't forget MemOS writes. CEO needs your outputs for cross-agent synthesis.
- Don't write essays. Email copy should be scannable: short paragraphs, bullets, clear CTA.
